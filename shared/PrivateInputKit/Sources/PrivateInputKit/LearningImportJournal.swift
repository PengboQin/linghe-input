import Foundation

/// Transaction state without I/O. The Apple idle adapter supplies persistence
/// and native execution; publishing a component alone does not deploy it.
///
/// The adapter must serialize learning and native engine access for the entire
/// transaction, and durably/atomically persist the journal returned by prepare
/// BEFORE changing the native engine. After commit it must persist again BEFORE
/// resuming learning observation. This must never block user input: if the
/// adapter cannot finish an isolated, fast native transaction, postpone sync.
/// While pending, input may continue but learning observation/publication stays
/// suspended; recovery conservatively does not count ambiguous native deltas.
/// Keeping the pending intent on disk makes every interruption
/// fail closed: imported counts cannot subsequently be observed as local input.
public struct LearningImportJournal: Codable {
    public enum JournalError: Error, Equatable {
        case importPending, noPendingImport, staleTransaction, incompatibleVersion
    }

    public struct Intent: Codable {
        public let id: UUID
        public let target: RimeLearningCheckpoint

        /// This is a desired snapshot, NOT an instruction to add these counts
        /// again. Recovery replay requires an idempotent native replacement (or
        /// reset/re-import) adapter. Blind additive TSV replay is unsafe.
        public func nativeImportTSV() throws -> Data { try target.engineImport() }

        fileprivate init(id: UUID, target: RimeLearningCheckpoint) {
            self.id = id; self.target = target
        }
    }

    /// The last completed checkpoint. While pending, only pending.target also
    /// includes the final pre-import observation and the incoming remote merge.
    public private(set) var checkpoint: RimeLearningCheckpoint
    public private(set) var pending: Intent?
    private var version: Int
    private static let maximumBytes = max(LearningCapacityProfiles.legacy5000.journalBytes, LearningCapacityProfiles.expanded10000.journalBytes)

    public init(checkpoint: RimeLearningCheckpoint = .init()) throws {
        try Self.validate(checkpoint)
        self.version = Self.version(for: checkpoint.capacityProfile); self.checkpoint = checkpoint
    }

    public var capacityProfile: LearningCapacityProfile { checkpoint.capacityProfile }
    /// Capacity migration cannot rewrite a desired native transaction in flight.
    public mutating func upgradeCapacity(to profile: LearningCapacityProfile) throws {
        guard pending == nil else { throw JournalError.importPending }
        var target = checkpoint; try target.upgradeCapacity(to: profile)
        let next = try Self(checkpoint: target); _ = try next.persistedData(); self = next
    }
    private static func version(for profile: LearningCapacityProfile) -> Int {
        profile == LearningCapacityProfiles.legacy5000 ? 1 : 2
    }

    /// Observe only when no native import may be unfinished. Mutates atomically
    /// on success, including when a malformed export appears after valid rows.
    public mutating func observeExport(_ data: Data, device: String) throws {
        guard pending == nil else { throw JournalError.importPending }
        try Self.validateDevice(device)
        var next = checkpoint
        try next.observeExport(data, device: device)
        try Self.validate(next)
        checkpoint = next
    }

    /// Captures local changes BEFORE remote import. The returned intent and this
    /// whole journal must be persisted together, never in separate stores.
    /// Native execution is forbidden until that persistence succeeds.
    @discardableResult
    public mutating func prepare(finalLocalExport: Data, remoteArchive: Data,
                                 device: String, transactionID: UUID = UUID()) throws -> Intent {
        guard pending == nil else { throw JournalError.importPending }
        try Self.validateDevice(device)
        var target = checkpoint
        try target.observeExport(finalLocalExport, device: device)
        try target.mergeRemoteArchive(remoteArchive)
        try Self.validate(target)
        _ = try target.engineImport()
        let intent = Intent(id: transactionID, target: target)
        // Validate size before mutation, so a persistable state is always left.
        var next = self; next.pending = intent
        _ = try next.persistedData()
        self = next
        return intent
    }

    /// Call only after ALL requested native resets/replacements/imports succeeded
    /// (including during recovery) AND the actual engine export was
    /// re-read while the native transaction remained quiescent. Never pass the requested TSV as
    /// the actual export. Persist this completed journal before resuming learning.
    /// A syntactically valid export alone does not prove native import completed.
    public mutating func commit(transactionID: UUID, actualEngineExport: Data) throws {
        guard let intent = pending else { throw JournalError.noPendingImport }
        guard intent.id == transactionID else { throw JournalError.staleTransaction }
        var next = intent.target
        try next.establishBaselineAfterImport(actualEngineExport)
        try Self.validate(next)
        checkpoint = next; pending = nil
    }

    /// Only after the ORIGINAL pending target has completed its native work.
    /// No desired import or pending ID is rewritten before that proof. The
    /// owner must reconcile provable post-crash excess before persisting this
    /// completed journal, so a newly baselined word cannot lose local usage.
    public mutating func commitThenUpgradeCapacity(transactionID: UUID, actualEngineExport: Data,
                                                   to profile: LearningCapacityProfile) throws {
        guard let intent = pending else { throw JournalError.noPendingImport }
        guard intent.id == transactionID else { throw JournalError.staleTransaction }
        var next = intent.target; try next.upgradeCapacity(to: profile)
        try next.establishBaselineAfterImport(actualEngineExport); try Self.validate(next)
        var completed = try Self(checkpoint: next); _ = try completed.persistedData()
        completed.pending = nil; self = completed
    }

    // There is deliberately no abort/"trust current native counts" shortcut.
    // After a crash the adapter must idempotently reset/re-import pending.target,
    // read the actual engine export, then commit the SAME transaction ID. In
    // particular a reset generation must not be acknowledged before native reset.

    /// Do not publish a half-applied transaction as if synchronization finished.
    public func outboundArchive() throws -> Data {
        guard pending == nil else { throw JournalError.importPending }
        return try checkpoint.outboundArchive()
    }

    public func persistedData() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= capacityProfile.journalBytes else { throw InputDataError.oversized }
        return data
    }

    public static func restore(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw InputDataError.oversized }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    private enum CodingKeys: String, CodingKey { case version, checkpoint, pending }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        guard version == 1 || version == 2 else { throw JournalError.incompatibleVersion }
        checkpoint = try values.decode(RimeLearningCheckpoint.self, forKey: .checkpoint)
        pending = try values.decodeIfPresent(Intent.self, forKey: .pending)
        guard version == Self.version(for: checkpoint.capacityProfile) else { throw JournalError.incompatibleVersion }
        try Self.validate(checkpoint)
        if let pending {
            guard pending.target.capacityProfile == checkpoint.capacityProfile else { throw JournalError.incompatibleVersion }
            try Self.validate(pending.target)
        }
    }

    public func encode(to encoder: Encoder) throws {
        guard version == Self.version(for: checkpoint.capacityProfile) else { throw JournalError.incompatibleVersion }
        try Self.validate(checkpoint)
        if let pending {
            guard pending.target.capacityProfile == checkpoint.capacityProfile else { throw JournalError.incompatibleVersion }
            try Self.validate(pending.target)
        }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(checkpoint, forKey: .checkpoint)
        try values.encodeIfPresent(pending, forKey: .pending)
    }

    private static func validateDevice(_ device: String) throws {
        guard !device.isEmpty, device.utf8.count <= 128 else { throw InputDataError.invalidRecord }
    }

    private static func validate(_ value: RimeLearningCheckpoint) throws {
        _ = try value.outboundArchive()
        guard value.model.entries.allSatisfy({ $0.key == $0.value.id }),
              value.observedCounts.count <= value.capacityProfile.observedCountKeys,
              (value.appliedGenerations?.count ?? 0) <= value.capacityProfile.appliedGenerationKeys else { throw InputDataError.invalidRecord }
        for (id, count) in value.observedCounts {
            try validateEntryID(id)
            guard count <= 1_000_000_000 else { throw InputDataError.invalidRecord }
        }
        for id in value.appliedGenerations?.keys ?? Dictionary<String, UInt64>().keys {
            try validateEntryID(id)
        }
    }

    private static func validateEntryID(_ id: String) throws {
        let parts = id.split(separator: "\u{001F}", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw InputDataError.invalidRecord }
        try LearningEntry(reading: String(parts[0]), text: String(parts[1])).validate()
    }
}
