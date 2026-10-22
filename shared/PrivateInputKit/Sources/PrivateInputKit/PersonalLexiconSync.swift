import Foundation

/// Versioned explicit entries, carried inside the encrypted learning domain.
/// A Lamport revision orders edits without trusting either device's wall clock.
public struct PersonalLexiconSync: Codable, Equatable {
    public struct Record: Codable, Equatable {
        public var entry: PersonalLexicon.Entry
        public var deleted: Bool
        public var revision: LogicalVersion
        public var created: LogicalVersion
    }
    public var version = 1
    public private(set) var records: [String: Record] = [:]
    public init() {}
    /// Preserve entry IDs, logical revisions and tombstones on incremental wire
    /// publication. Materialization stays receiver-side after CRDT merge.
    public func selectingRecords(_ identifiers: Set<String>) throws -> Self {
        try validate()
        var result = self; result.records = records.filter { identifiers.contains($0.key) }
        try result.validate(); return result
    }
    private func key(_ entry: PersonalLexicon.Entry) -> String {
        entry.kind.rawValue + "\u{1f}" + entry.trigger + "\u{1f}" + entry.text
    }
    public func validate() throws {
        guard version == 1, records.count <= 4000 else { throw InputDataError.oversized }
        for (id, record) in records {
            guard id == record.entry.id.uuidString, record.revision.sequence > 0,
                  UUID(uuidString: record.revision.device) != nil,
                  record.created.sequence > 0,record.created.sequence <= record.revision.sequence,
                  UUID(uuidString:record.created.device) != nil else { throw InputDataError.invalidRecord }
            var single = PersonalLexicon(); try single.upsert(record.entry)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard try encoder.encode(self).count <= PersonalLexicon.maximumBytes else { throw InputDataError.oversized }
    }
    public func materialized() throws -> PersonalLexicon {
        try validate()
        var result = PersonalLexicon(), seen = Set<String>()
        for record in records.values.sorted(by: {
            $0.created == $1.created ? $0.entry.id.uuidString < $1.entry.id.uuidString : $0.created < $1.created
        }) where !record.deleted {
            if seen.insert(key(record.entry)).inserted { try result.upsert(record.entry) }
        }
        return result
    }
    public mutating func merge(_ incoming: Self) throws {
        try incoming.validate()
        var next = self
        for (id, record) in incoming.records {
            if let old = next.records[id] {
                if old.revision == record.revision {
                    guard old == record else { throw InputDataError.invalidRecord }
                } else if old.revision.sequence == record.revision.sequence, old.deleted != record.deleted {
                    // Concurrent edit/delete at the same logical revision: delete wins.
                    if record.deleted { next.records[id] = record }
                } else if old.revision < record.revision { next.records[id] = record }
            } else { next.records[id] = record }
        }
        _ = try next.materialized(); self = next
    }
    public mutating func seed(_ legacy: PersonalLexicon, replica: UUID) throws {
        try legacy.validate()
        for entry in legacy.entries where records[entry.id.uuidString] == nil {
            try change(entry, deleted: false, replica: replica)
        }
    }
    public mutating func change(_ entry: PersonalLexicon.Entry, deleted: Bool, replica: UUID) throws {
        var next = self
        let highest = records.values.map { $0.revision.sequence }.max() ?? 0
        guard highest < UInt64.max else { throw InputDataError.oversized }
        let revision = LogicalVersion(sequence: highest + 1, device: replica.uuidString)
        // Identical imports may have different UUIDs. Retire aliases when the
        // visible entry is edited/deleted so a hidden copy cannot reappear.
        if let previous = records[entry.id.uuidString] {
            for (id, alias) in records where id != entry.id.uuidString && !alias.deleted && key(alias.entry) == key(previous.entry) {
                next.records[id] = .init(entry: alias.entry, deleted: true, revision: revision,created:alias.created)
            }
        }
        next.records[entry.id.uuidString] = .init(entry: entry, deleted: deleted, revision: revision,
                                               created:records[entry.id.uuidString]?.created ?? revision)
        _ = try next.materialized(); self = next
    }
}
