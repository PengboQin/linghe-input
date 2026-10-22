import Foundation
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
    private let personalEpoch=PersonalDataReset.generation
    private let rankingPreferences: UserDefaults?
    private let stateURL: URL
    private let device: String
    private let shared: SharedLearningSnapshot?
    private let recencyBridge: AppleRecencyBridge?
    private let refreshSharedDirectory: URL?
    init(base: URL, rankingPreferences: UserDefaults? = UserDefaults(suiteName: LocalLearningCoordinator.groupID)) throws {
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
            .init(name:"local-reset",url:stateURL.deletingLastPathComponent().appendingPathComponent(PersonalDataReset.marker),maximum:128,runtime:false)]
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
    }
    private var runtimeURL: URL { stateURL.deletingLastPathComponent().appendingPathComponent("learning-runtime-v2.json") }
    private var recent: RecencyCoordinator?
    private var cloudScoreActive = false
    private var cloudScoreGroup: UUID?
    private var cloudScoreEpoch: UInt64?
    private var storedScoreSnapshot = RecencyCoordinator.Snapshot.empty
    private var pendingCloudSnapshot: (RecencyCoordinator.Snapshot, UUID, UInt64)?
    func stageCloudSnapshot(_ snapshot: RecencyCoordinator.Snapshot, group: UUID, epoch: UInt64) {
        pendingCloudSnapshot = (snapshot, group, epoch)
    }
    /// O(1) pointer adoption at the next composition start, never reload a
    /// visible candidate list. No file, network, Keychain or full-model work.
    func beginComposition() {
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
    private let boot = AppleRecencyBridge.bootSession ?? UUID().uuidString
    private var recencyGroup: UUID?
    private var recencyMembershipEpoch: UInt64?
    private func ensureEpoch() throws {
        guard personalEpoch == PersonalDataReset.generation else { throw LearningSyncFailure.busy }
    }
    private func readJournal() throws -> LearningImportJournal {
        try ensureEpoch()
        if FileManager.default.fileExists(atPath: runtimeURL.path) {
            let data = try Data(contentsOf: runtimeURL)
            guard data.count <= 12 * 1024 * 1024 else { throw InputDataError.oversized }
            let state = try JSONDecoder().decode(RuntimeState.self, from: data)
            guard state.version == 2 else { throw InputDataError.incompatibleSchema }
            if recent == nil {
                recent = try RecencyCoordinator(persisted: state.recency)
                recencyGroup = state.group; recencyMembershipEpoch = state.membershipEpoch
            }
            return try LearningImportJournal.restore(state.journal)
        }
        let checkpoint: RimeLearningCheckpoint
        if FileManager.default.fileExists(atPath: stateURL.path) {
            let data = try Data(contentsOf: stateURL)
            guard data.count <= 8 * 1024 * 1024 else { throw InputDataError.oversized }
            checkpoint = try JSONDecoder().decode(RimeLearningCheckpoint.self, from: data)
        } else { checkpoint = RimeLearningCheckpoint() }
        if recent == nil { recent = try RecencyCoordinator(); try recent?.mergeCumulative(checkpoint) }
        return try LearningImportJournal(checkpoint: checkpoint)
    }
    private func persist(_ journal: LearningImportJournal) throws {
        var succeeded = false
        defer { if !succeeded { recent = nil; scoreSnapshot = .empty } }
        try ensureEpoch()
        guard let recent else { throw InputDataError.invalidRecord }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(RuntimeState(journal: journal.persistedData(), recency: recent.persisted(), group: recencyGroup, membershipEpoch: recencyMembershipEpoch))
        guard data.count <= 12 * 1024 * 1024 else { throw InputDataError.oversized }
        try persistIfChanged(data, to: runtimeURL)
        // This file is never authoritative for upgraded readers; an interruption
        // here still leaves the complete native transaction in runtime-v2.
        if journal.pending == nil {
            let legacy = try encoder.encode(journal.checkpoint)
            try persistIfChanged(legacy, to: stateURL)
        }
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
        let journal = try readJournal()
        let clock = try RecentLearningClock(authenticatedUnixSeconds: unixSeconds, uptime: uptime, bootSession: boot)
        try recent?.acceptAuthenticated(policy: policy, clock: clock, validUntilUptime: uptime + 7 * 86400)
        try persist(journal)
    }
    func suspendRecency() { recent?.suspend(); scoreSnapshot = .empty }
    func invalidateDatedObservation() { recent?.invalidateObservation() }
    func recencyArchive() throws -> Data { _ = try readJournal(); return try recent!.export() }
    func mergeRecencyArchive(_ data: Data) throws {
        let journal = try readJournal(); guard journal.pending == nil else { throw LearningSyncFailure.busy }
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
    func manage(reading: String, text: String, pinned: Bool?) throws {
        let old = try readJournal(); guard old.pending == nil else { throw LearningSyncFailure.busy }
        var state = old.checkpoint
        if let pinned { try state.setPinned(reading: reading, text: text, pinned: pinned, device: device) }
        else { try state.resetFrequency(reading: reading, text: text) }
        try recent?.mergeCumulative(state)
        try persist(LearningImportJournal(checkpoint: state))
    }
    func checkpoint(exportFile: URL, importFile: URL, publish: SnapshotPublisher?, engineExport: (URL) -> Int32, engineImport: (URL) -> Int32, engineReset: (LearningEntry) -> Int32, allowDatedLearning: Bool = true) throws -> [LearningEntry] {
        let started = ProcessInfo.processInfo.systemUptime
        lastCheckpointMetrics = LearningCheckpointMetrics()
        var completed = false
        defer {
            lastCheckpointMetrics.elapsedMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
            lastCheckpointMetrics.completed = completed
            if !completed { recent = nil; scoreSnapshot = .empty }
        }
        var journal = try readJournal()
        try consumeSharedRecency(journal.checkpoint)
        guard engineExport(exportFile) >= 0 else { throw LearningSyncFailure.exportFailed }
        var exported = try Data(contentsOf: exportFile)
        if let intent = journal.pending {
            lastCheckpointMetrics.recoveredPending = true
            // MAX import is idempotent and preserves any post-crash input. Reset
            // replay is not: prove its desired result in the actual native DB,
            // otherwise leave sync pending while normal typing remains usable.
            let counts = Dictionary(uniqueKeysWithValues: try RimeLearningFormat.parseExport(exported).map { ($0.id, $0.count) })
            for entry in intent.target.pendingResets {
                guard (counts[entry.id] ?? 0) == entry.frequency else { throw LearningSyncFailure.busy }
            }
            try intent.nativeImportTSV().write(to: importFile, options: .atomic)
            lastCheckpointMetrics.nativeImports += 1
            guard engineImport(importFile) >= 0, engineExport(exportFile) >= 0 else { throw LearningSyncFailure.importFailed }
            exported = try Data(contentsOf: exportFile)
            try journal.commit(transactionID: intent.id, actualEngineExport: exported)
            // Preserve provable excess above the desired imported snapshot as
            // undated cumulative use. It must never become a fresh daily bucket.
            var recovered = journal.checkpoint
            var excess = LearningModel()
            for word in try RimeLearningFormat.parseExport(exported) {
                let expected = intent.target.model.entries[word.id]?.frequency ?? 0
                if word.count > expected {
                    var entry = intent.target.model.entries[word.id] ?? LearningEntry(reading: word.reading, text: word.text)
                    if !entry.deleted {
                        entry.counts[device] = min(1_000_000_000, (entry.counts[device] ?? 0) + word.count - expected)
                        let data = try JSONEncoder().encode(LearningArchive(entries: [entry]))
                        try excess.merge(data)
                    }
                }
            }
            try recovered.mergeRemoteArchive(excess.export())
            journal = try LearningImportJournal(checkpoint: recovered)
            try recent?.mergeCumulative(journal.checkpoint); recent?.invalidateObservation()
            try persist(journal)
        }
        let before = journal.checkpoint
        var remoteModel = LearningModel()
        try remoteModel.merge(shared?.read() ?? before.outboundArchive())
        if let recent { try remoteModel.merge(recent.model.legacyProjection()) }
        let remote = try remoteModel.export()
        // prepare observes the final local export before merging incoming data.
        // Date only the pure local delta, before the remote MAX components exist.
        var observed = before; try observed.observeExport(exported, device: device)
        try recent?.observe(before: before, after: observed, replica: device,
            wall: Date().timeIntervalSince1970, uptime: ProcessInfo.processInfo.systemUptime,
            boot: boot, canDate: allowDatedLearning)
        let intent = try journal.prepare(finalLocalExport: exported, remoteArchive: remote, device: device)
        try recent?.mergeCumulative(intent.target)
        let actualCounts = Dictionary(uniqueKeysWithValues: try RimeLearningFormat.parseExport(exported).map { ($0.id, $0.count) })
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
                try recencyBridge?.merge(recent.export(), group: group, epoch: epoch)
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
