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
    private let version: Int
    private static let currentVersion = 1
    private static let maximumBytes = 8 * 1024 * 1024

    public init(checkpoint: RimeLearningCheckpoint = .init()) throws {
        try Self.validate(checkpoint)
        self.version = Self.currentVersion; self.checkpoint = checkpoint
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
        guard data.count <= Self.maximumBytes else { throw InputDataError.oversized }
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
        guard version == Self.currentVersion else { throw JournalError.incompatibleVersion }
        checkpoint = try values.decode(RimeLearningCheckpoint.self, forKey: .checkpoint)
        pending = try values.decodeIfPresent(Intent.self, forKey: .pending)
        try Self.validate(checkpoint)
        if let pending { try Self.validate(pending.target) }
    }

    public func encode(to encoder: Encoder) throws {
        try Self.validate(checkpoint)
        if let pending { try Self.validate(pending.target) }
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
              value.observedCounts.count <= 5000,
              (value.appliedGenerations?.count ?? 0) <= 5000 else { throw InputDataError.invalidRecord }
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
