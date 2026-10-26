import Foundation
import Darwin
import PrivateInputKit

enum LearningSyncFailure: Error { case busy, engineUnavailable, exportFailed, importFailed }
struct LearningCheckpointMetrics {
    var elapsedMilliseconds = 0.0
    var nativeImports = 0
    var nativeResets = 0
    var recoveredPending = false
    var persistedBytes = 0
    var skippedWriteBytes = 0
    var completed = false
}

/// One finite keyboard-maintenance grant. Only ProcessInfo's activity worker
/// waits; main and the input/IO queues never wait for lifecycle completion.
final class LearningMaintenancePermit: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false, completed = false
    private let completion = DispatchSemaphore(value: 0)
    var allowed: Bool { lock.lock(); defer { lock.unlock() }; return !cancelled && !completed }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func finish() { lock.lock(); let signal = !completed; completed = true; lock.unlock(); if signal { completion.signal() } }
    func waitForCompletionOnActivityWorker() { completion.wait() }
}

// Host/keyboard replicas use separate counter IDs; they share a physical device
// but cannot safely add counters from two independent private engine databases.
final class LocalLearningCoordinator {
    static let groupID = "group.live.linghe.privateinput"
    static func sharedDirectory() -> URL? {
        #if os(iOS)
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
        #else
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("PrivateInput/Shared", isDirectory: true)
        #endif
    }
    private let personalEpoch: String
    private var maintenancePermitted: () -> Bool = { true }
    func restrictMaintenance(to permitted: @escaping () -> Bool) { maintenancePermitted = permitted }
    private let rankingPreferences: UserDefaults?
    private let stateURL: URL
    private let device: String
    private let shared: SharedLearningSnapshot?
    private let recencyBridge: AppleRecencyBridge?
    private let refreshSharedDirectory: URL?
    init(base: URL, rankingPreferences: UserDefaults? = UserDefaults(suiteName: LocalLearningCoordinator.groupID)) throws {
        personalEpoch = PersonalDataReset.generation; boot = AppleRecencyBridge.bootSession ?? UUID().uuidString
        self.rankingPreferences = rankingPreferences
        let manager = FileManager.default
        try manager.createDirectory(at: base, withIntermediateDirectories: true)
        stateURL = base.appendingPathComponent("learning-checkpoint-v1.json")
        let idFile = base.appendingPathComponent("local-replica-id.txt")
        if manager.fileExists(atPath: idFile.path) {
            let value = try String(contentsOf: idFile, encoding: .utf8)
            guard UUID(uuidString: value) != nil else { throw InputDataError.invalidRecord }
            device = value
        } else {
            device = UUID().uuidString
            try Data(device.utf8).write(to: idFile, options: .atomic)
        }
        #if os(iOS)
        if let directory = manager.containerURL(forSecurityApplicationGroupIdentifier: Self.groupID) {
            refreshSharedDirectory = directory
            shared = SharedLearningSnapshot(directory: directory)
            recencyBridge = AppleRecencyBridge(directory: directory)
        } else { refreshSharedDirectory = nil; shared = nil; recencyBridge = nil }
        #else
        refreshSharedDirectory = base.appendingPathComponent("Shared", isDirectory: true)
        shared = SharedLearningSnapshot(directory: base.appendingPathComponent("Shared", isDirectory: true))
        recencyBridge = AppleRecencyBridge(directory: base.appendingPathComponent("Shared", isDirectory: true))
        #endif
    }
    /// Immutable locations only; the utility preflight never touches this live
    /// coordinator, its journal or the native session.
    var learningRefreshSources: [LearningRefreshSource] {
        var rows: [LearningRefreshSource] = [
            .init(name:"runtime",url:runtimeURL,maximum:12*1024*1024,runtime:true),
            .init(name:"legacy-local",url:stateURL,maximum:8*1024*1024,runtime:false),
            .init(name:"local-reset",url:stateURL.deletingLastPathComponent().appendingPathComponent(PersonalDataReset.marker),maximum:128,runtime:false),
            .init(name:"hidden-native-retry",url:hiddenMaintenanceURL,maximum:128,runtime:false)]
        if let root=refreshSharedDirectory {
            rows += [.init(name:"shared-v1",url:root.appendingPathComponent("learning-v1.json"),maximum:2*1024*1024,runtime:false),
                     .init(name:"shared-v2",url:root.appendingPathComponent("learning-recency-v2.json"),maximum:3*1024*1024,runtime:false),
                     .init(name:"cloud-ranking",url:root.appendingPathComponent(AppleCloudLearningRankState.filename),maximum:4*1024*1024,runtime:false),
                     .init(name:"shared-reset",url:root.appendingPathComponent(PersonalDataReset.marker),maximum:128,runtime:false)]
        }
        return rows
    }
    // One atomic authority covers the native intent, checkpoint and v2 archive.
    // learning-checkpoint-v1.json remains a compatibility projection only.
    private struct RuntimeState: Codable {
        var version = 2
        var journal: Data
        var recency: RecencyCoordinator.Persisted
        var group: UUID?
        var membershipEpoch: UInt64?
        var completedNativeNonce: UUID? = nil
        var personalEpoch: String? = nil
    }
    private var completedNativeNonce: UUID?
    private var runtimeCacheVersion: ObservationFileVersion?
    static let nativePhaseFilename = "learning-native-phase-v2.txt"
    static let authorityLockFilename = "learning-authority-v2.lock"
    /// Only already-encoded writes/native batches hold this lock. UI callers
    /// try rather than wait; explicit reset cleanup waits for a short IO lease.
    static func withAuthorityLock<T>(base: URL, wait: Bool, _ action: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let descriptor = Darwin.open(base.appendingPathComponent(authorityLockFilename).path,
            O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw SnapshotStoreError.busy }; defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | (wait ? 0 : LOCK_NB)) == 0 else { throw SnapshotStoreError.busy }
        defer { flock(descriptor, LOCK_UN) }
        return try action()
    }
    private var runtimeURL: URL { stateURL.deletingLastPathComponent().appendingPathComponent("learning-runtime-v2.json") }
    static let hiddenMaintenanceHint = "hidden-native-maintenance-v1.txt"
    private var hiddenMaintenanceURL: URL { stateURL.deletingLastPathComponent().appendingPathComponent(Self.hiddenMaintenanceHint) }
    /// A hint only: every later transaction still needs the current hidden,
    /// input, consent, epoch and source-fingerprint admission. Never an intent.
    func requiresHiddenNativeMaintenance() throws -> Bool {
        try ensureEpoch()
        if FileManager.default.fileExists(atPath: nativePhaseURL.path) { return true }
        guard FileManager.default.fileExists(atPath: hiddenMaintenanceURL.path) else { return false }
        let stamp = try ObservationFileVersion.read(hiddenMaintenanceURL)
        guard stamp.size <= 128 else { throw InputDataError.oversized }
        return try Data(contentsOf: hiddenMaintenanceURL) == Data(personalEpoch.utf8)
    }
    func requireHiddenNativeMaintenance() throws {
        try ensureEpoch()
        guard personalEpoch.utf8.count <= 128 else { throw InputDataError.invalidRecord }
        if try requiresHiddenNativeMaintenance() { return }
        #if os(iOS)
        try Data(personalEpoch.utf8).write(to: hiddenMaintenanceURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try Data(personalEpoch.utf8).write(to: hiddenMaintenanceURL, options: .atomic)
        #endif
    }
    func completeHiddenNativeMaintenance() throws {
        try ensureEpoch()
        if FileManager.default.fileExists(atPath: hiddenMaintenanceURL.path) { try FileManager.default.removeItem(at: hiddenMaintenanceURL) }
    }

    private var recent: RecencyCoordinator?
    private var cloudScoreActive = false
    private var cloudScoreGroup: UUID?
    private var cloudScoreEpoch: UInt64?
    private var storedScoreSnapshot = RecencyCoordinator.Snapshot.empty
    private var pendingObservationScore: (RecencyCoordinator.Snapshot, Bool, UUID?, UInt64?)?
    private var pendingCloudSnapshot: (RecencyCoordinator.Snapshot, UUID, UInt64)?
    func stageCloudSnapshot(_ snapshot: RecencyCoordinator.Snapshot, group: UUID, epoch: UInt64) {
        pendingCloudSnapshot = (snapshot, group, epoch)
    }
    /// O(1) pointer adoption at the next composition start, never reload a
    /// visible candidate list. No file, network, Keychain or full-model work.
    func beginComposition() {
        if let (snapshot, active, group, epoch) = pendingObservationScore {
            pendingObservationScore = nil; storedScoreSnapshot = snapshot
            cloudScoreActive = active; cloudScoreGroup = group; cloudScoreEpoch = epoch
        }
        guard let (snapshot, group, epoch) = pendingCloudSnapshot else { return }
        pendingCloudSnapshot = nil
        guard rankingPreferences?.bool(forKey: "learning-sharing-enabled") == true,
              rankingPreferences?.bool(forKey: "cloud-learning-enabled") == true,
              rankingPreferences?.string(forKey: "cloud-learning-group") == group.uuidString,
              (rankingPreferences?.object(forKey: "cloud-learning-epoch") as? NSNumber)?.uint64Value == epoch,
              snapshot.isCurrent() else { return }
        storedScoreSnapshot = snapshot; cloudScoreActive = true; cloudScoreGroup = group; cloudScoreEpoch = epoch
    }
    private(set) var scoreSnapshot: RecencyCoordinator.Snapshot {
        get {
            if cloudScoreActive {
                let prefs = rankingPreferences
                guard prefs?.bool(forKey: "learning-sharing-enabled") == true,
                      prefs?.bool(forKey: "cloud-learning-enabled") == true,
                      prefs?.string(forKey: "cloud-learning-group") == cloudScoreGroup?.uuidString,
                      (prefs?.object(forKey: "cloud-learning-epoch") as? NSNumber)?.uint64Value == cloudScoreEpoch else { return .empty }
            }
            return storedScoreSnapshot
        }
        set { storedScoreSnapshot = newValue }
    }
    private(set) var lastCheckpointMetrics = LearningCheckpointMetrics()
    private let boot: String
    private var recencyGroup: UUID?
    private var recencyMembershipEpoch: UInt64?
    private func ensureEpoch() throws {
        guard maintenancePermitted() else { throw LearningSyncFailure.busy }
        guard personalEpoch == PersonalDataReset.generation else { throw LearningSyncFailure.busy }
    }
    private func readJournal() throws -> LearningImportJournal {
        try ensureEpoch()
        if FileManager.default.fileExists(atPath: runtimeURL.path) {
            let data = try Data(contentsOf: runtimeURL)
            guard data.count <= 12 * 1024 * 1024 else { throw InputDataError.oversized }
            let state = try JSONDecoder().decode(RuntimeState.self, from: data)
            guard state.version == 2 else { throw InputDataError.incompatibleSchema }
            guard state.personalEpoch == nil || state.personalEpoch == personalEpoch else { throw LearningSyncFailure.busy }
            let version = try ObservationFileVersion.read(runtimeURL)
            completedNativeNonce = state.completedNativeNonce
            if recent == nil || runtimeCacheVersion != version {
                recent = try RecencyCoordinator(persisted: state.recency)
                recencyGroup = state.group; recencyMembershipEpoch = state.membershipEpoch
                runtimeCacheVersion = version
            }
            return try LearningImportJournal.restore(state.journal)
        }
        let checkpoint: RimeLearningCheckpoint
        if FileManager.default.fileExists(atPath: stateURL.path) {
            let data = try Data(contentsOf: stateURL)
            guard data.count <= 8 * 1024 * 1024 else { throw InputDataError.oversized }
            checkpoint = try JSONDecoder().decode(RimeLearningCheckpoint.self, from: data)
        } else { checkpoint = try RimeLearningCheckpoint(capacityProfile: LearningCapacityProfiles.expanded10000) }
        if recent == nil { recent = try RecencyCoordinator(capacityProfile: checkpoint.capacityProfile); try recent?.mergeCumulative(checkpoint) }
        return try LearningImportJournal(checkpoint: checkpoint)
    }
    /// Only callers already admitted to host/hidden/utility maintenance use
    /// this. Reading an old journal during keyboard start never migrates it.
    private func adoptCurrentCapacity(_ journal: inout LearningImportJournal) throws {
        guard journal.pending == nil else { throw LearningSyncFailure.busy }
        var nextJournal = journal
        if nextJournal.capacityProfile != LearningCapacityProfiles.expanded10000 {
            try nextJournal.upgradeCapacity(to: LearningCapacityProfiles.expanded10000)
        }
        guard var nextRecent = recent else { throw InputDataError.invalidRecord }
        if nextRecent.model.capacityProfile != LearningCapacityProfiles.expanded10000 {
            try nextRecent.upgradeCapacity(to: LearningCapacityProfiles.expanded10000)
        }
        journal = nextJournal; recent = nextRecent
    }
    private func persist(_ journal: LearningImportJournal, completingNative: UUID? = nil, expectedRuntime: ObservationFileVersion? = nil, expectedLegacy: ObservationFileVersion? = nil) throws {
        var succeeded = false
        defer { if !succeeded { recent = nil; scoreSnapshot = .empty } }
        try ensureEpoch()
        try requireAuthorityWrite(completingNative: completingNative)
        guard let recent else { throw InputDataError.invalidRecord }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(RuntimeState(journal: journal.persistedData(), recency: recent.persisted(), group: recencyGroup, membershipEpoch: recencyMembershipEpoch,
            completedNativeNonce: completingNative ?? completedNativeNonce, personalEpoch: personalEpoch))
        guard data.count <= 12 * 1024 * 1024 else { throw InputDataError.oversized }
        let projection = journal.pending == nil ? try encoder.encode(journal.checkpoint) : nil
        try Self.withAuthorityLock(base: stateURL.deletingLastPathComponent(), wait: false) {
            try ensureEpoch(); try requireAuthorityWrite(completingNative: completingNative)
            if let expectedRuntime, try ObservationFileVersion.read(runtimeURL) != expectedRuntime { throw LearningSyncFailure.busy }
            if let expectedLegacy, try ObservationFileVersion.read(stateURL) != expectedLegacy { throw LearningSyncFailure.busy }
            try persistIfChanged(data, to: runtimeURL)
            // This projection is not an independent authority.
            if let projection { try persistIfChanged(projection, to: stateURL) }
            completedNativeNonce = completingNative ?? completedNativeNonce
            runtimeCacheVersion = try ObservationFileVersion.read(runtimeURL)
        }
        pendingObservationScore = nil
        cloudScoreActive = false
        scoreSnapshot = self.recent?.snapshot(wall: Date().timeIntervalSince1970,
            uptime: ProcessInfo.processInfo.systemUptime, boot: boot) ?? .empty
        if let directory = refreshSharedDirectory, let producer = UUID(uuidString: device),
           let cloud = AppleCloudLearningRankState.read(directory: directory,
                group: rankingPreferences?.string(forKey: "cloud-learning-group").flatMap(UUID.init(uuidString:)) ?? recencyGroup,
                epoch: (rankingPreferences?.object(forKey: "cloud-learning-epoch") as? NSNumber)?.uint64Value ?? recencyMembershipEpoch,
                preferences: rankingPreferences) {
            cloudScoreActive = true; cloudScoreGroup = cloud.group; cloudScoreEpoch = cloud.membershipEpoch
            scoreSnapshot = cloud.snapshot(producer: producer, entries: Array(journal.checkpoint.model.entries.values), uptime: ProcessInfo.processInfo.systemUptime)
        }
        succeeded = true
    }
    /// Canonical data is already fully validated by the caller. Avoid replacing
    /// the full journal and compatibility file when observation changed nothing.
    /// A pending intent is still written before native mutation; equality is the
    /// only skip rule, never a timestamp or inferred local/native count.
    private func persistIfChanged(_ data: Data, to url: URL) throws {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           (attributes[.size] as? NSNumber)?.intValue == data.count,
           let old = try? Data(contentsOf: url, options: .mappedIfSafe), old == data {
            lastCheckpointMetrics.skippedWriteBytes += data.count
            return
        }
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        lastCheckpointMetrics.persistedBytes += data.count
    }
    /// Only an authenticated service adapter calls this. No network or Keychain
    /// work enters NativeEngine's key callbacks.
    func acceptAuthenticatedRecency(policy: RecentLearningPolicy, unixSeconds: Double,
                                    uptime: Double = ProcessInfo.processInfo.systemUptime) throws {
        var journal = try readJournal(); try adoptCurrentCapacity(&journal)
        let clock = try RecentLearningClock(authenticatedUnixSeconds: unixSeconds, uptime: uptime, bootSession: boot)
        try recent?.acceptAuthenticated(policy: policy, clock: clock, validUntilUptime: uptime + 7 * 86400)
        try persist(journal)
    }
    func suspendRecency() {
        recent?.suspend(); scoreSnapshot = .empty
        pendingObservationScore = nil; pendingCloudSnapshot = nil
    }
    func invalidateDatedObservation() { recent?.invalidateObservation() }
    func recencyArchive() throws -> Data { _ = try readJournal(); return try recent!.export() }
    func mergeRecencyArchive(_ data: Data) throws {
        var journal = try readJournal(); guard journal.pending == nil else { throw LearningSyncFailure.busy }
        try adoptCurrentCapacity(&journal)
        try recent?.mergeRemote(data); try persist(journal)
    }
    private func consumeSharedRecency(_ checkpoint: RimeLearningCheckpoint) throws {
        guard let shared = try recencyBridge?.read(), let anchor = shared.anchor,
              anchor.boot == boot else { recent?.suspend(); scoreSnapshot = .empty; return }
        if let group = recencyGroup, group != shared.group {
            recent = try RecencyCoordinator(); try recent?.mergeCumulative(checkpoint)
        }
        let policy = try shared.policy
        var clock = try RecentLearningClock(authenticatedUnixSeconds: anchor.unixSeconds, uptime: anchor.uptime, bootSession: anchor.boot)
        guard clock.day(wallUnixSeconds: Date().timeIntervalSince1970,
                        uptime: ProcessInfo.processInfo.systemUptime, bootSession: boot) != nil else {
            recent?.suspend(); scoreSnapshot = .empty; return
        }
        try recent?.acceptAuthenticated(policy: policy, clock: clock, validUntilUptime: anchor.uptime + 7 * 86400)
        if let data = shared.archive { try recent?.mergeRemote(data) }
        recencyGroup = shared.group; recencyMembershipEpoch = shared.epoch
    }
    /// Immutable committed state only, no native export/import or key access.
    func cloudBootstrapLocation(publisher: SnapshotPublisher?) -> (UUID, URL)? {
        let permitted: Bool
        switch publisher { case .containingApp?: permitted = true; case .keyboard(let full)?: permitted = full; case nil: permitted = false }
        guard permitted, let id = UUID(uuidString: device), let directory = refreshSharedDirectory else { return nil }
        return (id, directory)
    }
    func entries() throws -> [LearningEntry] { Array(try readJournal().checkpoint.model.entries.values) }
    /// Same durable path as manage(); records a cross-device deletion for the next
    /// checkpoint import and cloud publication.
    func forget(reading: String, text: String, knownCloudGeneration: UInt64 = 0) throws {
        try requireAuthorityWrite()
        let expectedRuntime = try ObservationFileVersion.read(runtimeURL), expectedLegacy = try ObservationFileVersion.read(stateURL)
        let old = try readJournal(); guard old.pending == nil else { throw LearningSyncFailure.busy }
        var state = old.checkpoint
        try state.forget(reading: reading, text: text, knownCloudGeneration: knownCloudGeneration)
        try recent?.mergeCumulative(state)
        try persist(LearningImportJournal(checkpoint: state), expectedRuntime: expectedRuntime, expectedLegacy: expectedLegacy)
    }
    func manage(reading: String, text: String, pinned: Bool?) throws {
        try requireAuthorityWrite()
        let expectedRuntime = try ObservationFileVersion.read(runtimeURL), expectedLegacy = try ObservationFileVersion.read(stateURL)
        let old = try readJournal(); guard old.pending == nil else { throw LearningSyncFailure.busy }
        // User candidate controls retain the already loaded profile. Capacity
        // migration belongs to the next admitted idle/host checkpoint.
        var state = old.checkpoint
        if let pinned { try state.setPinned(reading: reading, text: text, pinned: pinned, device: device) }
        else { try state.resetFrequency(reading: reading, text: text) }
        try recent?.mergeCumulative(state)
        try persist(LearningImportJournal(checkpoint: state), expectedRuntime: expectedRuntime, expectedLegacy: expectedLegacy)
    }
    /// The utility lane owns this detached value snapshot exclusively. It makes
    /// no native calls; only admitted stat/epoch-guarded methods may persist.
    func detachedObservationOwner() -> LocalLearningCoordinator {
        LocalLearningCoordinator(observationSource: self)
    }
    private init(observationSource source: LocalLearningCoordinator) {
        personalEpoch = source.personalEpoch; boot = source.boot
        rankingPreferences = source.rankingPreferences; stateURL = source.stateURL
        device = source.device; shared = source.shared; recencyBridge = source.recencyBridge
        refreshSharedDirectory = source.refreshSharedDirectory
        completedNativeNonce = source.completedNativeNonce; runtimeCacheVersion = source.runtimeCacheVersion
        recent = source.recent; recencyGroup = source.recencyGroup
        recencyMembershipEpoch = source.recencyMembershipEpoch
        cloudScoreActive = source.cloudScoreActive; cloudScoreGroup = source.cloudScoreGroup
        cloudScoreEpoch = source.cloudScoreEpoch; storedScoreSnapshot = source.storedScoreSnapshot
    }
    fileprivate struct ObservationFileVersion: Codable, Equatable {
        let exists: Bool
        let inode: UInt64
        let size: UInt64
        let modified: Date?
        static func read(_ url: URL) throws -> Self {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else { throw InputDataError.invalidRecord }
                return .init(exists: true, inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                    size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0, modified: attributes[.modificationDate] as? Date)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
                [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
                return .init(exists: false, inode: 0, size: 0, modified: nil)
            }
        }
    }
    struct PreparedObservation {
        fileprivate let runtimeVersion: ObservationFileVersion
        fileprivate let legacyVersion: ObservationFileVersion
        fileprivate let owner: LocalLearningCoordinator
        fileprivate let runtime: Data
        fileprivate let legacy: Data
        fileprivate let runtimeChanged: Bool
        fileprivate let legacyChanged: Bool
        fileprivate let outbound: Data
        fileprivate let recency: Data?
        let entries: [LearningEntry]
    }
    /// Only the no-native-mutation path may be planned. A pending intent,
    /// remote reset, changed pin or native count difference needs the existing
    /// quiescent transaction instead; rejecting never writes a pending intent.
    func prepareObservation(exported: Data, allowDatedLearning: Bool) throws -> PreparedObservation? {
        let runtimeVersion = try ObservationFileVersion.read(runtimeURL)
        let legacyVersion = try ObservationFileVersion.read(stateURL)
        try requireAuthorityWrite()
        var journal = try readJournal()
        guard journal.pending == nil else { return nil }
        try adoptCurrentCapacity(&journal); try ensureEpoch()
        let before = journal.checkpoint
        try consumeSharedRecency(before); try ensureEpoch()
        var remoteModel = try LearningModel(capacityProfile: LearningCapacityProfiles.expanded10000)
        try remoteModel.merge(shared?.read() ?? before.outboundArchive())
        if let recent { try remoteModel.merge(recent.model.cumulativeProjection()) }
        var observed = before; try observed.observeExport(exported, device: device); try ensureEpoch()
        try recent?.observe(before: before, after: observed, replica: device,
            wall: Date().timeIntervalSince1970, uptime: ProcessInfo.processInfo.systemUptime,
            boot: boot, canDate: allowDatedLearning, validating: maintenancePermitted)
        try ensureEpoch()
        let intent = try journal.prepare(finalLocalExport: exported, remoteArchive: remoteModel.export(), device: device)
        let actual = Dictionary(uniqueKeysWithValues: try RimeLearningFormat.parseExport(exported, capacityProfile: LearningCapacityProfiles.expanded10000).map { ($0.id, $0.count) })
        guard intent.target.model.entries.values.allSatisfy({ entry in
            let prior = before.model.entries[entry.id]
            return (actual[entry.id] ?? 0) == (entry.deleted ? 0 : entry.frequency) &&
                entry.pinned == (prior?.pinned ?? false) && entry.pinVersion == (prior?.pinVersion ?? .init(sequence: 0, device: "")) &&
                entry.generation == (prior?.generation ?? 0) && entry.deleted == (prior?.deleted ?? false)
        }) else { return nil }
        try recent?.mergeCumulative(intent.target)
        try journal.commit(transactionID: intent.id, actualEngineExport: exported)
        guard let recent else { throw InputDataError.invalidRecord }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let runtime = try encoder.encode(RuntimeState(journal: journal.persistedData(), recency: recent.persisted(), group: recencyGroup, membershipEpoch: recencyMembershipEpoch,
            completedNativeNonce: completedNativeNonce, personalEpoch: personalEpoch))
        let legacy = try encoder.encode(journal.checkpoint)
        guard runtime.count <= 12 * 1024 * 1024, legacy.count <= 8 * 1024 * 1024 else { throw InputDataError.oversized }
        cloudScoreActive = false
        scoreSnapshot = self.recent?.snapshot(wall: Date().timeIntervalSince1970,
            uptime: ProcessInfo.processInfo.systemUptime, boot: boot) ?? .empty
        if let directory = refreshSharedDirectory, let producer = UUID(uuidString: device),
           let cloud = AppleCloudLearningRankState.read(directory: directory,
                group: rankingPreferences?.string(forKey: "cloud-learning-group").flatMap(UUID.init(uuidString:)) ?? recencyGroup,
                epoch: (rankingPreferences?.object(forKey: "cloud-learning-epoch") as? NSNumber)?.uint64Value ?? recencyMembershipEpoch,
                preferences: rankingPreferences) {
            cloudScoreActive = true; cloudScoreGroup = cloud.group; cloudScoreEpoch = cloud.membershipEpoch
            scoreSnapshot = cloud.snapshot(producer: producer, entries: Array(journal.checkpoint.model.entries.values), uptime: ProcessInfo.processInfo.systemUptime)
        }
        guard try ObservationFileVersion.read(runtimeURL) == runtimeVersion,
              try ObservationFileVersion.read(stateURL) == legacyVersion else { throw LearningSyncFailure.busy }
        return .init(runtimeVersion: runtimeVersion, legacyVersion: legacyVersion, owner: self, runtime: runtime, legacy: legacy,
            runtimeChanged: (try? Data(contentsOf: runtimeURL, options: .mappedIfSafe)) != runtime,
            legacyChanged: (try? Data(contentsOf: stateURL, options: .mappedIfSafe)) != legacy,
            outbound: try journal.outboundArchive(), recency: try self.recent?.export(),
            entries: Array(journal.checkpoint.model.entries.values))
    }
    struct CompletedObservation {
        fileprivate let prepared: PreparedObservation
        fileprivate let runtimeVersion: ObservationFileVersion
        fileprivate let legacyVersion: ObservationFileVersion
        let metrics: LearningCheckpointMetrics
        var entries: [LearningEntry] { prepared.entries }
    }
    /// Detached IO owner only. The captured native baseline can commit while
    /// new input continues: later native increments remain for the next round.
    /// A concurrent control/reset must still match the original authority.
    func persistObservation(_ prepared: PreparedObservation) throws -> CompletedObservation {
        try ensureEpoch()
        guard prepared.owner.stateURL == stateURL, prepared.owner.device == device,
              prepared.owner.personalEpoch == personalEpoch else { throw LearningSyncFailure.busy }
        var metrics = LearningCheckpointMetrics()
        func replace(_ bytes: Data, at url: URL, changed: Bool) throws {
            try ensureEpoch()
            guard changed else { metrics.skippedWriteBytes += bytes.count; return }
            #if os(iOS)
            try bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try bytes.write(to: url, options: .atomic)
            #endif
            metrics.persistedBytes += bytes.count
        }
        var runtime: ObservationFileVersion!, legacy: ObservationFileVersion!
        try Self.withAuthorityLock(base: stateURL.deletingLastPathComponent(), wait: false) {
            try ensureEpoch(); try requireAuthorityWrite()
            guard try ObservationFileVersion.read(runtimeURL) == prepared.runtimeVersion,
                  try ObservationFileVersion.read(stateURL) == prepared.legacyVersion else { throw LearningSyncFailure.busy }
            try replace(prepared.runtime, at: runtimeURL, changed: prepared.runtimeChanged)
            try replace(prepared.legacy, at: stateURL, changed: prepared.legacyChanged)
            runtime = try ObservationFileVersion.read(runtimeURL); legacy = try ObservationFileVersion.read(stateURL)
        }
        runtimeCacheVersion = runtime; metrics.completed = true; lastCheckpointMetrics = metrics
        return .init(prepared: prepared, runtimeVersion: runtime, legacyVersion: legacy, metrics: metrics)
    }
    /// Original main owner adopts only metadata after IO. A newer control wins;
    /// ranking remains staged until a new composition, never a visible refresh.
    func adoptObservation(_ value: CompletedObservation) throws -> Bool {
        try ensureEpoch()
        let prepared = value.prepared
        guard prepared.owner.stateURL == stateURL, prepared.owner.device == device,
              prepared.owner.personalEpoch == personalEpoch,
              try ObservationFileVersion.read(runtimeURL) == value.runtimeVersion,
              try ObservationFileVersion.read(stateURL) == value.legacyVersion else { return false }
        runtimeCacheVersion = value.runtimeVersion
        completedNativeNonce = prepared.owner.completedNativeNonce
        recent = prepared.owner.recent; recencyGroup = prepared.owner.recencyGroup
        recencyMembershipEpoch = prepared.owner.recencyMembershipEpoch
        pendingObservationScore = (prepared.owner.storedScoreSnapshot, prepared.owner.cloudScoreActive,
            prepared.owner.cloudScoreGroup, prepared.owner.cloudScoreEpoch)
        lastCheckpointMetrics = value.metrics
        return true
    }
    /// Retained synchronous host-test adapter; product routes use detached IO.
    func commitObservation(_ prepared: PreparedObservation) throws {
        guard prepared.owner.stateURL == stateURL, prepared.owner.device == device, prepared.owner.personalEpoch == personalEpoch else { throw LearningSyncFailure.busy }
        let value = try prepared.owner.persistObservation(prepared)
        guard try adoptObservation(value) else { throw LearningSyncFailure.busy }
    }
    /// Pure publication uses immutable prepared bytes on utility, after the
    /// local authority committed. Existing shared publishers merge under lock.
    func publishObservation(_ prepared: PreparedObservation, by publish: SnapshotPublisher?) throws {
        try ensureEpoch()
        guard let publish, let shared else { return }
        try ensureEpoch(); try shared.publish(prepared.outbound, by: publish)
        try ensureEpoch()
        if let root = refreshSharedDirectory, let producer = UUID(uuidString: device) {
            try AppleCloudProducerSnapshot.publish(prepared.entries, producer: producer, directory: root)
        }
        if let group = prepared.owner.recencyGroup, let epoch = prepared.owner.recencyMembershipEpoch,
           let archive = prepared.recency {
            _ = try recencyBridge?.mergeIfCurrent(archive, group: group, epoch: epoch, validating: maintenancePermitted)
        }
    }
    enum NativePhase: String { case started = "S", done = "D", replayDone = "R" }
    struct NativePhaseStamp {
        let nonce: UUID
        let phase: NativePhase
    }
    struct PreparedNativeCheckpoint {
        fileprivate let nonce: UUID
        fileprivate let directory: URL
        fileprivate let runtimeVersion: ObservationFileVersion
        fileprivate let legacyVersion: ObservationFileVersion
        fileprivate let owner: LocalLearningCoordinator
        let importFile: URL
        let actualFile: URL
        let resets: [LearningEntry]
        let pins: [LearningEntry]
        let requiresImport: Bool
        let alreadyDone: Bool
        let alreadyCommitted: Bool
        fileprivate let replay: Bool
        fileprivate let hasPreparedRecency: Bool
    }
    struct CompletedNativeCheckpoint {
        fileprivate let owner: LocalLearningCoordinator
        fileprivate let runtimeVersion: ObservationFileVersion
        fileprivate let legacyVersion: ObservationFileVersion
        let entries: [LearningEntry]
        let metrics: LearningCheckpointMetrics
    }
    private struct NativePlan: Codable {
        var version = 1
        let profile: LearningCapacityReference
        let nonce: UUID
        let personalEpoch: String
        let runtimeVersion: ObservationFileVersion
        let legacyVersion: ObservationFileVersion
        let journal: Data
        let recency: RecencyCoordinator.Persisted
        let group: UUID?
        let membershipEpoch: UInt64?
        let originalPending: Bool
        let requiresImport: Bool
    }
    private var nativeBase: URL { stateURL.deletingLastPathComponent() }
    private var nativePhaseURL: URL { nativeBase.appendingPathComponent(Self.nativePhaseFilename) }
    private func nativeDirectory(_ nonce: UUID) -> URL {
        nativeBase.appendingPathComponent("Checkpoint-" + nonce.uuidString, isDirectory: true)
    }
    /// A bounded phase read only; never decode the derived target on main.
    func nativeCheckpointPhase() throws -> NativePhaseStamp? {
        try ensureEpoch()
        guard FileManager.default.fileExists(atPath: nativePhaseURL.path) else { return nil }
        let stamp = try ObservationFileVersion.read(nativePhaseURL)
        guard stamp.size <= 128 else { throw InputDataError.oversized }
        let data = try Data(contentsOf: nativePhaseURL)
        guard data.count <= 128, let text = String(data: data, encoding: .utf8) else { throw InputDataError.invalidRecord }
        let parts = text.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3, let nonce = UUID(uuidString: String(parts[0])),
              parts[1] == personalEpoch, let phase = NativePhase(rawValue: String(parts[2])) else { throw LearningSyncFailure.busy }
        return .init(nonce: nonce, phase: phase)
    }
    private func requireAuthorityWrite(completingNative: UUID? = nil) throws {
        guard let phase = try nativeCheckpointPhase() else { return }
        guard phase.nonce == completingNative, phase.phase != .started else { throw LearningSyncFailure.busy }
    }
    private func writeNativePhase(_ nonce: UUID, _ phase: NativePhase) throws {
        try ensureEpoch()
        let data = Data((nonce.uuidString + "|" + personalEpoch + "|" + phase.rawValue).utf8)
        guard data.count <= 128 else { throw InputDataError.oversized }
        #if os(iOS)
        try data.write(to: nativePhaseURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: nativePhaseURL, options: .atomic)
        #endif
    }
    private func readNativePlan(_ directory: URL) throws -> NativePlan {
        let file = directory.appendingPathComponent("native-plan-v2.json")
        let stamp = try ObservationFileVersion.read(file)
        guard stamp.exists, stamp.size <= UInt64(LearningCapacityProfiles.expanded10000.runtimeBytes) else { throw InputDataError.oversized }
        let data = try Data(contentsOf: file)
        guard data.count <= LearningCapacityProfiles.expanded10000.runtimeBytes else { throw InputDataError.oversized }
        let plan = try JSONDecoder().decode(NativePlan.self, from: data)
        guard plan.version == 1, try plan.profile.resolved() == LearningCapacityProfiles.expanded10000,
              plan.personalEpoch == personalEpoch, nativeDirectory(plan.nonce) == directory else { throw LearningSyncFailure.busy }
        return plan
    }
    /// Utility-only derived preparation. No authoritative pending journal is
    /// published until a native batch really begins; cancellation loses no use.
    func prepareNativeCheckpoint(exported: Data?, directory: URL, allowDatedLearning: Bool) throws -> PreparedNativeCheckpoint {
        try ensureEpoch()
        if let phase = try nativeCheckpointPhase() {
            let existingDirectory = nativeDirectory(phase.nonce), plan = try readNativePlan(existingDirectory)
            let journal = try readJournal()
            let committed = completedNativeNonce == phase.nonce
            let diskJournal = try LearningImportJournal.restore(plan.journal)
            guard let intent = diskJournal.pending else { throw InputDataError.invalidRecord }
            if !committed, phase.phase == .started {
                guard let exported else { throw LearningSyncFailure.exportFailed }
                let counts = Dictionary(uniqueKeysWithValues: try RimeLearningFormat.parseExport(exported, capacityProfile: LearningCapacityProfiles.expanded10000).map { ($0.id, $0.count) })
                // Reset replay is not MAX-idempotent. Keep the original intent
                // if its reset result cannot be proved; never erase later D.
                for row in intent.target.pendingResets {
                    guard counts[row.id, default: 0] == row.frequency else { throw LearningSyncFailure.busy }
                }
            }
            let runtime = try ObservationFileVersion.read(runtimeURL), legacy = try ObservationFileVersion.read(stateURL)
            guard committed || (runtime == plan.runtimeVersion && legacy == plan.legacyVersion) else { throw LearningSyncFailure.busy }
            _ = journal // validates the current authority before recovering.
            return .init(nonce: plan.nonce, directory: existingDirectory, runtimeVersion: runtime, legacyVersion: legacy,
                owner: self, importFile: existingDirectory.appendingPathComponent("incoming.tsv"), actualFile: existingDirectory.appendingPathComponent("actual.tsv"),
                resets: [], pins: intent.target.model.entries.values.filter { !$0.deleted && $0.pinned },
                requiresImport: !committed && phase.phase == .started, alreadyDone: phase.phase != .started,
                alreadyCommitted: committed, replay: phase.phase == .started || phase.phase == .replayDone, hasPreparedRecency: false)
        }
        guard let exported, let nonce = UUID(uuidString: directory.lastPathComponent.replacingOccurrences(of: "Checkpoint-", with: "")),
              nativeDirectory(nonce) == directory else { throw InputDataError.invalidRecord }
        let runtime = try ObservationFileVersion.read(runtimeURL), legacy = try ObservationFileVersion.read(stateURL)
        var journal = try readJournal()
        let originalPending = journal.pending != nil
        let intent: LearningImportJournal.Intent
        let counts = Dictionary(uniqueKeysWithValues: try RimeLearningFormat.parseExport(exported, capacityProfile: LearningCapacityProfiles.expanded10000).map { ($0.id, $0.count) })
        if let pending = journal.pending {
            for row in pending.target.pendingResets {
                guard counts[row.id, default: 0] == row.frequency else { throw LearningSyncFailure.busy }
            }
            intent = pending
        } else {
            try adoptCurrentCapacity(&journal); try consumeSharedRecency(journal.checkpoint)
            let before = journal.checkpoint
            var remote = try LearningModel(capacityProfile: LearningCapacityProfiles.expanded10000)
            try remote.merge(shared?.read() ?? before.outboundArchive())
            if let recent { try remote.merge(recent.model.cumulativeProjection()) }
            var observed = before; try observed.observeExport(exported, device: device)
            try recent?.observe(before: before, after: observed, replica: device,
                wall: Date().timeIntervalSince1970, uptime: ProcessInfo.processInfo.systemUptime, boot: boot, canDate: allowDatedLearning, validating: maintenancePermitted)
            try ensureEpoch()
            intent = try journal.prepare(finalLocalExport: exported, remoteArchive: remote.export(), device: device)
            try recent?.mergeCumulative(intent.target)
        }
        guard let recent else { throw InputDataError.invalidRecord }
        let needsImport = originalPending || !intent.target.model.entries.values.allSatisfy { counts[$0.id, default: 0] == ($0.deleted ? 0 : $0.frequency) }
        let plan = NativePlan(profile: .init(LearningCapacityProfiles.expanded10000), nonce: nonce, personalEpoch: personalEpoch,
            runtimeVersion: runtime, legacyVersion: legacy, journal: try journal.persistedData(), recency: try recent.persisted(),
            group: recencyGroup, membershipEpoch: recencyMembershipEpoch, originalPending: originalPending, requiresImport: needsImport)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(plan), input = try intent.nativeImportTSV()
        guard data.count <= LearningCapacityProfiles.expanded10000.runtimeBytes else { throw InputDataError.oversized }
        try ensureEpoch()
        try Self.withAuthorityLock(base: nativeBase, wait: false) {
            try ensureEpoch(); try requireAuthorityWrite()
            guard try ObservationFileVersion.read(runtimeURL) == runtime,
                  try ObservationFileVersion.read(stateURL) == legacy else { throw LearningSyncFailure.busy }
            try input.write(to: directory.appendingPathComponent("incoming.tsv"), options: .atomic)
            try data.write(to: directory.appendingPathComponent("native-plan-v2.json"), options: .atomic)
        }
        return .init(nonce: nonce, directory: directory, runtimeVersion: runtime, legacyVersion: legacy,
            owner: self, importFile: directory.appendingPathComponent("incoming.tsv"), actualFile: directory.appendingPathComponent("actual.tsv"),
            resets: originalPending || !needsImport ? [] : intent.target.pendingResets,
            pins: intent.target.model.entries.values.filter { !$0.deleted && $0.pinned },
            requiresImport: needsImport, alreadyDone: false, alreadyCommitted: false, replay: false, hasPreparedRecency: true)
    }
    /// Called only inside the native main-owner batch after its admission.
    func beginPreparedNative(_ plan: PreparedNativeCheckpoint) throws {
        try ensureEpoch()
        guard try ObservationFileVersion.read(runtimeURL) == plan.runtimeVersion,
              try ObservationFileVersion.read(stateURL) == plan.legacyVersion else { throw LearningSyncFailure.busy }
        if let old = try nativeCheckpointPhase() { guard old.nonce == plan.nonce, old.phase == .started else { throw LearningSyncFailure.busy } }
        try writeNativePhase(plan.nonce, .started)
    }
    /// Must run after actual export succeeds, BEFORE the normal session reopens.
    func completePreparedNative(_ plan: PreparedNativeCheckpoint) throws {
        guard let old = try nativeCheckpointPhase(), old.nonce == plan.nonce, old.phase == .started else { throw LearningSyncFailure.busy }
        try writeNativePhase(plan.nonce, plan.replay ? .replayDone : .done)
    }
    func discardPreparedNative(_ plan: PreparedNativeCheckpoint) throws {
        try ensureEpoch()
        guard try nativeCheckpointPhase()?.nonce != plan.nonce else { return }
        if FileManager.default.fileExists(atPath: plan.directory.path) { try FileManager.default.removeItem(at: plan.directory) }
    }
    func finishPreparedNative(_ prepared: PreparedNativeCheckpoint) throws -> CompletedNativeCheckpoint {
        try ensureEpoch()
        guard let phase = try nativeCheckpointPhase(), phase.nonce == prepared.nonce,
              phase.phase != .started else { throw LearningSyncFailure.busy }
        let plan = try readNativePlan(prepared.directory)
        let current = try readJournal()
        lastCheckpointMetrics = LearningCheckpointMetrics()
        if completedNativeNonce != plan.nonce {
            guard try ObservationFileVersion.read(runtimeURL) == prepared.runtimeVersion,
                  try ObservationFileVersion.read(stateURL) == prepared.legacyVersion else { throw LearningSyncFailure.busy }
            var journal = try LearningImportJournal.restore(plan.journal)
            guard let original = journal.pending else { throw InputDataError.invalidRecord }
            // An in-process prepared owner retains its trusted clock proof.
            // Restart recovery deliberately reconstructs only persisted state.
            if !prepared.hasPreparedRecency || recent?.model.capacityProfile != original.target.capacityProfile || prepared.replay || plan.originalPending {
                recent = try RecencyCoordinator(persisted: plan.recency)
            }
            recencyGroup = plan.group; recencyMembershipEpoch = plan.membershipEpoch
            let actual = try Data(contentsOf: prepared.actualFile)
            guard actual.count <= LearningCapacityProfiles.expanded10000.nativeTsvBytes else { throw InputDataError.oversized }
            if plan.originalPending || phase.phase == .replayDone {
                try journal.commitThenUpgradeCapacity(transactionID: original.id, actualEngineExport: actual, to: LearningCapacityProfiles.expanded10000)
                var recovered = journal.checkpoint, increments: [LearningEntry] = []
                for word in try RimeLearningFormat.parseExport(actual, capacityProfile: LearningCapacityProfiles.expanded10000) {
                    let expected = original.target.model.entries[word.id]?.frequency ?? 0
                    if word.count > expected {
                        var row = original.target.model.entries[word.id] ?? LearningEntry(reading: word.reading, text: word.text)
                        if !row.deleted { row.counts[device] = min(1_000_000_000, (row.counts[device] ?? 0) + word.count - expected); increments.append(row) }
                    }
                }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                try recovered.mergeRemoteArchive(encoder.encode(LearningArchive(entries: increments, capacityProfile: LearningCapacityProfiles.expanded10000)))
                journal = try LearningImportJournal(checkpoint: recovered)
                try recent?.upgradeCapacity(to: LearningCapacityProfiles.expanded10000)
                try recent?.mergeCumulative(recovered); recent?.invalidateObservation()
            } else { try journal.commit(transactionID: original.id, actualEngineExport: actual) }
            try persist(journal, completingNative: plan.nonce)
        } else {
            // Runtime committed before a crash/IO error: do not count excess or
            // rerun the original target. Repair only the secondary projection.
            try persist(current, completingNative: plan.nonce)
        }
        let complete = try readJournal()
        let runtime = try ObservationFileVersion.read(runtimeURL), legacy = try ObservationFileVersion.read(stateURL)
        try ensureEpoch()
        try Self.withAuthorityLock(base: nativeBase, wait: false) {
            try ensureEpoch()
            guard try nativeCheckpointPhase()?.nonce == plan.nonce,
                  try ObservationFileVersion.read(runtimeURL) == runtime,
                  try ObservationFileVersion.read(stateURL) == legacy else { throw LearningSyncFailure.busy }
            try FileManager.default.removeItem(at: nativePhaseURL)
            if FileManager.default.fileExists(atPath: prepared.directory.path) { try FileManager.default.removeItem(at: prepared.directory) }
        }
        lastCheckpointMetrics.completed = true
        return .init(owner: self, runtimeVersion: runtime, legacyVersion: legacy,
            entries: Array(complete.checkpoint.model.entries.values), metrics: lastCheckpointMetrics)
    }
    /// Main adopts only metadata/pointers. A later local control wins over this
    /// result; no JSON reload, native call or visible candidate refresh occurs.
    func adoptCompletedNative(_ value: CompletedNativeCheckpoint) throws -> Bool {
        try ensureEpoch()
        guard value.owner.stateURL == stateURL, value.owner.personalEpoch == personalEpoch,
              try ObservationFileVersion.read(runtimeURL) == value.runtimeVersion,
              try ObservationFileVersion.read(stateURL) == value.legacyVersion else { return false }
        recent = value.owner.recent; recencyGroup = value.owner.recencyGroup; recencyMembershipEpoch = value.owner.recencyMembershipEpoch
        completedNativeNonce = value.owner.completedNativeNonce; runtimeCacheVersion = value.runtimeVersion
        pendingObservationScore = (value.owner.storedScoreSnapshot, value.owner.cloudScoreActive, value.owner.cloudScoreGroup, value.owner.cloudScoreEpoch)
        lastCheckpointMetrics = value.metrics
        return true
    }
    func publishCompletedNative(_ value: CompletedNativeCheckpoint, by publisher: SnapshotPublisher?) throws {
        try ensureEpoch()
        guard let publisher, let shared else { return }
        let journal = try readJournal()
        try shared.publish(journal.outboundArchive(), by: publisher)
        try ensureEpoch()
        if let directory = refreshSharedDirectory, let id = UUID(uuidString: device) {
            try AppleCloudProducerSnapshot.publish(value.entries, producer: id, directory: directory)
        }
        if let group = recencyGroup, let epoch = recencyMembershipEpoch, let recent {
            _ = try recencyBridge?.mergeIfCurrent(recent.export(), group: group, epoch: epoch, validating: maintenancePermitted)
        }
    }
    enum NativeCheckpointStage { case preparing, prepared, applying, committed }
    /// A learning-specific scheduler. Only the two supplied native closures run
    /// on main; full model IO/JSON and authority commits stay on the utility lane.
    func synchronizeNativeCheckpoint(queue: DispatchQueue, allowDatedLearning: Bool,
        mayCommit: @escaping () -> Bool, stage: @escaping (NativeCheckpointStage) -> Void,
        exportNative: @escaping (URL) throws -> Void,
        applyNative: @escaping (PreparedNativeCheckpoint, () throws -> Void, () throws -> Void) throws -> Void,
        completion: @escaping (Result<CompletedNativeCheckpoint, Error>) -> Void) {
        let nonce = UUID(), directory = nativeDirectory(nonce), initialExport = directory.appendingPathComponent("engine.tsv")
        func finish(_ prepared: PreparedNativeCheckpoint) {
            queue.async {
                let result: Result<CompletedNativeCheckpoint, Error>
                do { result = .success(try prepared.owner.finishPreparedNative(prepared)) }
                catch { result = .failure(error) }
                DispatchQueue.main.async {
                    if case .success = result { stage(.committed) }
                    completion(result)
                }
            }
        }
        func prepared(_ value: PreparedNativeCheckpoint) {
            DispatchQueue.main.async {
                stage(.prepared)
                if value.alreadyDone || value.alreadyCommitted { finish(value); return }
                guard mayCommit() else {
                    queue.async {
                        try? value.owner.discardPreparedNative(value)
                        DispatchQueue.main.async { completion(.failure(LearningSyncFailure.busy)) }
                    }
                    return
                }
                do {
                    stage(.applying)
                    try Self.withAuthorityLock(base: self.nativeBase, wait: false) {
                        try value.owner.ensureEpoch()
                        try applyNative(value, { try value.owner.beginPreparedNative(value) }, { try value.owner.completePreparedNative(value) })
                    }
                    finish(value)
                } catch {
                    queue.async {
                        try? value.owner.discardPreparedNative(value)
                        DispatchQueue.main.async { completion(.failure(error)) }
                    }
                }
            }
        }
        queue.async {
            do {
                try self.ensureEpoch()
                let phase = try self.nativeCheckpointPhase()
                if let phase, phase.phase != .started {
                    stage(.preparing)
                    let value = try autoreleasepool { try self.prepareNativeCheckpoint(exported: nil, directory: directory, allowDatedLearning: allowDatedLearning) }
                    prepared(value); return
                }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                DispatchQueue.main.async {
                    guard mayCommit() else {
                        queue.async { try? FileManager.default.removeItem(at: directory); DispatchQueue.main.async { completion(.failure(LearningSyncFailure.busy)) } }; return
                    }
                    do {
                        try Self.withAuthorityLock(base: self.nativeBase, wait: false) { try self.ensureEpoch(); try exportNative(initialExport) }
                        queue.async {
                            do {
                                stage(.preparing)
                                let value = try autoreleasepool { try self.prepareNativeCheckpoint(exported: Data(contentsOf: initialExport), directory: directory, allowDatedLearning: allowDatedLearning) }
                                if value.directory != directory { try? FileManager.default.removeItem(at: directory) }
                                prepared(value)
                            } catch { try? FileManager.default.removeItem(at: directory); DispatchQueue.main.async { completion(.failure(error)) } }
                        }
                    } catch { queue.async { try? FileManager.default.removeItem(at: directory); DispatchQueue.main.async { completion(.failure(error)) } } }
                }
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }

    func checkpoint(exportFile: URL, importFile: URL, publish: SnapshotPublisher?, engineExport: (URL) -> Int32, engineImport: (URL) -> Int32, engineReset: (LearningEntry) -> Int32, allowDatedLearning: Bool = true) throws -> [LearningEntry] {
        try requireAuthorityWrite()
        let started = ProcessInfo.processInfo.systemUptime
        lastCheckpointMetrics = LearningCheckpointMetrics()
        var completed = false
        defer {
            lastCheckpointMetrics.elapsedMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
            lastCheckpointMetrics.completed = completed
            if !completed { recent = nil; scoreSnapshot = .empty }
        }
        var journal = try readJournal()
        guard engineExport(exportFile) >= 0 else { throw LearningSyncFailure.exportFailed }
        var exported = try Data(contentsOf: exportFile)
        if let intent = journal.pending {
            lastCheckpointMetrics.recoveredPending = true
            // MAX import is idempotent and preserves any post-crash input. Reset
            // replay is not: prove its desired result in the actual native DB,
            // otherwise leave sync pending while normal typing remains usable.
            let counts = Dictionary(uniqueKeysWithValues: try RimeLearningFormat.parseExport(exported, capacityProfile: LearningCapacityProfiles.expanded10000).map { ($0.id, $0.count) })
            for entry in intent.target.pendingResets {
                guard (counts[entry.id] ?? 0) == entry.frequency else { throw LearningSyncFailure.busy }
            }
            try intent.nativeImportTSV().write(to: importFile, options: .atomic)
            lastCheckpointMetrics.nativeImports += 1
            guard engineImport(importFile) >= 0, engineExport(exportFile) >= 0 else { throw LearningSyncFailure.importFailed }
            exported = try Data(contentsOf: exportFile)
            try journal.commitThenUpgradeCapacity(transactionID: intent.id, actualEngineExport: exported,
                to: LearningCapacityProfiles.expanded10000)
            // Preserve provable excess above the desired imported snapshot as
            // undated cumulative use. It must never become a fresh daily bucket.
            var recovered = journal.checkpoint
            var excess = try LearningModel(capacityProfile: LearningCapacityProfiles.expanded10000)
            for word in try RimeLearningFormat.parseExport(exported, capacityProfile: LearningCapacityProfiles.expanded10000) {
                let expected = intent.target.model.entries[word.id]?.frequency ?? 0
                if word.count > expected {
                    var entry = intent.target.model.entries[word.id] ?? LearningEntry(reading: word.reading, text: word.text)
                    if !entry.deleted {
                        entry.counts[device] = min(1_000_000_000, (entry.counts[device] ?? 0) + word.count - expected)
                        let data = try JSONEncoder().encode(LearningArchive(entries: [entry], capacityProfile: LearningCapacityProfiles.expanded10000))
                        try excess.merge(data)
                    }
                }
            }
            try recovered.mergeRemoteArchive(excess.export())
            journal = try LearningImportJournal(checkpoint: recovered)
            try recent?.upgradeCapacity(to: LearningCapacityProfiles.expanded10000)
            try recent?.mergeCumulative(journal.checkpoint); recent?.invalidateObservation()
            try persist(journal)
        }
        try adoptCurrentCapacity(&journal)
        try consumeSharedRecency(journal.checkpoint)
        let before = journal.checkpoint
        var remoteModel = try LearningModel(capacityProfile: LearningCapacityProfiles.expanded10000)
        try remoteModel.merge(shared?.read() ?? before.outboundArchive())
        if let recent { try remoteModel.merge(recent.model.cumulativeProjection()) }
        let remote = try remoteModel.export()
        // prepare observes the final local export before merging incoming data.
        // Date only the pure local delta, before the remote MAX components exist.
        var observed = before; try observed.observeExport(exported, device: device)
        try recent?.observe(before: before, after: observed, replica: device,
            wall: Date().timeIntervalSince1970, uptime: ProcessInfo.processInfo.systemUptime,
            boot: boot, canDate: allowDatedLearning)
        let intent = try journal.prepare(finalLocalExport: exported, remoteArchive: remote, device: device)
        try recent?.mergeCumulative(intent.target)
        let actualCounts = Dictionary(uniqueKeysWithValues: try RimeLearningFormat.parseExport(exported, capacityProfile: LearningCapacityProfiles.expanded10000).map { ($0.id, $0.count) })
        let alreadyApplied = intent.target.model.entries.values.allSatisfy { entry in
            (actualCounts[entry.id] ?? 0) == (entry.deleted ? 0 : entry.frequency)
        }
        if alreadyApplied {
            // A local-only observation changes no native state. Commit the
            // proved actual baseline once, without a redundant import/reset or
            // durable pending intent on the common idle checkpoint path.
            try journal.commit(transactionID: intent.id, actualEngineExport: exported)
        } else {
            try persist(journal) // durable intent BEFORE any native mutation
            for entry in intent.target.pendingResets {
                lastCheckpointMetrics.nativeResets += 1
                guard engineReset(entry) >= 0 else { throw LearningSyncFailure.importFailed }
            }
            try intent.nativeImportTSV().write(to: importFile, options: .atomic)
            lastCheckpointMetrics.nativeImports += 1
            guard engineImport(importFile) >= 0 else { throw LearningSyncFailure.importFailed }
            guard engineExport(exportFile) >= 0 else { throw LearningSyncFailure.exportFailed }
            try journal.commit(transactionID: intent.id, actualEngineExport: Data(contentsOf: exportFile))
        }
        try persist(journal)
        if let publish, let shared {
            try shared.publish(journal.outboundArchive(), by: publish)
            if let root = refreshSharedDirectory, let producer = UUID(uuidString: device) {
                try AppleCloudProducerSnapshot.publish(Array(journal.checkpoint.model.entries.values), producer: producer, directory: root)
            }
            if let group = recencyGroup, let epoch = recencyMembershipEpoch, let recent {
                // Permission of the existing v1 publisher is checked before v2.
                _ = try recencyBridge?.mergeIfCurrent(recent.export(), group: group, epoch: epoch, validating: maintenancePermitted)
            }
        }
        completed = true
        return Array(journal.checkpoint.model.entries.values)
    }

}

enum PersonalLexiconLocation {
    static var directory:URL? {
        #if os(iOS)
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:LocalLearningCoordinator.groupID)
        #else
        return FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first?.appendingPathComponent("PrivateInput",isDirectory:true)
        #endif
    }
    static var syllables:Set<String> {
        guard let root=Bundle.main.url(forResource:"semantic",withExtension:nil),
              let text=try? String(contentsOf:root.appendingPathComponent("pinyin-syllables.txt"),encoding:.utf8) else { return [] }
        return Set(text.split(separator:"\n").map(String.init))
    }
}


// One distribution: saved endpoint or QR supplies the operator address.
enum DeviceSyncDefaults { static var endpoint:String { "" } }
