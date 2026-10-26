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

/// Persist only the known identity, never client-supplied numeric limits.
public struct LearningCapacityReference: Codable, Equatable {
    public let profileID: String
    public let profileVersion: Int
    public init(_ profile: LearningCapacityProfile) { profileID = profile.id; profileVersion = profile.version }
    private enum CodingKeys: String, CodingKey { case profileID = "profile_id", profileVersion = "profile_version" }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try values.decode(String.self, forKey: .profileID)
        profileVersion = try values.decode(Int.self, forKey: .profileVersion)
        _ = try resolved()
    }
    public func resolved() throws -> LearningCapacityProfile {
        try LearningCapacityProfiles.require(id: profileID, version: profileVersion)
    }
}

public struct LearningArchive: Codable {
    public var version: Int = 1
    public var schemaID: String = "private_pinyin"
    public var entries: [LearningEntry]
    public var personalLexicon: PersonalLexiconSync?
    public private(set) var capacityProfile = LearningCapacityProfiles.legacy5000
    public init(entries: [LearningEntry], personalLexicon: PersonalLexiconSync? = nil,
                capacityProfile: LearningCapacityProfile = LearningCapacityProfiles.legacy5000) {
        self.entries = entries; self.personalLexicon = personalLexicon; self.capacityProfile = capacityProfile
        version = capacityProfile == LearningCapacityProfiles.legacy5000 ? 1 : 2
    }
    private enum CodingKeys: String, CodingKey { case version, schemaID, entries, personalLexicon, capacityProfile = "capacity_profile" }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        schemaID = try values.decode(String.self, forKey: .schemaID)
        if version == 1 {
            guard !values.contains(.capacityProfile) else { throw InputDataError.incompatibleSchema }
            capacityProfile = LearningCapacityProfiles.legacy5000
        } else if version == 2 {
            capacityProfile = try values.decode(LearningCapacityReference.self, forKey: .capacityProfile).resolved()
            guard capacityProfile == LearningCapacityProfiles.expanded10000 else { throw InputDataError.incompatibleSchema }
        } else { throw InputDataError.incompatibleSchema }
        entries = try values.decode([LearningEntry].self, forKey: .entries)
        personalLexicon = try values.decodeIfPresent(PersonalLexiconSync.self, forKey: .personalLexicon)
    }
    public func encode(to encoder: Encoder) throws {
        let known = try LearningCapacityProfiles.require(id: capacityProfile.id, version: capacityProfile.version)
        guard version == (known == LearningCapacityProfiles.legacy5000 ? 1 : 2) else { throw InputDataError.incompatibleSchema }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version); try values.encode(schemaID, forKey: .schemaID)
        try values.encode(entries, forKey: .entries); try values.encodeIfPresent(personalLexicon, forKey: .personalLexicon)
        if known != LearningCapacityProfiles.legacy5000 { try values.encode(LearningCapacityReference(known), forKey: .capacityProfile) }
    }
}

public struct LearningModel: Codable {
    public private(set) var entries: [String: LearningEntry] = [:]
    public var learningEnabled = true
    public private(set) var personalLexicon: PersonalLexiconSync?
    public private(set) var capacityProfile = LearningCapacityProfiles.legacy5000
    public init() {}
    public init(capacityProfile: LearningCapacityProfile) throws {
        self.capacityProfile = try LearningCapacityProfiles.require(id: capacityProfile.id, version: capacityProfile.version)
    }
    public mutating func upgradeCapacity(to profile: LearningCapacityProfile) throws {
        let target = try LearningCapacityProfiles.require(id: profile.id, version: profile.version)
        guard target.termRows >= capacityProfile.termRows else { throw InputDataError.incompatibleSchema }
        var next = self; next.capacityProfile = target; _ = try next.export(); self = next
    }
    public mutating func record(reading: String, text: String, device: String) throws {
        guard learningEnabled else { return }
        var entry = LearningEntry(reading: reading.lowercased(), text: text.precomposedStringWithCanonicalMapping)
        entry = entries[entry.id] ?? entry
        guard !entry.deleted else { return }
        entry.counts[device] = min(1_000_000_000, (entry.counts[device] ?? 0) + 1)
        try entry.validate()
        guard entries[entry.id] != nil || entries.count < capacityProfile.termRows else { throw InputDataError.oversized }
        entries[entry.id] = entry
    }
    public mutating func setDeviceCount(reading: String, text: String, device: String, count: UInt64) throws {
        guard learningEnabled else { return }
        var entry = LearningEntry(reading: reading.lowercased(), text: text.precomposedStringWithCanonicalMapping)
        entry = entries[entry.id] ?? entry
        guard !entry.deleted else { return }
        entry.counts[device] = max(entry.counts[device] ?? 0, count)
        try entry.validate()
        guard entries[entry.id] != nil || entries.count < capacityProfile.termRows else { throw InputDataError.oversized }
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
        guard sequence < UInt64.max, entries[entry.id] != nil || entries.count < capacityProfile.termRows else { throw InputDataError.oversized }
        entry.pinned = pinned; entry.pinVersion = .init(sequence: sequence + 1, device: device)
        try entry.validate(); entries[entry.id] = entry
    }
    // A new generation makes an explicit reset win over old peer counters.
    // Keep the word and its pin; resetting frequency must not delete either.
    public mutating func resetFrequency(reading: String, text: String) throws {
        var entry = LearningEntry(reading: reading.lowercased(), text: text.precomposedStringWithCanonicalMapping)
        entry = entries[entry.id] ?? entry
        guard !entry.deleted, entry.generation < UInt64.max, entries[entry.id] != nil || entries.count < capacityProfile.termRows else { throw InputDataError.invalidRecord }
        entry.generation += 1; entry.counts = [:]
        try entry.validate(); entries[entry.id] = entry
    }
    // Forget everywhere: a deletion one generation above both the local entry and the
    // known shared-model generation, so stale producers on other devices cannot revive it.
    public mutating func forget(reading: String, text: String, knownCloudGeneration: UInt64 = 0) throws {
        var entry = LearningEntry(reading: reading.lowercased(), text: text.precomposedStringWithCanonicalMapping)
        entry = entries[entry.id] ?? entry
        let base = max(entry.generation, knownCloudGeneration)
        guard base < UInt64.max, entries[entry.id] != nil || entries.count < capacityProfile.termRows else { throw InputDataError.invalidRecord }
        entry.generation = base + 1; entry.deleted = true; entry.counts = [:]; entry.pinned = false
        try entry.validate(); entries[entry.id] = entry
    }
    public mutating func restore(id: String) throws {
        guard var entry = entries[id], entry.deleted else { return }
        guard entry.generation < UInt64.max else { throw InputDataError.invalidRecord }
        entry.generation += 1; entry.deleted = false; entry.counts = [:]; entries[id] = entry
    }
    public func export() throws -> Data {
        guard entries.count <= capacityProfile.termRows else { throw InputDataError.oversized }
        for entry in entries.values { try entry.validate() }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try personalLexicon?.validate()
        let data = try encoder.encode(LearningArchive(entries: entries.values.sorted { $0.id < $1.id },personalLexicon:personalLexicon,capacityProfile:capacityProfile))
        guard data.count <= capacityProfile.learningArchiveBytes else { throw InputDataError.oversized }
        return data
    }
    public mutating func merge(_ data: Data) throws {
        guard data.count <= capacityProfile.learningArchiveBytes else { throw InputDataError.oversized }
        let archive = try JSONDecoder().decode(LearningArchive.self, from: data)
        guard archive.schemaID == "private_pinyin",
              archive.capacityProfile == capacityProfile || archive.capacityProfile == LearningCapacityProfiles.legacy5000 else { throw InputDataError.incompatibleSchema }
        guard archive.entries.count <= capacityProfile.termRows else { throw InputDataError.oversized }
        var next = entries, seen: Set<String> = []
        for entry in archive.entries {
            try entry.validate()
            guard seen.insert(entry.id).inserted else { throw InputDataError.duplicateEntry }
            next[entry.id] = try next[entry.id]?.merging(entry) ?? entry
        }
        guard next.count <= capacityProfile.termRows else { throw InputDataError.oversized }
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
    private struct PersistedBody: Codable {
        let entries: [String: LearningEntry]
        let learningEnabled: Bool
        let personalLexicon: PersonalLexiconSync?
    }
    private enum CodingKeys: String, CodingKey {
        case entries, learningEnabled, personalLexicon
        case capacityProfile = "capacity_profile", profiledModel = "profiled_model"
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if values.contains(.capacityProfile) {
            capacityProfile = try values.decode(LearningCapacityReference.self, forKey: .capacityProfile).resolved()
            guard capacityProfile == LearningCapacityProfiles.expanded10000,
                  !values.contains(.entries), !values.contains(.learningEnabled), !values.contains(.personalLexicon) else { throw InputDataError.incompatibleSchema }
            let body = try values.decode(PersistedBody.self, forKey: .profiledModel)
            entries = body.entries; learningEnabled = body.learningEnabled; personalLexicon = body.personalLexicon
        } else {
            guard !values.contains(.profiledModel) else { throw InputDataError.incompatibleSchema }
            capacityProfile = LearningCapacityProfiles.legacy5000
            entries = try values.decode([String: LearningEntry].self, forKey: .entries)
            learningEnabled = try values.decode(Bool.self, forKey: .learningEnabled)
            personalLexicon = try values.decodeIfPresent(PersonalLexiconSync.self, forKey: .personalLexicon)
        }
        try validateStoredEntries()
    }
    func validateStoredEntries() throws {
        guard entries.count <= capacityProfile.termRows,
              entries.allSatisfy({ $0.key == $0.value.id }) else { throw InputDataError.invalidRecord }
        for row in entries.values { try row.validate() }
        try personalLexicon?.validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validateStoredEntries()
        var values = encoder.container(keyedBy: CodingKeys.self)
        if capacityProfile == LearningCapacityProfiles.legacy5000 {
            try values.encode(entries, forKey: .entries); try values.encode(learningEnabled, forKey: .learningEnabled)
            try values.encodeIfPresent(personalLexicon, forKey: .personalLexicon)
        } else {
            try values.encode(LearningCapacityReference(capacityProfile), forKey: .capacityProfile)
            try values.encode(PersistedBody(entries: entries, learningEnabled: learningEnabled, personalLexicon: personalLexicon), forKey: .profiledModel)
        }
    }

}
