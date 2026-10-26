import Foundation

public struct RimeLearnedWord: Equatable {
    public let reading: String
    public let text: String
    public let count: UInt64
    public var id: String { reading + "\u{001F}" + text }
}

public enum RimeLearningFormat {
    public static func parseExport(_ data: Data, capacityProfile: LearningCapacityProfile = LearningCapacityProfiles.legacy5000) throws -> [RimeLearnedWord] {
        let profile = try LearningCapacityProfiles.require(id: capacityProfile.id, version: capacityProfile.version)
        guard data.count <= profile.nativeTsvBytes else { throw InputDataError.oversized }
        guard let string = String(data: data, encoding: .utf8) else { throw InputDataError.invalidRecord }
        var result: [RimeLearnedWord] = [], ids: Set<String> = []
        var learnedRows = 0
        for line in string.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("#") { continue } // Discard engine/device metadata.
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count == 3, let count = UInt64(columns[2]), count <= 1_000_000_000 else { throw InputDataError.invalidRecord }
            let text = String(columns[0]).precomposedStringWithCanonicalMapping
            let reading = String(columns[1]).lowercased().trimmingCharacters(in: .whitespaces)
            let entry = LearningEntry(reading: reading, text: text)
            try entry.validate()
            guard ids.insert(entry.id).inserted else { throw InputDataError.duplicateEntry }
            result.append(.init(reading: reading, text: text, count: count))
            // Rime also exports zero-commit prediction rows. They must remain
            // visible to baseline reconciliation, but are not learned words.
            // Keep the total byte/row validation above; bound positive entries.
            if count > 0 { learnedRows += 1 }
            guard learnedRows <= profile.nativePositiveRows else { throw InputDataError.oversized }
        }
        return result
    }
    public static func importTSV(from model: LearningModel) throws -> Data {
        var lines = ["# Private Input semantic learning snapshot; no host document or engine user ID"]
        for entry in model.entries.values.sorted(by: { $0.id < $1.id }) {
            try entry.validate()
            // Zero-frequency entries carry pins/reset epochs, not a new user
            // dictionary promotion. The engine adapter separately retains
            // genuinely custom words when applying a reset.
            if !entry.deleted && entry.frequency == 0 { continue }
            // Deleted entries need explicit tombstones; Rime's normal export
            // omits them, so disappearance alone must never imply deletion.
            let count = entry.deleted ? "-1" : String(entry.frequency)
            lines.append(entry.text + "\t" + entry.reading + "\t" + count)
        }
        let result = Data((lines.joined(separator: "\n") + "\n").utf8)
        guard result.count <= model.capacityProfile.nativeTsvBytes else { throw InputDataError.oversized }
        return result
    }
}

public struct RimeLearningCheckpoint: Codable {
    public private(set) var model = LearningModel()
    public private(set) var observedCounts: [String: UInt64] = [:]
    public private(set) var appliedGenerations: [String: UInt64]?
    public init() {}
    public var capacityProfile: LearningCapacityProfile { model.capacityProfile }
    public init(capacityProfile: LearningCapacityProfile) throws { model = try LearningModel(capacityProfile: capacityProfile) }
    public mutating func upgradeCapacity(to profile: LearningCapacityProfile) throws {
        var next = self; try next.model.upgradeCapacity(to: profile)
        try next.validateState(); _ = try next.persistedData(); self = next
    }
    public func persistedData() throws -> Data {
        try validateState(); _ = try model.export()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= capacityProfile.checkpointStateBytes else { throw InputDataError.oversized }
        return data
    }
    public static func restore(_ data: Data) throws -> Self {
        let limit = max(LearningCapacityProfiles.legacy5000.checkpointStateBytes, LearningCapacityProfiles.expanded10000.checkpointStateBytes)
        guard data.count <= limit else { throw InputDataError.oversized }
        return try JSONDecoder().decode(Self.self, from: data)
    }
    public mutating func observeExport(_ data: Data, device: String) throws {
        let words = try RimeLearningFormat.parseExport(data, capacityProfile: capacityProfile)
        var next = self
        for word in words {
            if let entry = next.model.entries[word.id], entry.generation > (appliedGenerations?[word.id] ?? 0) { continue }
            let baseline = observedCounts[word.id] ?? 0
            let delta = word.count >= baseline ? word.count - baseline : 0
            if delta > 0 {
                let local = next.model.entries[word.id]?.counts[device] ?? 0
                try next.model.setDeviceCount(reading: word.reading, text: word.text, device: device, count: min(1_000_000_000, local + delta))
            }
            next.observedCounts[word.id] = word.count
        }
        // Missing and explicit zero have the same baseline (`?? 0`). Process
        // zeros first, including positive→zero resets, then compact only zeros.
        // Never discard nonzero proof or a model/pin/reset generation.
        next.observedCounts = next.observedCounts.filter { $0.value > 0 }
        try next.validateState(); self = next
    }
    public mutating func mergeRemoteArchive(_ data: Data) throws { try model.merge(data) }
    public mutating func setPinned(reading: String, text: String, pinned: Bool, device: String) throws {
        try model.setPinned(reading: reading, text: text, pinned: pinned, device: device)
    }
    public mutating func resetFrequency(reading: String, text: String, knownCloudGeneration: UInt64 = 0) throws { try model.resetFrequency(reading: reading, text: text, knownCloudGeneration: knownCloudGeneration) }
    /// Only an explicit candidate selection may revive a forgotten term. Native
    /// exports and old peer snapshots never call this path.
    @discardableResult public mutating func relearnForgotten(reading: String, text: String, device: String, knownCloudGeneration: UInt64 = 0, cloudDeleted: Bool = false) throws -> Bool {
        var next = self
        guard try next.model.relearnDeleted(reading: reading, text: text, device: device,
            knownCloudGeneration: knownCloudGeneration, cloudDeleted: cloudDeleted) else { return false }
        try next.validateState(); self = next
        return true
    }
    public mutating func forget(reading: String, text: String, knownCloudGeneration: UInt64 = 0, device: String? = nil) throws { try model.forget(reading: reading, text: text, knownCloudGeneration: knownCloudGeneration, device: device) }
    public var pendingResets: [LearningEntry] { model.entries.values.filter { !$0.deleted && $0.generation > (appliedGenerations?[$0.id] ?? 0) } }
    // Call ONLY after the actual engine import succeeded and its export was
    // re-read while input was quiescent. Imported counts are not local typing.
    public mutating func establishBaselineAfterImport(_ data: Data) throws {
        var next = self
        next.observedCounts = Dictionary(uniqueKeysWithValues: try RimeLearningFormat.parseExport(data, capacityProfile: capacityProfile).filter { $0.count > 0 }.map { ($0.id, $0.count) })
        next.appliedGenerations = Dictionary(uniqueKeysWithValues: model.entries.values.map { ($0.id, $0.generation) })
        try next.validateState(); self = next
    }
    public func outboundArchive() throws -> Data { try model.export() }
    public func engineImport() throws -> Data { try RimeLearningFormat.importTSV(from: model) }
    private enum CodingKeys: String, CodingKey { case model, observedCounts, appliedGenerations }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        model = try values.decode(LearningModel.self, forKey: .model)
        observedCounts = try values.decode([String: UInt64].self, forKey: .observedCounts)
        appliedGenerations = try values.decodeIfPresent([String: UInt64].self, forKey: .appliedGenerations)
        try validateState()
    }
    public func encode(to encoder: Encoder) throws {
        try validateState()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(model, forKey: .model); try values.encode(observedCounts, forKey: .observedCounts)
        try values.encodeIfPresent(appliedGenerations, forKey: .appliedGenerations)
    }
    private func validateState() throws {
        try model.validateStoredEntries()
        guard observedCounts.count <= capacityProfile.observedCountKeys,
              (appliedGenerations?.count ?? 0) <= capacityProfile.appliedGenerationKeys else { throw InputDataError.oversized }
        for (id, count) in observedCounts {
            try Self.validateEntryID(id)
            guard count <= 1_000_000_000 else { throw InputDataError.invalidRecord }
        }
        for id in appliedGenerations?.keys ?? Dictionary<String, UInt64>().keys { try Self.validateEntryID(id) }
    }
    private static func validateEntryID(_ id: String) throws {
        let pieces = id.split(separator: "\u{001F}", omittingEmptySubsequences: false)
        guard pieces.count == 2 else { throw InputDataError.invalidRecord }
        try LearningEntry(reading: String(pieces[0]), text: String(pieces[1])).validate()
    }

}
