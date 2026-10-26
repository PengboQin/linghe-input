import Foundation
import CryptoKit

/// P5: personal word/phrase records held by the cloud learning service (ops 8/9).
/// Same record schema and CRDT merge as PersonalLexiconSync; the server is the
/// single authority shared by all devices of one group.
public struct CloudPersonalRecord: Codable, Equatable {
    public let id: String
    public let entry: PersonalLexicon.Entry
    public let deleted: Bool
    public let revision: LogicalVersion
    public let created: LogicalVersion
    public init(id: String, record: PersonalLexiconSync.Record) {
        self.id = id; entry = record.entry; deleted = record.deleted; revision = record.revision; created = record.created
    }
    public var record: PersonalLexiconSync.Record { .init(entry: entry, deleted: deleted, revision: revision, created: created) }
}

public struct CloudPersonalPage: Codable {
    public let records: [CloudPersonalRecord]
    public let nextVersion, version: UInt64
    public let hasMore: Bool
    enum CodingKeys: String, CodingKey { case records, version, nextVersion = "next_version", hasMore = "has_more" }
}

public struct CloudPersonalPutResult: Codable {
    public let accepted: Bool
    public let applied: Int
    public let version: UInt64
}

/// Durable per-scope progress: last pulled server version and the digest of
/// each record the server has acknowledged. Losing it only causes a re-upload.
public struct CloudPersonalProgress: Codable, Equatable {
    public var scope: String
    public var pulled: UInt64 = 0
    public var acked: [String: String] = [:]
    public init(scope: String) { self.scope = scope }

    public static func digest(_ record: PersonalLexiconSync.Record) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Data(SHA256.hash(data: try encoder.encode(record))).base64EncodedString()
    }

    /// Records whose current local content the server has not acknowledged.
    public func pending(_ local: PersonalLexiconSync) throws -> [CloudPersonalRecord] {
        try local.records.keys.sorted().compactMap { id in
            let record = local.records[id]!
            return try acked[id] == Self.digest(record) ? nil : CloudPersonalRecord(id: id, record: record)
        }
    }

    public static func incoming(_ rows: [CloudPersonalRecord]) throws -> PersonalLexiconSync {
        struct Wire: Encodable { let version = 1; let records: [String: PersonalLexiconSync.Record] }
        var map: [String: PersonalLexiconSync.Record] = [:]
        for row in rows {
            guard UUID(uuidString: row.id) == row.entry.id else { throw CloudLearningError.invalid }
            map[row.entry.id.uuidString] = row.record
        }
        let sync = try JSONDecoder().decode(PersonalLexiconSync.self, from: JSONEncoder().encode(Wire(records: map)))
        try sync.validate(); return sync
    }
}

public extension CloudLearningClient {
    func putPersonal(_ records: [CloudPersonalRecord], generation: UInt64, consentVersion: UInt64, installation: UUID,
                     group: UUID, identity: DeviceIdentity, now: UInt64) async throws -> CloudPersonalPutResult {
        guard (1...256).contains(records.count), generation > 0 else { throw CloudLearningError.invalid }
        struct Body: Encodable { let generation, consent_version: UInt64; let installation_id: UUID; let records: [CloudPersonalRecord] }
        let result: CloudPersonalPutResult = try await rpc(8, Body(generation: generation, consent_version: consentVersion,
            installation_id: installation, records: records), group: group, identity: identity, now: now)
        guard result.accepted, (0...records.count).contains(result.applied) else { throw CloudLearningError.invalid }
        return result
    }

    func pullPersonal(after: UInt64, generation: UInt64, consentVersion: UInt64, installation: UUID,
                      group: UUID, identity: DeviceIdentity, now: UInt64) async throws -> CloudPersonalPage {
        struct Body: Encodable { let generation, consent_version, after_version: UInt64; let installation_id: UUID; let limit: Int }
        let page: CloudPersonalPage = try await rpc(9, Body(generation: generation, consent_version: consentVersion, after_version: after,
            installation_id: installation, limit: 256), group: group, identity: identity, now: now)
        guard page.records.count <= 256, page.nextVersion >= after, page.hasMore || page.nextVersion <= page.version else { throw CloudLearningError.invalid }
        return page
    }
}
