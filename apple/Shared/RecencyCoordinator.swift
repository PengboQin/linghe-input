import Foundation
import Darwin
import PrivateInputKit

/// No Date-derived trust: the sync adapter injects an authenticated service
/// policy/clock. The durable archive survives old v1 publishers independently.
struct RecencyCoordinator {
    struct Snapshot {
        let scores: [String: Double]
        let authenticated: Bool
        let expiresUptime: Double
        func isCurrent(uptime: Double = ProcessInfo.processInfo.systemUptime) -> Bool { authenticated && uptime <= expiresUptime }
        static let empty = Snapshot(scores: [:], authenticated: false, expiresUptime: 0)
    }
    struct Persisted: Codable {
        let archive: Data
        let referenceDay: Int
        let windowDays: Int
    }
    private(set) var model = RecentLearningModel()
    private(set) var policy: RecentLearningPolicy
    private var clock: RecentLearningClock?
    // Never persist this observation proof. Restart and privacy-mode intervals
    // must establish a new observation before any native delta receives a date.
    private var previousObservationDay: Int?
    private var previousObservationUptime: Double?
    private var previousBoot: String?
    private var permit = false
    private var clockValidityDeadline: Double?

    init(persisted: Persisted? = nil, capacityProfile: LearningCapacityProfile = LearningCapacityProfiles.expanded10000) throws {
        policy = try RecentLearningPolicy(referenceDay: persisted?.referenceDay ?? 90,
                                         windowDays: persisted?.windowDays ?? 90)
        if let persisted {
            model = try RecentLearningModel(restoring: persisted.archive, policy: policy)
        } else { model = try RecentLearningModel(capacityProfile: capacityProfile) }
    }
    mutating func upgradeCapacity(to profile: LearningCapacityProfile) throws {
        guard model.capacityProfile != profile else { return }
        var next = model; try next.upgradeCapacity(to: profile, policy: policy); model = next
    }
    func persisted() throws -> Persisted {
        .init(archive: try model.export(policy: policy), referenceDay: policy.referenceDay, windowDays: policy.windowDays)
    }
    mutating func acceptAuthenticated(policy: RecentLearningPolicy, clock: RecentLearningClock, validUntilUptime: Double? = nil) throws {
        // An older service response cannot rewind the pruning/score watermark.
        guard policy.referenceDay >= self.policy.referenceDay else { throw InputDataError.invalidRecord }
        var next = model
        let archive = try next.export(policy: self.policy)
        next = try RecentLearningModel(capacityProfile: model.capacityProfile); try next.merge(archive, policy: policy)
        let resetProof = !permit || self.policy.referenceDay != policy.referenceDay
        self.model = next; self.policy = policy; self.clock = clock; clockValidityDeadline = validUntilUptime; permit = true
        if resetProof { invalidateObservation() }
    }
    mutating func suspend() { permit = false; clock = nil; invalidateObservation() }
    mutating func invalidateObservation() {
        previousObservationDay = nil; previousObservationUptime = nil; previousBoot = nil
    }
    /// The *entire* increment interval must be demonstrably within one trusted
    /// day. A cross-midnight, cold start, imported or private interval is undated.
    mutating func observe(before: RimeLearningCheckpoint, after: RimeLearningCheckpoint,
                          replica: String, wall: Double, uptime: Double, boot: String,
                          canDate: Bool, validating: () -> Bool = { true }) throws {
        var active = clock
        let day = permit && canDate ? active?.day(wallUnixSeconds: wall, uptime: uptime, bootSession: boot) : nil
        clock = active
        let dateDelta = day != nil && day == previousObservationDay && previousBoot == boot &&
            previousObservationUptime.map { uptime >= $0 } == true
        var deltas: [RecentLearningDelta] = []
        for entry in after.model.entries.values {
            let old = before.model.entries[entry.id]
            let checkpointBaseline = old?.generation == entry.generation ? (old?.counts[replica] ?? 0) : 0
            let known = model.entries[entry.id]?.word
            // A shared v2 snapshot may already contain this writer's exact
            // positive increment while its older native checkpoint is restored.
            // MAX baselines ensure replay cannot date or add that amount twice.
            let knownBaseline = known?.generation == entry.generation ? (known?.counts[replica] ?? 0) : 0
            let baseline = max(checkpointBaseline, knownBaseline)
            let count = entry.counts[replica] ?? 0
            if count > baseline, (known?.generation ?? entry.generation) == entry.generation {
                deltas.append(.init(reading: entry.reading, text: entry.text, replica: replica,
                                    amount: count - baseline, trustedDay: dateDelta ? day : nil))
            }
        }
        // Establish the prior cumulative counts before adding a dated increment;
        // otherwise the final legacy MAX merge would double the replica count.
        guard validating() else { throw SnapshotStoreError.busy }
        try model.mergeLegacy(before.outboundArchive(), policy: policy)
        guard validating() else { throw SnapshotStoreError.busy }
        try model.recordLocalDeltas(deltas, policy: policy)
        guard validating() else { throw SnapshotStoreError.busy }
        try model.mergeLegacy(after.outboundArchive(), policy: policy)
        guard validating() else { throw SnapshotStoreError.busy }
        previousObservationDay = day; previousObservationUptime = day == nil ? nil : uptime
        previousBoot = day == nil ? nil : boot
    }
    mutating func mergeCumulative(_ checkpoint: RimeLearningCheckpoint) throws {
        try model.mergeLegacy(checkpoint.outboundArchive(), policy: policy)
    }
    mutating func mergeRemote(_ data: Data) throws { try model.merge(data, policy: policy) }
    func export() throws -> Data { try model.export(policy: policy) }
    /// Computed only at idle checkpoints / verified policy changes, never while
    /// iterating a touch target or performing key-down native work.
    mutating func snapshot(wall: Double, uptime: Double, boot: String) -> Snapshot {
        var active = clock
        let day = permit ? active?.day(wallUnixSeconds: wall, uptime: uptime, bootSession: boot) : nil
        clock = active
        let trusted = day != nil && policy.accepts(day!)
        var values: [String: Double] = [:]
        for id in model.entries.keys {
            if let score = try? model.score(id: id, policy: trusted ? policy : nil) {
                // Absent/stale authenticated service falls back to unchanged
                // native cumulative ranking, not a locally invented fresh day.
                if trusted { values[id] = score.total }
            }
        }
        return .init(scores: values, authenticated: trusted, expiresUptime: clockValidityDeadline ?? uptime)
    }

    /// Stable bounded ranking within a pre-classified equivalent candidate
    /// group. Source/spelling/pin/prefix eligibility is owned by NativeEngine.
    static func ordered<T>(_ rows: [T], score: (T) -> Double) -> [T] {
        // Scores are bounded preferences, not fractions of a fixed rank gap.
        // Insertion swaps allow a meaningful fresh habit to move, while an
        // explicit displacement check protects BOTH promoted and displaced rows.
        var result = rows.enumerated().map { (original: $0.offset, row: $0.element, score: min(0.999, max(0, score($0.element)))) }
        for original in rows.indices.dropFirst() {
            guard var position = result.firstIndex(where: { $0.original == original }) else { continue }
            while position > 0 {
                let value = result[position], preceding = result[position - 1]
                guard value.score - preceding.score > 0.025,
                      abs(value.original - (position - 1)) <= 2,
                      abs(preceding.original - position) <= 2 else { break }
                result.swapAt(position, position - 1); position -= 1
            }
        }
        return result.map(\.row)
    }
}

/// A small app-owned bridge between the asynchronous network worker and the
/// independent app / keyboard Rime replicas. All write paths are idle or sync
/// work; candidate display reads only LocalLearningCoordinator.scoreSnapshot.
struct AppleRecencyBridge {
    struct Anchor: Codable {
        let unixSeconds: Double
        let uptime: Double
        let boot: String
    }
    struct State: Codable {
        var version = 1
        var group: UUID
        var epoch: UInt64
        var referenceDay: Int
        var windowDays: Int
        var archive: Data?
        var anchor: Anchor?
        var policy: RecentLearningPolicy { get throws { try .init(referenceDay: referenceDay, windowDays: windowDays) } }
    }
    let directory: URL
    private let epoch: PersonalDataEpoch
    init(directory: URL) { self.directory = directory; epoch = PersonalDataEpoch(directory: directory) }
    private var file: URL { directory.appendingPathComponent("learning-recency-v2.json") }
    static var bootSession: String? {
        var value = timeval(), count = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &value, &count, nil, 0) == 0, value.tv_sec > 0 else { return nil }
        return "darwin-\(value.tv_sec)-\(value.tv_usec)"
    }
    func read() throws -> State? {
        try epoch.requireCurrent()
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 3 * 1024 * 1024 else { throw InputDataError.oversized }
        let data = try Data(contentsOf: file)
        guard data.count <= 3 * 1024 * 1024 else { throw InputDataError.oversized }
        let state = try JSONDecoder().decode(State.self, from: data)
        guard state.version == 1 else { throw InputDataError.incompatibleSchema }
        let policy = try state.policy
        if let data = state.archive { var model = try RecentLearningModel(capacityProfile: LearningCapacityProfiles.expanded10000); try model.merge(data, policy: policy) }
        return state
    }
    func acceptAuthenticated(group: UUID, epoch: UInt64, policy: RecentLearningPolicy, unixSeconds: Double,
                             uptime: Double = ProcessInfo.processInfo.systemUptime) throws {
        guard let boot = Self.bootSession else { throw InputDataError.invalidRecord }
        _ = try RecentLearningClock(authenticatedUnixSeconds: unixSeconds, uptime: uptime, bootSession: boot)
        try update { old in
            if let old, old.group == group, (policy.referenceDay < old.referenceDay || epoch < old.epoch) { throw InputDataError.invalidRecord }
            var model = try RecentLearningModel(capacityProfile: LearningCapacityProfiles.expanded10000)
            if let old, old.group == group, let data = old.archive { try model.merge(data, policy: policy) }
            return State(group: group, epoch: epoch, referenceDay: policy.referenceDay, windowDays: policy.windowDays,
                archive: try model.export(policy: policy), anchor: .init(unixSeconds: unixSeconds, uptime: uptime, boot: boot))
        }
    }
    func suspend() throws {
        try update { old in
            guard var old, old.anchor != nil else { return nil }; old.anchor = nil; return old
        }
    }
    func archive(group: UUID, epoch: UInt64) throws -> Data? {
        guard let state = try read() else { return nil }
        guard state.group == group, state.epoch == epoch else { throw InputDataError.invalidRecord }
        return state.archive
    }
    func merge(_ data: Data, group: UUID, epoch: UInt64) throws {
        guard try mergeIfCurrent(data, group: group, epoch: epoch) else { throw InputDataError.invalidRecord }
    }
    /// A completed local checkpoint may still refer to the previously accepted
    /// group epoch after its clock anchor was suspended. Never publish that
    /// observation into another target, or turn its local commit into failure.
    func mergeIfCurrent(_ data: Data, group: UUID, epoch: UInt64, validating: () -> Bool = { true }) throws -> Bool {
        try self.epoch.requireCurrent()
        do { _ = try FileManager.default.attributesOfItem(atPath: file.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return false }
        var merged = false
        try update(validating: validating) { old in
            guard var old, old.group == group, old.epoch == epoch else { return nil }
            let policy = try old.policy
            var model = try RecentLearningModel(capacityProfile: LearningCapacityProfiles.expanded10000)
            if let data = old.archive { try model.merge(data, policy: policy) }
            try model.merge(data, policy: policy); old.archive = try model.export(policy: policy)
            merged = true
            return old
        }
        return merged
    }
    private struct FileVersion: Equatable {
        let inode: UInt64, size: UInt64
        let modified: Date?
        static func read(_ file: URL) throws -> Self? {
            do {
                let a = try FileManager.default.attributesOfItem(atPath: file.path)
                return .init(inode: (a[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                    size: (a[.size] as? NSNumber)?.uint64Value ?? 0, modified: a[.modificationDate] as? Date)
            } catch let e as NSError where e.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(e.code) { return nil }
        }
    }
    private func update(validating: () -> Bool = { true }, _ action: (State?) throws -> State?) throws {
        try epoch.requireCurrent(); guard validating() else { throw SnapshotStoreError.busy }
        let before = try FileVersion.read(file), old = try read()
        guard try FileVersion.read(file) == before else { throw SnapshotStoreError.busy }
        // Decode, merge and encode before acquiring the publication lock.
        guard let next = try action(old) else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(next)
        guard data.count <= 3 * 1024 * 1024 else { throw InputDataError.oversized }
        try epoch.requireCurrent(); guard validating() else { throw SnapshotStoreError.busy }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = Darwin.open(directory.appendingPathComponent("learning-recency-publication.lock").path,
                                     O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw SnapshotStoreError.busy }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw SnapshotStoreError.busy }
        defer { flock(descriptor, LOCK_UN) }
        try epoch.requireCurrent()
        guard validating(), try FileVersion.read(file) == before else { throw SnapshotStoreError.busy }
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: file, options: .atomic)
        #endif
    }
}
