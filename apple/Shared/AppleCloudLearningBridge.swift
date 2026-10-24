import Foundation
import PrivateInputKit
import Darwin

/// Written only at existing idle native checkpoints, after the same permission
/// check used to publish v1. It contains this engine's producer, never peers.
struct AppleCloudProducerSnapshot: Codable {
    let version: Int
    let personalEpoch: String
    let producer: UUID
    let entries: [LearningEntry]
    let capacityProfile: LearningCapacityReference?
    init(version: Int, personalEpoch: String, producer: UUID, entries: [LearningEntry],
         capacityProfile: LearningCapacityProfile? = nil) {
        self.version = version; self.personalEpoch = personalEpoch; self.producer = producer; self.entries = entries
        self.capacityProfile = capacityProfile.map(LearningCapacityReference.init)
    }
    private enum CodingKeys: String, CodingKey { case version, personalEpoch, producer, entries, capacityProfile = "capacity_profile" }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        personalEpoch = try values.decode(String.self, forKey: .personalEpoch)
        producer = try values.decode(UUID.self, forKey: .producer)
        entries = try values.decode([LearningEntry].self, forKey: .entries)
        capacityProfile = try values.decodeIfPresent(LearningCapacityReference.self, forKey: .capacityProfile)
        if version == 1 { guard capacityProfile == nil else { throw InputDataError.incompatibleSchema } }
        else if version == 2 {
            guard try capacityProfile?.resolved() == LearningCapacityProfiles.expanded10000 else { throw InputDataError.incompatibleSchema }
        } else { throw InputDataError.incompatibleSchema }
    }
    private func validate() throws {
        guard personalEpoch == PersonalDataReset.generation,
              entries.count <= LearningCapacityProfiles.expanded10000.producerTermRows,
              Set(entries.map(\.id)).count == entries.count else { throw InputDataError.invalidRecord }
        for row in entries {
            try row.validate()
            guard row.counts.count == 1, row.counts[producer.uuidString] != nil else { throw InputDataError.invalidRecord }
        }
    }
    /// The containing app's existing sync owner upgrades metadata under the
    /// same producer lock as native publication; no count/control is changed.
    static func migrateCurrent(directory: URL) throws {
        let epoch = PersonalDataEpoch(directory: directory); try epoch.requireCurrent()
        let folder = directory.appendingPathComponent("CloudLearningProducers", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        let descriptor = Darwin.open(folder.appendingPathComponent("producer.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw SnapshotStoreError.busy }; defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw SnapshotStoreError.busy }; defer { flock(descriptor, LOCK_UN) }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey]).filter { $0.pathExtension == "json" }
        guard files.count <= LearningCapacityProfiles.expanded10000.producersPerDevice else { throw InputDataError.oversized }
        for file in files {
            guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw InputDataError.invalidRecord }
            let data = try Data(contentsOf: file); guard data.count <= LearningCapacityProfiles.expanded10000.producerFileBytes else { throw InputDataError.oversized }
            let old = try JSONDecoder().decode(Self.self, from: data); try old.validate()
            guard file.lastPathComponent == old.producer.uuidString + ".json" else { throw InputDataError.invalidRecord }
            guard old.version == 1 else { continue }
            let upgraded = Self(version: 2, personalEpoch: old.personalEpoch, producer: old.producer,
                entries: old.entries, capacityProfile: LearningCapacityProfiles.expanded10000)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let current = try encoder.encode(upgraded); guard current.count <= LearningCapacityProfiles.expanded10000.producerFileBytes else { throw InputDataError.oversized }
            try epoch.requireCurrent()
            #if os(iOS)
            try current.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try current.write(to: file, options: .atomic)
            #endif
        }
    }
    static func publish(_ entries: [LearningEntry], producer: UUID, directory: URL, onlyIfAbsent: Bool = false) throws {
        let epoch = PersonalDataEpoch(directory: directory); try epoch.requireCurrent()
        let folder = directory.appendingPathComponent("CloudLearningProducers", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = folder.appendingPathComponent(producer.uuidString + ".json")
        let descriptor = Darwin.open(folder.appendingPathComponent("producer.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw SnapshotStoreError.busy }; defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw SnapshotStoreError.busy }; defer { flock(descriptor, LOCK_UN) }
        if onlyIfAbsent, FileManager.default.fileExists(atPath: destination.path) { return }
        var own = try entries.map { row -> LearningEntry in
            // Validate before projecting away peer counters; projection must
            // never hide an invalid source record.
            try row.validate()
            var copy = row; copy.counts = [producer.uuidString: row.counts[producer.uuidString] ?? 0]; return copy
        }
        var previousData: Data?
        if FileManager.default.fileExists(atPath: destination.path) {
            let handle = try FileHandle(forReadingFrom: destination); defer { try? handle.close() }
            let data = try handle.read(upToCount: 4 * 1024 * 1024 + 1) ?? Data()
            guard data.count <= 4 * 1024 * 1024 else { throw InputDataError.oversized }
            previousData = data
            let old = try JSONDecoder().decode(Self.self, from: data)
            guard (old.version == 1 || old.version == 2), old.producer == producer, old.personalEpoch == PersonalDataReset.generation,
                  old.entries.count <= LearningCapacityProfiles.expanded10000.producerTermRows, Set(old.entries.map(\.id)).count == old.entries.count,
                  old.entries.allSatisfy({ $0.counts.count == 1 && $0.counts[producer.uuidString] != nil }) else { throw InputDataError.invalidRecord }
            for row in old.entries { try row.validate() }
            var merged = Dictionary(uniqueKeysWithValues: old.entries.map { ($0.id, $0) })
            for row in own { merged[row.id] = try merged[row.id].map { try $0.merging(row) } ?? row }
            own = Array(merged.values)
        }
        // A peer-only word mapped to ownCount=0 carries no producer component
        // when every control is also at its default. Remove only that neutral
        // projection after merging; nonzero counters and all reset/delete/pin
        // versions remain authoritative, including an explicit unpin.
        own.removeAll { row in
            (row.counts[producer.uuidString] ?? 0) == 0 && row.generation == 0 &&
                !row.deleted && !row.pinned && row.pinVersion.sequence == 0 && row.pinVersion.device.isEmpty
        }
        guard own.count <= LearningCapacityProfiles.expanded10000.producerTermRows else { throw InputDataError.oversized }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Self(version: 2, personalEpoch: PersonalDataReset.generation, producer: producer, entries: own.sorted { $0.id < $1.id }, capacityProfile: LearningCapacityProfiles.expanded10000))
        guard data.count <= 4 * 1024 * 1024 else { throw InputDataError.oversized }
        try epoch.requireCurrent()
        if previousData == data { return }
        try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    /// Read the committed pre-upgrade journal once. No native engine mutation,
    /// no imported peer counter ownership and no guessed observation timestamp.
    static func seedCommittedProducer(base: URL, directory: URL) throws {
        let idFile = base.appendingPathComponent("local-replica-id.txt")
        guard let text = try? String(contentsOf: idFile, encoding: .utf8), let producer = UUID(uuidString: text) else { return }
        guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("CloudLearningProducers").appendingPathComponent(producer.uuidString + ".json").path) else { return }
        struct Runtime: Decodable { let journal: Data }
        let runtime = base.appendingPathComponent("learning-runtime-v2.json")
        let checkpoint: RimeLearningCheckpoint
        if FileManager.default.fileExists(atPath: runtime.path) {
            let handle = try FileHandle(forReadingFrom: runtime); defer { try? handle.close() }
            let data = try handle.read(upToCount: 12 * 1024 * 1024 + 1) ?? Data()
            guard data.count <= 12 * 1024 * 1024 else { throw InputDataError.oversized }
            let journal = try LearningImportJournal.restore(JSONDecoder().decode(Runtime.self, from: data).journal)
            guard journal.pending == nil else { throw LearningSyncFailure.busy }
            checkpoint = journal.checkpoint
        } else { return }
        try publish(Array(checkpoint.model.entries.values), producer: producer, directory: directory, onlyIfAbsent: true)
    }
    static func read(directory: URL) throws -> [Self] {
        let epoch = PersonalDataEpoch(directory: directory); try epoch.requireCurrent()
        let folder = directory.appendingPathComponent("CloudLearningProducers", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey])
            .filter { $0.pathExtension == "json" }
        guard files.count <= 8 else { throw InputDataError.oversized }
        return try files.map { file in
            guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw InputDataError.invalidRecord }
            let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
            let data = try handle.read(upToCount: 4 * 1024 * 1024 + 1) ?? Data()
            guard data.count <= 4 * 1024 * 1024 else { throw InputDataError.oversized }
            let value = try JSONDecoder().decode(Self.self, from: data)
            guard (value.version == 1 || value.version == 2), value.personalEpoch == PersonalDataReset.generation,
                  file.lastPathComponent == value.producer.uuidString + ".json", value.entries.count <= LearningCapacityProfiles.expanded10000.producerTermRows else { throw InputDataError.invalidRecord }
            try value.validate()
            return value
        }
    }
}

/// A compact authenticated, already-verified model projection. The owner reads
/// once at safe refresh boundaries; key/touch handlers do no I/O or networking.
struct AppleCloudLearningRankState: Codable {
    let version: Int
    let group: UUID
    let membershipEpoch: UInt64
    let personalEpoch: String
    let modelVersion: UInt64
    let expiresAt: UInt64
    let projection: CloudLearningRankProjection
    static let filename = "cloud-learning-ranking-v1.json"
    static func publish(_ migration: CloudLearningComponentMigration, membershipEpoch: UInt64, directory: URL, now: UInt64) throws {
        guard migration.ready else { return }
        let value = Self(version: 2, group: migration.model.group, membershipEpoch: membershipEpoch,
            personalEpoch: PersonalDataReset.generation, modelVersion: migration.model.modelVersion, expiresAt: now + 7 * 86400,
            projection: CloudLearningRankProjection(migration: migration))
        let epoch = PersonalDataEpoch(directory: directory); try epoch.requireCurrent()
        let data = try JSONEncoder().encode(value); guard data.count <= 4 * 1024 * 1024 else { throw InputDataError.oversized }
        try data.write(to: directory.appendingPathComponent(filename), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func read(directory: URL, group: UUID?, epoch: UInt64?, preferences: UserDefaults? = UserDefaults(suiteName: LocalLearningCoordinator.groupID)) -> Self? {
        guard preferences?.bool(forKey: "learning-sharing-enabled") == true,
              preferences?.bool(forKey: "cloud-learning-enabled") == true,
              let group, let epoch, let data = try? Data(contentsOf: directory.appendingPathComponent(filename)), data.count <= 4 * 1024 * 1024,
              let state = try? JSONDecoder().decode(Self.self, from: data), state.version == 2,
              state.group == group, state.membershipEpoch == epoch, state.personalEpoch == PersonalDataReset.generation,
              state.expiresAt > UInt64(Date().timeIntervalSince1970), state.projection.weights.count <= LearningCapacityProfiles.expanded10000.modelTermRows,
              state.projection.represented.count <= 8 else { return nil }
        return state
    }
    func snapshot(producer: UUID, entries: [LearningEntry], uptime: Double) -> RecencyCoordinator.Snapshot {
        guard let scores = try? projection.scores(current: [producer: entries]) else { return .empty }
        let remaining = max(0, Double(expiresAt) - Date().timeIntervalSince1970)
        return .init(scores: scores,
                     authenticated: true, expiresUptime: uptime + remaining)
    }
}
