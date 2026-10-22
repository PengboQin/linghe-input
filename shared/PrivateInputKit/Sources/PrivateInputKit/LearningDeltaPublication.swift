import Foundation
import CryptoKit

/// A wire-compatible delta of the existing per-device MAX counter CRDT. It is
/// prepared off the key path and checkpointed only after durable enqueue.
/// Older peers can merge it without upgrading their encrypted relay protocol.
public struct LearningDeltaCheckpoint: Codable, Equatable {
    public let version: Int
    public let group: UUID
    public let epoch: UInt64
    public let entries: [String: Data]
    public let personalDigest: Data?
    public let personalEntries: [String: Data]?
}

public struct LearningDeltaPublication {
    public let payload: Data?
    public let checkpoint: LearningDeltaCheckpoint
    public let changedEntries: Int
    public let bootstrap: Bool

    public static func prepare(archive: Data, group: UUID, epoch: UInt64,
                               previous: LearningDeltaCheckpoint?) throws -> Self {
        guard epoch > 0 else { throw InputDataError.invalidRecord }
        var model = LearningModel(); try model.merge(archive)
        let canonical = try model.export()
        let decoded = try JSONDecoder().decode(LearningArchive.self, from: canonical)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let prior: LearningDeltaCheckpoint?
        if let previous, previous.version == 2, previous.group == group, previous.epoch == epoch,
           previous.entries.count <= 5000, previous.entries.values.allSatisfy({ $0.count == 32 }),
           previous.entries.keys.allSatisfy({ Data(base64Encoded: $0)?.count == 32 }),
           (previous.personalEntries?.count ?? 0) <= 4000,
           previous.personalEntries?.allSatisfy({ UUID(uuidString: $0.key) != nil && $0.value.count == 32 }) ?? true,
           previous.personalDigest == nil || previous.personalDigest?.count == 32 {
            prior = previous
        } else { prior = nil }
        var hashes: [String: Data] = [:], changed: [LearningEntry] = []
        for entry in decoded.entries {
            let hash = Data(SHA256.hash(data: try encoder.encode(entry)))
            let key = Data(SHA256.hash(data: Data(entry.id.utf8))).base64EncodedString()
            hashes[key] = hash
            if prior?.entries[key] != hash { changed.append(entry) }
        }
        // Entries are retained as explicit deleted/generation controls. A row
        // silently disappearing is not a tombstone and cannot safely be omitted.
        if let prior, !Set(prior.entries.keys).isSubset(of: Set(hashes.keys)) {
            throw InputDataError.invalidRecord
        }
        let personalHash = try decoded.personalLexicon.map { Data(SHA256.hash(data: try encoder.encode($0))) }
        let personalChanged = prior?.personalDigest != personalHash
        if prior?.personalDigest != nil && personalHash == nil { throw InputDataError.invalidRecord }
        var personalHashes: [String: Data] = [:], personalChangedIDs = Set<String>()
        if let personal = decoded.personalLexicon {
            for (id, record) in personal.records {
                let hash = Data(SHA256.hash(data: try encoder.encode(record))); personalHashes[id] = hash
                if prior?.personalEntries?[id] != hash { personalChangedIDs.insert(id) }
            }
        }
        if let old = prior?.personalEntries, !Set(old.keys).isSubset(of: Set(personalHashes.keys)) { throw InputDataError.invalidRecord }
        let personalDelta = personalChanged ? try decoded.personalLexicon?.selectingRecords(personalChangedIDs) : nil
        let delta = LearningArchive(entries: changed, personalLexicon: personalDelta)
        let bytes = changed.isEmpty && !personalChanged ? nil : try encoder.encode(delta)
        return .init(payload: bytes,
                     checkpoint: .init(version: 2, group: group, epoch: epoch, entries: hashes, personalDigest: personalHash, personalEntries: personalHashes),
                     changedEntries: changed.count, bootstrap: prior == nil)
    }
}
