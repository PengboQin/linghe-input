import Foundation

/// An opt-in data model, not a replacement for the version-1 learning wire
/// format. No device, storage, network or engine APIs are called by this file.
public struct RecentLearningPolicy: Equatable {
    public let referenceDay: Int
    public let windowDays: Int
    public init(referenceDay: Int, windowDays: Int = 90) throws {
        guard (90...3_000_000).contains(referenceDay), (1...90).contains(windowDays) else { throw InputDataError.invalidRecord }
        self.referenceDay = referenceDay; self.windowDays = windowDays
    }
    public func accepts(_ day: Int) -> Bool { day > referenceDay - windowDays && day <= referenceDay }
}

/// The caller must authenticate the time source before establishing an anchor.
/// Wall time detects anomalies only; it never dates usage or advances policy.
/// Persisting this value does not make it valid across a different boot session.
public struct RecentLearningClock: Codable, Equatable {
    private let anchorUnixSeconds: Double
    private let anchorUptime: Double
    private let bootSession: String
    private var lastUptime: Double
    public private(set) var trusted = true
    public init(authenticatedUnixSeconds: Double, uptime: Double, bootSession: String) throws {
        guard authenticatedUnixSeconds.isFinite, (0...259_200_000_000).contains(authenticatedUnixSeconds),
              uptime.isFinite, uptime >= 0, !bootSession.isEmpty, bootSession.utf8.count <= 128 else { throw InputDataError.invalidRecord }
        anchorUnixSeconds = authenticatedUnixSeconds; anchorUptime = uptime
        lastUptime = uptime; self.bootSession = bootSession
    }
    private enum CodingKeys: String, CodingKey { case anchorUnixSeconds, anchorUptime, bootSession, lastUptime, trusted }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let anchor = try values.decode(Double.self, forKey: .anchorUnixSeconds)
        let uptime = try values.decode(Double.self, forKey: .anchorUptime)
        let boot = try values.decode(String.self, forKey: .bootSession)
        try self.init(authenticatedUnixSeconds: anchor, uptime: uptime, bootSession: boot)
        lastUptime = try values.decode(Double.self, forKey: .lastUptime)
        trusted = try values.decode(Bool.self, forKey: .trusted)
        guard lastUptime.isFinite, lastUptime >= anchorUptime else { throw InputDataError.invalidRecord }
    }
    public mutating func day(wallUnixSeconds: Double, uptime: Double, bootSession: String) -> Int? {
        guard trusted, anchorUnixSeconds.isFinite, (0...259_200_000_000).contains(anchorUnixSeconds),
              anchorUptime.isFinite, anchorUptime >= 0, lastUptime.isFinite, lastUptime >= anchorUptime,
              !self.bootSession.isEmpty, self.bootSession.utf8.count <= 128,
              wallUnixSeconds.isFinite, uptime.isFinite, bootSession == self.bootSession,
              uptime >= anchorUptime, uptime >= lastUptime, uptime - anchorUptime <= 7 * 86400 else {
            trusted = false; return nil
        }
        let expected = anchorUnixSeconds + uptime - anchorUptime
        guard abs(wallUnixSeconds - expected) <= 86400, expected >= 0, expected <= 259_200_000_000 else {
            trusted = false; return nil
        }
        lastUptime = uptime
        return Int(floor(expected / 86400))
    }
}

public struct RecentLearningBucket: Codable, Equatable {
    public var day: Int
    public var counts: [String: UInt64]
    public init(day: Int, counts: [String: UInt64]) { self.day = day; self.counts = counts }
}

public struct RecentLearningEntry: Codable, Equatable {
    public var word: LearningEntry
    public var buckets: [RecentLearningBucket]
    public init(word: LearningEntry, buckets: [RecentLearningBucket] = []) { self.word = word; self.buckets = buckets }
    public func validate() throws {
        try word.validate()
        guard buckets.count <= 90 else { throw InputDataError.oversized }
        var days = Set<Int>(), subtotal: [String: UInt64] = [:]
        for bucket in buckets {
            guard (0...3_000_000).contains(bucket.day), days.insert(bucket.day).inserted,
                  !bucket.counts.isEmpty, bucket.counts.count <= 64 else { throw InputDataError.invalidRecord }
            for (replica, count) in bucket.counts {
                guard let total = word.counts[replica], count > 0, count <= 1_000_000_000,
                      (subtotal[replica] ?? 0) <= total, count <= total - (subtotal[replica] ?? 0) else { throw InputDataError.invalidRecord }
                subtotal[replica, default: 0] += count
            }
        }
    }
    public func normalized(_ policy: RecentLearningPolicy) throws -> Self {
        try validate()
        return Self(word: word, buckets: buckets.filter { policy.accepts($0.day) }.sorted { $0.day < $1.day })
    }
    public func merging(_ other: Self, policy: RecentLearningPolicy) throws -> Self {
        let left = try normalized(policy), right = try other.normalized(policy)
        guard left.word.id == right.word.id else { throw InputDataError.invalidRecord }
        // One logical version must have one value. Refuse a fork rather than
        // making the result depend on which peer happened to arrive first.
        guard left.word.pinVersion != right.word.pinVersion || left.word.pinned == right.word.pinned else { throw InputDataError.invalidRecord }
        let word = try left.word.merging(right.word)
        let buckets: [RecentLearningBucket]
        if left.word.generation != right.word.generation {
            buckets = left.word.generation > right.word.generation ? left.buckets : right.buckets
        } else {
            var days = Dictionary(uniqueKeysWithValues: left.buckets.map { ($0.day, $0.counts) })
            for bucket in right.buckets {
                var counts = days[bucket.day] ?? [:]
                for (replica, count) in bucket.counts { counts[replica] = max(counts[replica] ?? 0, count) }
                days[bucket.day] = counts
            }
            buckets = days.map { RecentLearningBucket(day: $0.key, counts: $0.value) }.sorted { $0.day < $1.day }
        }
        let result = Self(word: word, buckets: buckets)
        try result.validate(); return result
    }
}

public struct RecentLearningArchive: Codable {
    public var version = 2
    public var schemaID = "private_pinyin_recency"
    public var algorithmVersion = 1
    public var entries: [RecentLearningEntry]
    public var personalLexicon: PersonalLexiconSync?
    public init(entries: [RecentLearningEntry], personalLexicon: PersonalLexiconSync? = nil) {
        self.entries = entries; self.personalLexicon = personalLexicon
    }
}

public struct RecentLearningScore: Equatable {
    public let pinned: Bool
    public let historical: Double
    public let recent: Double
    public var total: Double { historical + recent }
}

public struct RecentLearningDelta {
    public let reading: String
    public let text: String
    public let replica: String
    public let amount: UInt64
    public let trustedDay: Int?
    public init(reading: String, text: String, replica: String, amount: UInt64, trustedDay: Int?) {
        self.reading = reading; self.text = text; self.replica = replica
        self.amount = amount; self.trustedDay = trustedDay
    }
}

public struct RecentLearningModel {
    public static let byteLimit = 2 * 1024 * 1024
    public static let componentLimit = 40_000
    public private(set) var entries: [String: RecentLearningEntry] = [:]
    public private(set) var personalLexicon: PersonalLexiconSync?
    public var learningEnabled = true
    public init() {}

    /// Only checkpoint-confirmed local positive increments belong here.
    /// An absent/untrusted date preserves cumulative usage without inventing
    /// recent use. Never call this for imports, clipboard or generated content.
    public mutating func recordLocalDelta(reading: String, text: String, replica: String, amount: UInt64,
                                         trustedDay: Int?, policy: RecentLearningPolicy) throws {
        try recordLocalDeltas([.init(reading: reading, text: text, replica: replica, amount: amount, trustedDay: trustedDay)], policy: policy)
    }
    /// One checkpoint batch, one size/encoding validation. Do not repeatedly
    /// serialize a complete archive for each word or run this on key-down.
    public mutating func recordLocalDeltas(_ deltas: [RecentLearningDelta], policy: RecentLearningPolicy) throws {
        guard learningEnabled else { return }
        guard deltas.count <= 5000 else { throw InputDataError.oversized }
        var next = self
        for delta in deltas { try next.applyLocalDelta(delta, policy: policy) }
        next.entries = try next.entries.mapValues { try $0.normalized(policy) }
        _ = try next.export(policy: policy); self = next
    }
    private mutating func applyLocalDelta(_ delta: RecentLearningDelta, policy: RecentLearningPolicy) throws {
        let (reading, text, replica, amount, trustedDay) = (delta.reading, delta.text, delta.replica, delta.amount, delta.trustedDay)
        guard amount <= 1_000_000_000, !replica.isEmpty else { throw InputDataError.invalidRecord }
        guard amount > 0 else { return }
        let word = LearningEntry(reading: reading.lowercased(), text: text.precomposedStringWithCanonicalMapping)
        var entry = try (entries[word.id] ?? RecentLearningEntry(word: word)).normalized(policy)
        guard !entry.word.deleted else { return }
        let old = entry.word.counts[replica] ?? 0
        let increment = min(amount, 1_000_000_000 - old)
        entry.word.counts[replica] = old + increment
        if increment > 0, let day = trustedDay, policy.accepts(day) {
            if let i = entry.buckets.firstIndex(where: { $0.day == day }) {
                entry.buckets[i].counts[replica, default: 0] += increment
            } else { entry.buckets.append(.init(day: day, counts: [replica: increment])) }
        }
        try entry.validate()
        entries[word.id] = entry
    }

    /// Legacy migration adds no fabricated timestamps, and re-importing the
    /// same totals cannot add fresh buckets. The version-1 file is not changed.
    public mutating func mergeLegacy(_ data: Data, policy: RecentLearningPolicy) throws {
        var legacy = LearningModel(); try legacy.merge(data)
        try mergeEntries(Array(legacy.entries.values).map { .init(word: $0) }, personalLexicon: legacy.personalLexicon, policy: policy)
    }
    public mutating func merge(_ data: Data, policy: RecentLearningPolicy) throws {
        guard data.count <= Self.byteLimit else { throw InputDataError.oversized }
        let archive = try JSONDecoder().decode(RecentLearningArchive.self, from: data)
        guard archive.version == 2, archive.schemaID == "private_pinyin_recency", archive.algorithmVersion == 1 else { throw InputDataError.incompatibleSchema }
        try mergeEntries(archive.entries, personalLexicon: archive.personalLexicon, policy: policy)
    }
    private mutating func mergeEntries(_ incoming: [RecentLearningEntry], personalLexicon: PersonalLexiconSync?, policy: RecentLearningPolicy) throws {
        guard incoming.count <= 5000 else { throw InputDataError.oversized }
        var next = self, seen = Set<String>()
        for entry in incoming {
            try entry.validate()
            guard seen.insert(entry.word.id).inserted else { throw InputDataError.duplicateEntry }
            next.entries[entry.word.id] = try next.entries[entry.word.id]?.merging(entry, policy: policy) ?? entry.normalized(policy)
        }
        if let personalLexicon {
            var combined = next.personalLexicon ?? PersonalLexiconSync()
            try combined.merge(personalLexicon); next.personalLexicon = combined
        }
        next.entries = try next.entries.mapValues { try $0.normalized(policy) }
        _ = try next.export(policy: policy); self = next
    }
    public func export(policy: RecentLearningPolicy) throws -> Data {
        guard entries.count <= 5000 else { throw InputDataError.oversized }
        var components = 0
        let normalized = try entries.values.map { entry -> RecentLearningEntry in
            let value = try entry.normalized(policy)
            components += value.buckets.reduce(0) { $0 + $1.counts.count }
            guard components <= Self.componentLimit else { throw InputDataError.oversized }
            return value
        }.sorted { $0.word.id < $1.word.id }
        try personalLexicon?.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(RecentLearningArchive(entries: normalized, personalLexicon: personalLexicon))
        guard data.count <= Self.byteLimit else { throw InputDataError.oversized }
        return data
    }
    /// Deliberate compatibility projection, never a complete v2 backup. Do not
    /// replace durable v2 state with this lossy view after an older peer echoes it.
    public func legacyProjection() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(LearningArchive(entries: entries.values.map(\.word).sorted { $0.id < $1.id }, personalLexicon: personalLexicon))
        var check = LearningModel(); try check.merge(data); return data
    }
    public mutating func resetFrequency(id: String, policy: RecentLearningPolicy) throws {
        guard var entry = entries[id], !entry.word.deleted, entry.word.generation < UInt64.max else { throw InputDataError.invalidRecord }
        entry.word.generation += 1; entry.word.counts = [:]; entry.buckets = []
        var next = self; next.entries[id] = entry; _ = try next.export(policy: policy); self = next
    }
    public mutating func remove(id: String, policy: RecentLearningPolicy) throws {
        guard var entry = entries[id] else { return }
        entry.word.deleted = true
        var next = self; next.entries[id] = entry; _ = try next.export(policy: policy); self = next
    }
    public mutating func restore(id: String, policy: RecentLearningPolicy) throws {
        guard var entry = entries[id], entry.word.deleted else { return }
        guard entry.word.generation < UInt64.max else { throw InputDataError.invalidRecord }
        entry.word.generation += 1; entry.word.deleted = false; entry.word.counts = [:]; entry.buckets = []
        var next = self; next.entries[id] = entry; _ = try next.export(policy: policy); self = next
    }
    public mutating func setPinned(id: String, pinned: Bool, replica: String, policy: RecentLearningPolicy) throws {
        guard !replica.isEmpty, replica.utf8.count <= 128,
              var entry = entries[id], !entry.word.deleted else { throw InputDataError.invalidRecord }
        let maximum = entries.values.map { $0.word.pinVersion.sequence }.max() ?? 0
        guard maximum < UInt64.max else { throw InputDataError.oversized }
        entry.word.pinned = pinned; entry.word.pinVersion = .init(sequence: maximum + 1, device: replica)
        var next = self; next.entries[id] = entry; _ = try next.export(policy: policy); self = next
    }
    /// Applies only inside an already eligible spelling/candidate class. Pins
    /// remain a separate user control, not an extra numerical bonus.
    public func score(id: String, policy: RecentLearningPolicy?) throws -> RecentLearningScore? {
        guard let entry = entries[id] else { return nil }; try entry.validate()
        guard !entry.word.deleted else { return nil }
        let base = 0.20 * log1p(Double(entry.word.frequency)) / log1p(1_000_000_000)
        var short = 0.0, long = 0.0
        if let policy {
            for bucket in entry.buckets where policy.accepts(bucket.day) {
                let age = Double(policy.referenceDay - bucket.day)
                let count = bucket.counts.values.reduce(0.0) { $0 + Double($1) }
                if age < 7 { short += count * pow(2, -age / 2) }
                long += count * pow(2, -age / 30)
            }
        }
        return .init(pinned: entry.word.pinned, historical: base, recent: 0.55 * short / (short + 4) + 0.25 * long / (long + 30))
    }
}

/// This is a pure decision, not a declaration that a relay/member is capable.
/// Every active writer, including a phone keyboard's separate replica, must be
/// authenticated by the integration layer. An empty/missing member is unsafe.
public enum RecentLearningCompatibility {
    public static let capability = "learning-recency-v2"
    public static func canPublish(activeWriters: Set<String>, authenticatedCapabilities: [String: Set<String>]) -> Bool {
        !activeWriters.isEmpty && activeWriters.allSatisfy { !$0.isEmpty && authenticatedCapabilities[$0]?.contains(capability) == true }
    }
}
