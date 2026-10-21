import Foundation

public struct RimeLearnedWord: Equatable {
    public let reading: String
    public let text: String
    public let count: UInt64
    public var id: String { reading + "\u{001F}" + text }
}

public enum RimeLearningFormat {
    public static func parseExport(_ data: Data) throws -> [RimeLearnedWord] {
        guard data.count <= 2 * 1024 * 1024 else { throw InputDataError.oversized }
        guard let string = String(data: data, encoding: .utf8) else { throw InputDataError.invalidRecord }
        var result: [RimeLearnedWord] = [], ids: Set<String> = []
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
            guard result.count <= 5000 else { throw InputDataError.oversized }
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
        guard result.count <= 2 * 1024 * 1024 else { throw InputDataError.oversized }
        return result
    }
}

public struct RimeLearningCheckpoint: Codable {
    public private(set) var model = LearningModel()
    public private(set) var observedCounts: [String: UInt64] = [:]
    public private(set) var appliedGenerations: [String: UInt64]?
    public init() {}
    public mutating func observeExport(_ data: Data, device: String) throws {
        let words = try RimeLearningFormat.parseExport(data)
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
        self = next
    }
    public mutating func mergeRemoteArchive(_ data: Data) throws { try model.merge(data) }
    public mutating func setPinned(reading: String, text: String, pinned: Bool, device: String) throws {
        try model.setPinned(reading: reading, text: text, pinned: pinned, device: device)
    }
    public mutating func resetFrequency(reading: String, text: String) throws { try model.resetFrequency(reading: reading, text: text) }
    public var pendingResets: [LearningEntry] { model.entries.values.filter { !$0.deleted && $0.generation > (appliedGenerations?[$0.id] ?? 0) } }
    // Call ONLY after the actual engine import succeeded and its export was
    // re-read while input was quiescent. Imported counts are not local typing.
    public mutating func establishBaselineAfterImport(_ data: Data) throws {
        observedCounts = Dictionary(uniqueKeysWithValues: try RimeLearningFormat.parseExport(data).map { ($0.id, $0.count) })
        appliedGenerations = Dictionary(uniqueKeysWithValues: model.entries.values.map { ($0.id, $0.generation) })
    }
    public func outboundArchive() throws -> Data { try model.export() }
    public func engineImport() throws -> Data { try RimeLearningFormat.importTSV(from: model) }
}
