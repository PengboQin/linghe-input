import Foundation
import CryptoKit

public struct CloudLearningComponentPublication: Codable {
    public let generation, consentVersion: UInt64
    public let installationID, producerID, publicationID: UUID
    public let historyMode: String
    public let records: [LearningEntry]
    enum CodingKeys: String, CodingKey {
        case generation, records, consentVersion = "consent_version", installationID = "installation_id"
        case producerID = "producer_id", publicationID = "publication_id", historyMode = "history_mode"
    }
}
public struct CloudLearningComponentReceipt: Codable {
    public let acceptedPublicationID, producerID: UUID
    public let producerRevision, generation, consentVersion: UInt64
    public let changedRecords: Int
    public let componentDigest: String
    enum CodingKeys: String, CodingKey {
        case acceptedPublicationID = "accepted_publication_id", producerID = "producer_id", producerRevision = "producer_revision"
        case generation, consentVersion = "consent_version", changedRecords = "changed_records", componentDigest = "component_digest"
    }
}
public struct CloudLearningComponentSnapshot: Codable {
    public let exists: Bool
    public let producerID: UUID
    public let producerRevision: UInt64
    public let componentDigest: String
    public let records: [LearningEntry]
    enum CodingKeys: String, CodingKey {
        case exists, records, producerID = "producer_id", producerRevision = "producer_revision", componentDigest = "component_digest"
    }
}
public extension CloudLearningClient {
    func componentSnapshot(producer: UUID, generation: UInt64, consentVersion: UInt64, installation: UUID,
                           group: UUID, identity: DeviceIdentity, now: UInt64) async throws -> CloudLearningComponentSnapshot {
        struct Body: Encodable { let generation, consent_version: UInt64; let installation_id, producer_id: UUID }
        let snapshot: CloudLearningComponentSnapshot = try await rpc(7, Body(generation: generation, consent_version: consentVersion,
            installation_id: installation, producer_id: producer), group: group, identity: identity, now: now)
        guard snapshot.producerID == producer, snapshot.records.count <= LearningCapacityProfiles.expanded10000.producerTermRows,
              snapshot.exists ? snapshot.producerRevision > 0 : (snapshot.producerRevision == 0 && snapshot.records.isEmpty),
              try CloudLearningComponents.digest(producer: producer, records: snapshot.records) == snapshot.componentDigest else { throw CloudLearningError.badHash }
        return snapshot
    }

    func publishComponents(_ publication: CloudLearningComponentPublication, group: UUID, identity: DeviceIdentity,
                           now: UInt64) async throws -> CloudLearningComponentReceipt {
        guard (0...128).contains(publication.records.count), publication.generation > 0,
              ["historical_undated", "incremental"].contains(publication.historyMode) else { throw CloudLearningError.invalid }
        for row in publication.records {
            try row.validate()
            guard row.counts.count == 1, row.counts[publication.producerID.uuidString] != nil else { throw CloudLearningError.invalid }
        }
        let receipt: CloudLearningComponentReceipt = try await rpc(6, publication, group: group, identity: identity, now: now)
        guard receipt.acceptedPublicationID == publication.publicationID, receipt.producerID == publication.producerID,
              receipt.generation == publication.generation, receipt.consentVersion == publication.consentVersion,
              receipt.changedRecords >= 0, receipt.changedRecords <= publication.records.count,
              receipt.componentDigest.count == 64 else { throw CloudLearningError.invalid }
        return receipt
    }
}

/// A projection of one local engine's cumulative CRDT components. Peer counts
/// are removed, never reattributed. Raw archives and the native userdb survive.
public enum CloudLearningComponents {
    public static func project(_ entries: [LearningEntry], producer: UUID, policy: CloudLearningTextPolicy) -> [LearningEntry] {
        entries.compactMap { entry in
            guard (entry.counts.first(where: { $0.key.uppercased() == producer.uuidString })?.value ?? 0) > 0 || entry.pinVersion.device.uppercased() == producer.uuidString || entry.generation > 0 || entry.deleted else { return nil }
            guard policy.allowsTerm(entry.text), entry.reading.utf8.count <= 96,
                  entry.reading.range(of: "^[a-z]+(?:[ '][a-z]+)*\\z", options: .regularExpression) != nil else { return nil }
            var row = entry
            row.counts = [producer.uuidString: entry.counts.first(where: { $0.key.uppercased() == producer.uuidString })?.value ?? 0]
            return row
        }.sorted { ($0.reading, $0.text) < ($1.reading, $1.text) }
    }
    public static func digest(producer: UUID, records: [LearningEntry]) throws -> String {
        struct Body: Encodable { let producer_id: String; let records: [LearningEntry] }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Body(producer_id: producer.uuidString, records: records.sorted { ($0.reading, $0.text) < ($1.reading, $1.text) }))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Durable background migration authority. A publication is persisted before
/// HTTP and retried byte-for-byte. Only an aggregated producer watermark clears
/// its local overlay; transport ACK alone cannot switch the ranking source.
public struct CloudLearningComponentMigration: Codable {
    public struct Producer: Codable {
        public var accepted: [String: LearningEntry] = [:]
        public var represented: [String: LearningEntry] = [:]
        public var receipt: CloudLearningComponentReceipt?
        public var bootstrapWatermark: CloudLearningProducerWatermark?
        public var pending: CloudLearningComponentPublication?
        public var baselineComplete = false
    }
    public var model: CloudLearningReplica
    public private(set) var producers: [String: Producer] = [:]
    public private(set) var ready = false
    public init(model: CloudLearningReplica) { self.model = model }
    public mutating func bootstrap(_ snapshot: CloudLearningComponentSnapshot) throws {
        guard producers[snapshot.producerID.uuidString] == nil,
              snapshot.records.count <= LearningCapacityProfiles.expanded10000.producerTermRows, Set(snapshot.records.map(\.id)).count == snapshot.records.count,
              try CloudLearningComponents.digest(producer: snapshot.producerID, records: snapshot.records) == snapshot.componentDigest else { throw CloudLearningError.invalid }
        var state = Producer()
        for row in snapshot.records {
            try row.validate()
            guard row.counts.count == 1, row.counts[snapshot.producerID.uuidString] != nil else { throw CloudLearningError.invalid }
            state.accepted[row.id] = row
        }
        if snapshot.exists {
            guard snapshot.producerRevision > 0 else { throw CloudLearningError.invalid }
            state.bootstrapWatermark = .init(producerID: snapshot.producerID, producerRevision: snapshot.producerRevision, componentDigest: snapshot.componentDigest)
        } else { guard snapshot.producerRevision == 0, snapshot.records.isEmpty else { throw CloudLearningError.invalid } }
        producers[snapshot.producerID.uuidString] = state
    }
    public mutating func prepare(producer: UUID, records: [LearningEntry]) throws -> CloudLearningComponentPublication? {
        var state = producers[producer.uuidString] ?? Producer()
        if let pending = state.pending { return pending }
        // Re-establish this producer under the current consent before dating
        // post-bootstrap changes. No forged upload receipt from a read-only RPC.
        if state.receipt == nil, state.bootstrapWatermark != nil {
            let publication = CloudLearningComponentPublication(generation: model.generation, consentVersion: model.consentVersion,
                installationID: model.installation, producerID: producer, publicationID: UUID(), historyMode: "historical_undated", records: [])
            state.pending = publication; producers[producer.uuidString] = state; return publication
        }
        let changed = try records.compactMap { row -> LearningEntry? in
            let merged = try state.accepted[row.id].map { try $0.merging(row) } ?? row
            return state.accepted[row.id] == merged ? nil : merged
        }
        guard !changed.isEmpty || state.receipt == nil else {
            state.baselineComplete = true; producers[producer.uuidString] = state; return nil
        }
        let publication = CloudLearningComponentPublication(generation: model.generation, consentVersion: model.consentVersion,
            installationID: model.installation, producerID: producer, publicationID: UUID(),
            historyMode: state.baselineComplete ? "incremental" : "historical_undated", records: Array(changed.prefix(128)))
        state.pending = publication; producers[producer.uuidString] = state; return publication
    }
    public mutating func receive(_ receipt: CloudLearningComponentReceipt) throws {
        guard var producer = producers[receipt.producerID.uuidString], let pending = producer.pending,
              pending.publicationID == receipt.acceptedPublicationID, receipt.generation == model.generation,
              receipt.consentVersion == model.consentVersion else { throw CloudLearningError.invalid }
        for row in pending.records {
            if let old = producer.accepted[row.id] { producer.accepted[row.id] = try old.merging(row) }
            else { producer.accepted[row.id] = row }
        }
        guard try CloudLearningComponents.digest(producer: receipt.producerID, records: Array(producer.accepted.values)) == receipt.componentDigest else { throw CloudLearningError.badHash }
        if pending.records.isEmpty, producer.bootstrapWatermark != nil { producer.baselineComplete = true }
        producer.receipt = receipt; producer.pending = nil; producers[receipt.producerID.uuidString] = producer
    }
    public mutating func stage(_ delta: CloudLearningDelta, policy: CloudLearningTextPolicy) throws {
        guard delta.algorithmVersion == "shared-lexeme-decay-v2" else { throw CloudLearningError.unsupported }
        var next = self; try next.model.stage(delta, policy: policy)
        let marks = delta.producerWatermarks ?? []
        guard Set(marks.map(\.producerID)).count == marks.count else { throw CloudLearningError.invalid }
        var all = true
        for key in next.producers.keys {
            guard let producerID = UUID(uuidString: key), var producer = next.producers[key] else { throw CloudLearningError.invalid }
            let expected = producer.receipt.map { CloudLearningProducerWatermark(producerID: $0.producerID, producerRevision: $0.producerRevision, componentDigest: $0.componentDigest) } ?? producer.bootstrapWatermark
            if let expected, let mark = marks.first(where: { $0.producerID == producerID }),
               mark.producerRevision == expected.producerRevision, mark.componentDigest == expected.componentDigest {
                producer.represented = producer.accepted; next.producers[key] = producer
            } else if !producer.accepted.isEmpty { all = false }
            if producer.pending != nil || !producer.baselineComplete { all = false }
        }
        next.ready = all && !next.producers.isEmpty && next.model.modelVersion > 0 && !delta.hasMore
        self = next
    }
    /// A bounded replacement for v2 recency contribution, never added to it.
    /// Native exact-match/pin/explicit correction tiers remain the owner's job.
    public func scores(current: [UUID: [LearningEntry]]) -> [String: Double]? {
        guard ready else { return nil }
        return try? CloudLearningRankProjection(migration: self).scores(current: current)
    }
    public func data() throws -> Data {
        let result = try JSONEncoder().encode(self); guard result.count <= 12 * 1024 * 1024 else { throw CloudLearningError.oversized }; return result
    }
    public static func restore(_ data: Data) throws -> Self {
        guard data.count <= 12 * 1024 * 1024 else { throw CloudLearningError.oversized }
        let state = try JSONDecoder().decode(Self.self, from: data)
        _ = try CloudLearningReplica.restore(state.model.persistedData())
        guard state.producers.count <= LearningCapacityProfiles.expanded10000.producersPerDevice else { throw CloudLearningError.invalid }
        for (key, value) in state.producers {
            guard UUID(uuidString: key)?.uuidString == key, value.accepted.count <= LearningCapacityProfiles.expanded10000.producerAcceptedKeys, value.represented.count <= LearningCapacityProfiles.expanded10000.producerRepresentedKeys else { throw CloudLearningError.invalid }
            for row in value.accepted.values { try row.validate(); guard row.counts.count == 1, row.counts[key] != nil else { throw CloudLearningError.invalid } }
            if let receipt = value.receipt { guard receipt.producerID.uuidString == key, try CloudLearningComponents.digest(producer: receipt.producerID, records: Array(value.accepted.values)) == receipt.componentDigest else { throw CloudLearningError.badHash } }
        }
        return state
    }
}

/// One shared overlay implementation for every Apple host. Cloud tombstones and
/// Native CRDT deletion/generation fences are merged before adding any scores.
public struct CloudLearningRankProjection: Codable {
    public let weights: [String: Int]
    public let generations: [String: UInt64]
    public let deleted: Set<String>
    public let represented: [String: [String: LearningEntry]]
    public init(migration: CloudLearningComponentMigration) {
        var values: [String: Int] = [:], epochs: [String: UInt64] = [:]
        let prefix = CloudLearningLayout.shared.rawValue + "\u{001F}"
        for (id, generation) in migration.model.cloudTermGenerations where id.hasPrefix(prefix) {
            epochs[String(id.dropFirst(prefix.count))] = generation
        }
        for term in migration.model.terms.values {
            let id = term.reading + "\u{001F}" + term.text; values[id] = term.weight; epochs[id] = term.termGeneration
        }
        weights = values; generations = epochs
        deleted = Set(epochs.keys).subtracting(values.keys)
        represented = migration.producers.mapValues(\.represented)
    }
    /// Includes tombstones: a locally absent word may already have a newer
    /// shared generation. Explicit deletion must advance beyond that fence.
    public func generation(reading: String, text: String) -> UInt64 {
        let key = LearningEntry(reading: reading.lowercased(), text: text.precomposedStringWithCanonicalMapping).id
        return generations[key] ?? 0
    }
    public func scores(current: [UUID: [LearningEntry]]) throws -> [String: Double] {
        var result = weights, local: [String: LearningEntry] = [:]
        // Project ownership before merge. A host's checkpoint also contains
        // peers, but those counts must not become another local increment.
        for (producer, entries) in current {
            for entry in entries {
                var row = entry; row.counts = [producer.uuidString: entry.counts[producer.uuidString] ?? 0]
                if let old = local[row.id] { local[row.id] = try old.merging(row) }
                else { try row.validate(); local[row.id] = row }
            }
        }
        for row in local.values {
            let epoch = generations[row.id] ?? 0
            guard row.generation >= epoch else { continue }
            // A same-generation cloud removal wins over an offline undeleted
            // component. Only an explicit higher-generation restore can revive.
            if row.deleted || (row.generation == epoch && deleted.contains(row.id)) { result[row.id] = 0; continue }
            if row.generation > epoch { result[row.id] = 0 }
            for (producer, count) in row.counts {
                let baseline = represented[producer]?[row.id]
                let old = baseline?.generation == row.generation ? (baseline?.counts[producer] ?? 0) : 0
                if count > old { result[row.id] = min(200000, (result[row.id] ?? 0) + Int(min(1000, count - old)) * 1000) }
            }
        }
        return result.mapValues { min(0.999, log1p(Double(max(0, $0))) / log1p(200000)) }
    }
}
