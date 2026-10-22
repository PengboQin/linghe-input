import Foundation
import CryptoKit

/// Explicitly activated, serial-owner value state. Persist atomically after
/// mutation, before acknowledging/discarding anything. No engine/network APIs.
/// UI sessions retain their old snapshot while this staged model is updated.
public struct CloudLearningReplica: Codable {
    public let group, device, installation: UUID
    public let generation, consentVersion: UInt64
    public private(set) var nextSequence: UInt64 = 1
    public private(set) var receivedSequence: UInt64 = 0
    public private(set) var producerWatermarks: [CloudLearningProducerWatermark]?
    public private(set) var modelVersion: UInt64 = 0
    public private(set) var terms: [String: CloudLearningTerm] = [:]
    public private(set) var cloudTermGenerations: [String: UInt64] = [:]
    public private(set) var termGenerations: [String: UInt64] = [:]
    public private(set) var observations: [CloudLearningEvent] = []
    public init(group: UUID, device: UUID, installation: UUID, generation: UInt64, consentVersion: UInt64) throws {
        guard generation > 0, consentVersion > 0 else { throw CloudLearningError.invalid }
        self.group = group; self.device = device; self.installation = installation
        self.generation = generation; self.consentVersion = consentVersion
    }
    @discardableResult
    public mutating func record(kind: CloudLearningAction, reading: String, text: String, layout: CloudLearningLayout,
                                now: UInt64, count: Int? = nil, policy: CloudLearningTextPolicy) throws -> CloudLearningEvent {
        guard observations.count < 8192, nextSequence < Int64.max else { throw CloudLearningError.oversized }
        guard policy.allowsTerm(text) else { throw CloudLearningError.invalid }
        let id = CloudLearningLayout.shared.rawValue + "\u{001F}" + reading + "\u{001F}" + text
        let event = try CloudLearningEvent(deviceSeq: nextSequence, kind: kind, reading: reading, text: text,
                                          layout: layout, termGeneration: termGenerations[id] ?? 0, observedAt: now, count: count)
        if kind == .reset || kind == .remove || kind == .restore {
            guard event.termGeneration < Int64.max else { throw CloudLearningError.invalid }
            termGenerations[id] = event.termGeneration + 1
        }
        observations.append(event); nextSequence += 1; return event
    }
    public func pendingUpload(limit: Int = 128) -> [CloudLearningEvent] {
        Array(observations.lazy.filter { $0.deviceSeq > receivedSequence }.prefix(max(0, min(128, limit))))
    }
    public mutating func receive(_ receipt: CloudLearningReceipt, batch: [CloudLearningEvent]) throws {
        if receipt.receivedDeviceSeq >= nextSequence { throw CloudLearningError.localStateBehindServer }
        let ids = receipt.acceptedEventIDs + (receipt.rejectedEventIDs ?? []).map(\.eventID)
        guard receipt.generation == generation, receipt.consentVersion == consentVersion,
              !batch.isEmpty, ids.count == batch.count, Set(ids) == Set(batch.map(\.eventID)),
              receipt.receivedDeviceSeq >= (batch.map(\.deviceSeq).max() ?? 0),
              receipt.receivedDeviceSeq < nextSequence,
              batch.allSatisfy({ sent in observations.contains(sent) || sent.deviceSeq <= receivedSequence }) else { throw CloudLearningError.invalid }
        var next = self
        next.receivedSequence = max(receivedSequence, receipt.receivedDeviceSeq)
        let rejected = Set((receipt.rejectedEventIDs ?? []).map(\.eventID))
        next.observations.removeAll { rejected.contains($0.eventID) }
        for control in receipt.termGenerations ?? [] { next.termGenerations[control.id] = max(next.termGenerations[control.id] ?? 0, control.termGeneration) }
        self = next
    }
    public mutating func stage(_ delta: CloudLearningDelta, policy: CloudLearningTextPolicy) throws {
        guard delta.generation == generation, ["bounded-confirmed-decay-v1", "shared-lexeme-decay-v2"].contains(delta.algorithmVersion), delta.fromVersion == modelVersion,
              delta.toVersion >= modelVersion, delta.upserts.count <= 5000, delta.tombstones.count <= 5000,
              Set(delta.upserts.map(\.id)).count == delta.upserts.count,
              Set(delta.tombstones.map(\.id)).count == delta.tombstones.count,
              Set(delta.upserts.map(\.id)).isDisjoint(with: Set(delta.tombstones.map(\.id))) else { throw CloudLearningError.staleModel }
        guard delta.algorithmVersion != "shared-lexeme-decay-v2" || (delta.producerWatermarks != nil && delta.upserts.allSatisfy { $0.layout == .shared } && delta.tombstones.allSatisfy { $0.layout == .shared }) else { throw CloudLearningError.invalid }
        var next = self
        for term in delta.upserts {
            guard (0...200000).contains(term.weight), policy.allowsTerm(term.text),
                  term.termGeneration >= (cloudTermGenerations[term.id] ?? 0) else { throw CloudLearningError.invalid }
            next.terms[term.id] = term; next.termGenerations[term.id] = max(termGenerations[term.id] ?? 0, term.termGeneration)
            next.cloudTermGenerations[term.id] = term.termGeneration
        }
        for term in delta.tombstones {
            guard term.termGeneration >= (cloudTermGenerations[term.id] ?? 0) else { throw CloudLearningError.invalid }
            next.terms.removeValue(forKey: term.id); next.termGenerations[term.id] = max(termGenerations[term.id] ?? 0, term.termGeneration)
            next.cloudTermGenerations[term.id] = term.termGeneration
        }
        guard next.terms.count <= 5000 else { throw CloudLearningError.oversized }
        let actualHash = try Self.hash(generation: generation, terms: Array(next.terms.values), watermarks: delta.watermarks, algorithmVersion: delta.algorithmVersion, producers: delta.producerWatermarks)
        guard actualHash == delta.modelSHA256 else { throw CloudLearningError.badHash }
        let own = delta.watermarks.filter { $0.deviceID == device && $0.installationID == installation && $0.consentVersion == consentVersion }
        guard own.count <= 1 else { throw CloudLearningError.invalid }
        if let watermark = own.first {
            guard watermark.deviceSeq < nextSequence else { throw CloudLearningError.localStateBehindServer }
            next.receivedSequence = max(next.receivedSequence, watermark.deviceSeq)
            next.observations.removeAll { $0.deviceSeq <= watermark.deviceSeq }
        }
        next.producerWatermarks = delta.producerWatermarks
        next.modelVersion = delta.toVersion; self = next
    }
    /// Do not add an event already represented by a worker ACK a second time.
    public func localPendingCount(reading: String, text: String, layout: CloudLearningLayout) -> Int {
        let id = CloudLearningLayout.shared.rawValue + "\u{001F}" + reading + "\u{001F}" + text
        return observations.filter { $0.kind == .confirm && $0.reading == reading && $0.text == text && $0.termGeneration == (termGenerations[id] ?? 0) }
            .reduce(0) { $0 + ($1.count ?? 1) }
    }
    /// A ranking contribution only. Exact 26-key path priority is a separate
    /// tier. Replay unaggregated explicit controls before exposing cloud data.
    public func effectiveTerm(reading: String, text: String, layout: CloudLearningLayout) -> CloudLearningTerm? {
        let id = CloudLearningLayout.shared.rawValue + "\u{001F}" + reading + "\u{001F}" + text
        let legacyID = layout.rawValue + "\u{001F}" + reading + "\u{001F}" + text
        let base = terms[id] ?? terms[legacyID]
        var version = base?.termGeneration ?? cloudTermGenerations[id] ?? 0, weight = base?.weight ?? 0, pinned = base?.pinned ?? false
        var removed = base == nil
        for event in observations.sorted(by: { $0.deviceSeq < $1.deviceSeq }) where event.reading == reading && event.text == text {
            guard event.termGeneration == version else { continue }
            switch event.kind {
            case .reset: version += 1; weight = 0; pinned = false; removed = false
            case .remove: version += 1; weight = 0; pinned = false; removed = true
            case .restore: version += 1; weight = 0; pinned = false; removed = false
            case .pin:
                if !removed || (base == nil && version == 0) { pinned = true; removed = false }
            case .unpin: pinned = false
            case .confirm:
                // An unknown term can be locally learned; an explicit pending
                // remove cannot be bypassed by a subsequent stale confirmation.
                if base == nil && version == 0 { removed = false }
                if !removed { weight = min(200000, weight + (event.count ?? 1) * 1000) }
            }
        }
        guard !removed, version >= (termGenerations[id] ?? 0) else { return nil }
        return CloudLearningTerm(reading: reading, text: text, layout: layout, termGeneration: version, weight: weight, pinned: pinned)
    }
    public static func hash(generation: UInt64, terms: [CloudLearningTerm], watermarks: [CloudLearningWatermark], algorithmVersion: String = "bounded-confirmed-decay-v1", producers: [CloudLearningProducerWatermark]? = nil) throws -> String {
        struct Model: Encodable { let generation: UInt64; let algorithm_version: String; let upserts: [CloudLearningTerm]; let watermarks: [CloudLearningWatermark]; let producer_watermarks: [CloudLearningProducerWatermark]? }
        let entries = terms.sorted { ($0.layout.rawValue, $0.reading, $0.text) < ($1.layout.rawValue, $1.reading, $1.text) }
        let marks = watermarks.sorted { ($0.deviceID.uuidString, $0.installationID.uuidString) < ($1.deviceID.uuidString, $1.installationID.uuidString) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(Model(generation: generation, algorithm_version: algorithmVersion, upserts: entries, watermarks: marks, producer_watermarks: producers?.sorted { $0.producerID.uuidString < $1.producerID.uuidString })))
            .map { String(format: "%02x", $0) }.joined()
    }
    public func persistedData() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= 4 * 1024 * 1024 else { throw CloudLearningError.oversized }; return data
    }
    public static func restore(_ data: Data) throws -> Self {
        guard data.count <= 4 * 1024 * 1024 else { throw CloudLearningError.oversized }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.generation > 0, value.consentVersion > 0, value.observations.count <= 8192, value.terms.count <= 5000, value.cloudTermGenerations.count <= 5000,
              value.receivedSequence < value.nextSequence, value.nextSequence <= Int64.max,
              Set(value.observations.map(\.eventID)).count == value.observations.count,
              Set(value.observations.map(\.deviceSeq)).count == value.observations.count else { throw CloudLearningError.invalid }
        for event in value.observations { try event.validate(); guard event.deviceSeq < value.nextSequence else { throw CloudLearningError.invalid } }
        let pending = value.observations.filter { $0.deviceSeq > value.receivedSequence }.map(\.deviceSeq).sorted()
        guard UInt64(pending.count) == value.nextSequence - value.receivedSequence - 1,
              pending.enumerated().allSatisfy({ $0.element == value.receivedSequence + UInt64($0.offset) + 1 }) else { throw CloudLearningError.invalid }
        return value
    }
}
