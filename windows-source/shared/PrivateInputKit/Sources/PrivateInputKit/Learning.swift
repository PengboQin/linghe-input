import Foundation

public enum InputDataError: Error { case invalidRecord, incompatibleSchema, oversized, duplicateEntry }

public struct LogicalVersion: Codable, Equatable, Comparable {
    public var sequence: UInt64
    public var device: String
    public init(sequence: UInt64, device: String) { self.sequence = sequence; self.device = device }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.sequence == rhs.sequence ? lhs.device < rhs.device : lhs.sequence < rhs.sequence
    }
}

public struct LearningEntry: Codable, Equatable, Identifiable {
    public var reading: String
    public var text: String
    public var generation: UInt64
    public var deleted: Bool
    public var counts: [String: UInt64]
    public var pinned: Bool
    public var pinVersion: LogicalVersion
    public var id: String { reading + "\u{001F}" + text }
    public var frequency: UInt64 { counts.values.reduce(0) { min(1_000_000_000, $0 + $1) } }
    public init(reading: String, text: String, generation: UInt64 = 0, deleted: Bool = false, counts: [String: UInt64] = [:], pinned: Bool = false, pinVersion: LogicalVersion = .init(sequence: 0, device: "")) {
        self.reading = reading; self.text = text; self.generation = generation
        self.deleted = deleted; self.counts = counts; self.pinned = pinned; self.pinVersion = pinVersion
    }
    public func validate() throws {
        guard !reading.isEmpty, reading.utf8.count <= 128, reading.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == " " || $0 == "'") }),
              !text.isEmpty, text.utf8.count <= 1024, !text.contains("\u{001F}"),
              !text.contains("\t"), !text.contains("\n"), !text.contains("\r"), !text.contains("\0"),
              counts.count <= 64, counts.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 128 && $0.value <= 1_000_000_000 }),
              pinVersion.device.utf8.count <= 128 else { throw InputDataError.invalidRecord }
    }
    public func merging(_ other: Self) throws -> Self {
        try validate(); try other.validate()
        guard id == other.id else { throw InputDataError.invalidRecord }
        if generation != other.generation {
            var result = generation > other.generation ? self : other
            // Frequency epochs and pin versions are independent. An offline
            // peer may change its pin after another peer resets frequency.
            let pin = pinVersion < other.pinVersion ? other : self
            result.pinned = pin.pinned; result.pinVersion = pin.pinVersion
            return result
        }
        var result = self
        result.deleted = deleted || other.deleted
        for (device, value) in other.counts { result.counts[device] = max(result.counts[device] ?? 0, value) }
        if pinVersion < other.pinVersion { result.pinned = other.pinned; result.pinVersion = other.pinVersion }
        try result.validate(); return result
    }
}

public struct LearningArchive: Codable {
    public var version: Int = 1
    public var schemaID: String = "private_pinyin"
    public var entries: [LearningEntry]
    public var personalLexicon: PersonalLexiconSync?
    public init(entries: [LearningEntry],personalLexicon:PersonalLexiconSync? = nil) { self.entries = entries;self.personalLexicon=personalLexicon }
}

public struct LearningModel: Codable {
    public private(set) var entries: [String: LearningEntry] = [:]
    public var learningEnabled = true
    public private(set) var personalLexicon: PersonalLexiconSync?
    public init() {}
    public mutating func record(reading: String, text: String, device: String) throws {
        guard learningEnabled else { return }
        var entry = LearningEntry(reading: reading.lowercased(), text: text.precomposedStringWithCanonicalMapping)
        entry = entries[entry.id] ?? entry
        guard !entry.deleted else { return }
        entry.counts[device] = min(1_000_000_000, (entry.counts[device] ?? 0) + 1)
        try entry.validate()
        guard entries[entry.id] != nil || entries.count < 5000 else { throw InputDataError.oversized }
        entries[entry.id] = entry
    }
    public mutating func setDeviceCount(reading: String, text: String, device: String, count: UInt64) throws {
        guard learningEnabled else { return }
        var entry = LearningEntry(reading: reading.lowercased(), text: text.precomposedStringWithCanonicalMapping)
        entry = entries[entry.id] ?? entry
        guard !entry.deleted else { return }
        entry.counts[device] = max(entry.counts[device] ?? 0, count)
        try entry.validate()
        guard entries[entry.id] != nil || entries.count < 5000 else { throw InputDataError.oversized }
        entries[entry.id] = entry
    }
    public mutating func remove(id: String) {
        guard var entry = entries[id] else { return }
        entry.deleted = true; entries[id] = entry
    }
    public mutating func setPinned(reading: String, text: String, pinned: Bool, device: String) throws {
        var entry = LearningEntry(reading: reading.lowercased(), text: text.precomposedStringWithCanonicalMapping)
        entry = entries[entry.id] ?? entry
        guard !entry.deleted else { throw InputDataError.invalidRecord }
        let sequence = entries.values.map { $0.pinVersion.sequence }.max() ?? 0
        guard sequence < UInt64.max, entries[entry.id] != nil || entries.count < 5000 else { throw InputDataError.oversized }
        entry.pinned = pinned; entry.pinVersion = .init(sequence: sequence + 1, device: device)
        try entry.validate(); entries[entry.id] = entry
    }
    // A new generation makes an explicit reset win over old peer counters.
    // Keep the word and its pin; resetting frequency must not delete either.
    public mutating func resetFrequency(reading: String, text: String) throws {
        var entry = LearningEntry(reading: reading.lowercased(), text: text.precomposedStringWithCanonicalMapping)
        entry = entries[entry.id] ?? entry
        guard !entry.deleted, entry.generation < UInt64.max, entries[entry.id] != nil || entries.count < 5000 else { throw InputDataError.invalidRecord }
        entry.generation += 1; entry.counts = [:]
        try entry.validate(); entries[entry.id] = entry
    }
    public mutating func restore(id: String) throws {
        guard var entry = entries[id], entry.deleted else { return }
        guard entry.generation < UInt64.max else { throw InputDataError.invalidRecord }
        entry.generation += 1; entry.deleted = false; entry.counts = [:]; entries[id] = entry
    }
    public func export() throws -> Data {
        guard entries.count <= 5000 else { throw InputDataError.oversized }
        for entry in entries.values { try entry.validate() }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try personalLexicon?.validate()
        let data = try encoder.encode(LearningArchive(entries: entries.values.sorted { $0.id < $1.id },personalLexicon:personalLexicon))
        guard data.count <= 2 * 1024 * 1024 else { throw InputDataError.oversized }
        return data
    }
    public mutating func merge(_ data: Data) throws {
        guard data.count <= 2 * 1024 * 1024 else { throw InputDataError.oversized }
        let archive = try JSONDecoder().decode(LearningArchive.self, from: data)
        guard archive.version == 1, archive.schemaID == "private_pinyin" else { throw InputDataError.incompatibleSchema }
        guard archive.entries.count <= 5000 else { throw InputDataError.oversized }
        var next = entries, seen: Set<String> = []
        for entry in archive.entries {
            try entry.validate()
            guard seen.insert(entry.id).inserted else { throw InputDataError.duplicateEntry }
            next[entry.id] = try next[entry.id]?.merging(entry) ?? entry
        }
        guard next.count <= 5000 else { throw InputDataError.oversized }
        // A valid 2MiB peer archive can make the union exceed our persisted/wire
        // limit. Reject before mutation so later reads don't become unusable.
        var candidate = self; candidate.entries = next
        if let incoming=archive.personalLexicon { var combined=candidate.personalLexicon ?? PersonalLexiconSync();try combined.merge(incoming);candidate.personalLexicon=combined }
        _ = try candidate.export()
        self = candidate
    }
    public mutating func mergePersonalLexicon(_ incoming:PersonalLexiconSync) throws {
        var candidate=self;var combined=personalLexicon ?? PersonalLexiconSync();try combined.merge(incoming)
        candidate.personalLexicon=combined;_ = try candidate.export();self=candidate
    }
}
