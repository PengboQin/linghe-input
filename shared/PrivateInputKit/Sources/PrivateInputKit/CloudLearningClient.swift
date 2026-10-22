import Foundation
import CryptoKit

public enum CloudLearningError: Error { case invalid, unsupported, staleModel, localStateBehindServer, badHash, oversized, remote(String), http(Int) }
public enum CloudLearningLayout: String, Codable { case pinyin26, t9, shared }
public enum CloudLearningAction: String, Codable { case confirm, reset, remove, restore, pin, unpin }

/// Confirmed selection/control signals only, never a clipboard or raw key log.
public struct CloudLearningEvent: Codable, Equatable {
    public let eventID: UUID
    public let deviceSeq: UInt64
    public let kind: CloudLearningAction
    public let reading, text: String
    public let layout: CloudLearningLayout
    public let termGeneration, observedAt: UInt64
    public let count: Int?
    enum CodingKeys: String, CodingKey {
        case eventID = "event_id", deviceSeq = "device_seq", termGeneration = "term_generation", observedAt = "observed_at"
        case kind, reading, text, layout, count
    }
    public init(eventID: UUID = UUID(), deviceSeq: UInt64, kind: CloudLearningAction, reading: String,
                text: String, layout: CloudLearningLayout, termGeneration: UInt64 = 0, observedAt: UInt64, count: Int? = nil) throws {
        self.eventID = eventID; self.deviceSeq = deviceSeq; self.kind = kind; self.reading = reading; self.text = text
        self.layout = layout; self.termGeneration = termGeneration; self.observedAt = observedAt; self.count = count
        try validate()
    }
    public func validate() throws {
        guard deviceSeq > 0, deviceSeq <= Int64.max, termGeneration <= Int64.max, observedAt <= Int64.max,
              !reading.isEmpty, reading.utf8.count <= 96,
              reading.range(of: "^[a-z]+(?:[ '][a-z]+)*\\z", options: .regularExpression) != nil,
              !text.isEmpty, text.unicodeScalars.count <= 32,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              count == nil || (kind == .confirm && (1...64).contains(count!)) else { throw CloudLearningError.invalid }
        // The service performs the shared 8105-character validation. This model
        // does not guess simplified Chinese from Unicode blocks.
    }
}

/// Read once at feature activation from the same packaged resource as core and
/// server. No table copy and no per-key file access. Cloud terms require Han.
public struct CloudLearningTextPolicy {
    private let characters: Set<Unicode.Scalar>
    public init(standardCharacters: Data) throws {
        let hash = SHA256.hash(data: standardCharacters).map { String(format: "%02x", $0) }.joined()
        guard hash == "668f69e856c357157720ab5a6f8644dca8a253b439772f92cd762b186a53b421",
              let text = String(data: standardCharacters, encoding: .utf8) else { throw CloudLearningError.invalid }
        let rows = text.split(separator: "\n")
        guard rows.count == 8105, rows.allSatisfy({ $0.unicodeScalars.count == 1 }) else { throw CloudLearningError.invalid }
        characters = Set(rows.compactMap { $0.unicodeScalars.first })
        guard characters.count == 8105 else { throw CloudLearningError.invalid }
    }
    public func allowsTerm(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        return (1...32).contains(scalars.count) && scalars.contains(where: characters.contains) && scalars.allSatisfy {
            characters.contains($0) || (" -'._".unicodeScalars.contains($0)) ||
                (48...57).contains($0.value) || (65...90).contains($0.value) || (97...122).contains($0.value)
        }
    }
}

public struct CloudLearningRequest: Codable {
    public let version: UInt8
    public let group, sender, nonce: UUID
    public let issuedAt: UInt64
    public let operation: UInt8
    public let body, signature: Data
    public func canonical() throws -> Data {
        guard version == 1, (1...7).contains(operation), body.count <= 524288 else { throw CloudLearningError.invalid }
        var bytes = Data("PrivateInput/cloud-learning-request/v1\0".utf8)
        bytes.append(version); bytes.appendUUID(group); bytes.appendUUID(sender); bytes.appendUUID(nonce)
        bytes.appendBE(issuedAt); bytes.append(operation); bytes.append(contentsOf: SHA256.hash(data: body)); return bytes
    }
    public static func sign(group: UUID, identity: DeviceIdentity, operation: UInt8, body: Data, now: UInt64) throws -> Self {
        let request = Self(version: 1, group: group, sender: identity.device, nonce: UUID(), issuedAt: now,
                           operation: operation, body: body, signature: Data())
        return Self(version: 1, group: group, sender: identity.device, nonce: request.nonce, issuedAt: now,
                    operation: operation, body: body, signature: try identity.signingKey.signature(for: request.canonical()))
    }
}
public protocol CloudLearningTransport { func send(_ request: CloudLearningRequest) async throws -> Data }
public struct CloudLearningHTTPTransport: CloudLearningTransport {
    public let endpoint: URL
    public init(endpoint: URL, allowLoopbackHTTP: Bool = false) throws {
        _ = try ActivityHTTPTransport(endpoint: endpoint, allowLoopbackHTTP: allowLoopbackHTTP); self.endpoint = endpoint
    }
    public func send(_ request: CloudLearningRequest) async throws -> Data {
        var url = endpoint; for part in ["v1", "learning", "rpc"] { url.appendPathComponent(part) }
        var http = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        http.httpMethod = "POST"; http.httpBody = try JSONEncoder().encode(request)
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (bytes, raw) = try await PrivateInputHTTPSessions.cloudLearning.bytes(for: http)
        guard let response = raw as? HTTPURLResponse else { throw CloudLearningError.invalid }
        guard response.expectedContentLength <= 4194304 else { throw CloudLearningError.oversized }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation(); guard data.count < 4194304 else { throw CloudLearningError.oversized }; data.append(byte)
        }
        if response.statusCode == 404 { throw CloudLearningError.unsupported }
        guard response.statusCode == 200 else {
            struct Failure: Decodable { let version: Int; let error: String }
            if let failure = try? JSONDecoder().decode(Failure.self, from: data), failure.version == 1,
               failure.error.utf8.count <= 96, failure.error.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }) {
                throw CloudLearningError.remote(failure.error)
            }
            throw CloudLearningError.http(response.statusCode)
        }
        return data
    }
}

public struct CloudLearningConsent: Codable {
    public let version: UInt64
    public let enabled: Bool
    public let installationID: UUID
    enum CodingKeys: String, CodingKey { case version, enabled, installationID = "installation_id" }
}
public struct CloudLearningStatus: Decodable {
    public let enabled: Bool
    public let policyVersion, generation, modelVersion: UInt64
    public let algorithmVersion: String
    public let consent: CloudLearningConsent?
    enum CodingKeys: String, CodingKey {
        case enabled, consent, generation, policyVersion = "policy_version", modelVersion = "model_version", algorithmVersion = "algorithm_version"
    }
}
public struct CloudLearningReceipt: Decodable {
    public struct Rejection: Decodable { public let eventID: UUID; public let reason: String
        enum CodingKeys: String, CodingKey { case eventID = "event_id", reason } }
    public let acceptedEventIDs: [UUID]
    public let rejectedEventIDs: [Rejection]?
    public let receivedDeviceSeq, generation, consentVersion: UInt64
    public let termGenerations: [CloudLearningTombstone]?
    enum CodingKeys: String, CodingKey {
        case acceptedEventIDs = "accepted_event_ids", rejectedEventIDs = "rejected_event_ids", receivedDeviceSeq = "received_device_seq"
        case generation, consentVersion = "consent_version", termGenerations = "term_generations"
    }
}
public struct CloudLearningTerm: Codable, Equatable {
    public let reading, text: String
    public let layout: CloudLearningLayout
    public let termGeneration: UInt64
    public let weight: Int
    public let pinned: Bool
    enum CodingKeys: String, CodingKey { case reading, text, layout, termGeneration = "term_generation", weight, pinned }
    public var id: String { layout.rawValue + "\u{001F}" + reading + "\u{001F}" + text }
}
public struct CloudLearningTombstone: Codable {
    public let reading, text: String
    public let layout: CloudLearningLayout
    public let termGeneration: UInt64
    enum CodingKeys: String, CodingKey { case reading, text, layout, termGeneration = "term_generation" }
    public var id: String { layout.rawValue + "\u{001F}" + reading + "\u{001F}" + text }
}
public struct CloudLearningWatermark: Codable, Equatable {
    public let deviceID, installationID: UUID
    public let consentVersion, deviceSeq: UInt64
    enum CodingKeys: String, CodingKey { case deviceID = "device_id", installationID = "installation_id", consentVersion = "consent_version", deviceSeq = "device_seq" }
}
public struct CloudLearningProducerWatermark: Codable, Equatable {
    public let producerID: UUID
    public let producerRevision: UInt64
    public let componentDigest: String
    enum CodingKeys: String, CodingKey { case producerID = "producer_id", producerRevision = "producer_revision", componentDigest = "component_digest" }
}
public struct CloudLearningDelta: Codable {
    public let generation, fromVersion, toVersion: UInt64
    public let algorithmVersion: String
    public let upserts: [CloudLearningTerm]
    public let tombstones: [CloudLearningTombstone]
    public let watermarks: [CloudLearningWatermark]
    public let producerWatermarks: [CloudLearningProducerWatermark]?
    public let modelSHA256: String
    public let hasMore: Bool
    enum CodingKeys: String, CodingKey {
        case generation, fromVersion = "from_version", toVersion = "to_version", algorithmVersion = "algorithm_version"
        case producerWatermarks = "producer_watermarks"
        case upserts, tombstones, watermarks, modelSHA256 = "model_sha256", hasMore = "has_more"
    }
}

private struct CloudLearningRPCResponse<T: Decodable>: Decodable {
    let version, operation: UInt8
    let result: T
}
public struct CloudLearningClient {
    public let transport: any CloudLearningTransport
    public init(transport: any CloudLearningTransport) { self.transport = transport }
    func rpc<T: Decodable, B: Encodable>(_ op: UInt8, _ body: B, group: UUID, identity: DeviceIdentity, now: UInt64) async throws -> T {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let request = try CloudLearningRequest.sign(group: group, identity: identity, operation: op, body: encoder.encode(body), now: now)
        let data = try await transport.send(request)
        guard data.count <= 4194304 else { throw CloudLearningError.oversized }
        let wrapper = try JSONDecoder().decode(CloudLearningRPCResponse<T>.self, from: data)
        guard wrapper.version == 1, wrapper.operation == op else { throw CloudLearningError.invalid }
        return wrapper.result
    }
    public func status(group: UUID, identity: DeviceIdentity, now: UInt64) async throws -> CloudLearningStatus {
        try await rpc(1, [String: Int](), group: group, identity: identity, now: now)
    }
    public func configureGroup(expectedVersion: UInt64, enabled: Bool, group: UUID, identity: DeviceIdentity, now: UInt64) async throws -> CloudLearningStatus {
        struct Body: Encodable { let expected_version: UInt64; let enabled: Bool }
        return try await rpc(2, Body(expected_version: expectedVersion, enabled: enabled), group: group, identity: identity, now: now)
    }
    public func configureDevice(expectedVersion: UInt64, enabled: Bool, installation: UUID, group: UUID, identity: DeviceIdentity, now: UInt64) async throws -> CloudLearningStatus {
        struct Body: Encodable { let expected_version: UInt64; let enabled: Bool; let installation_id: UUID }
        return try await rpc(3, Body(expected_version: expectedVersion, enabled: enabled, installation_id: installation), group: group, identity: identity, now: now)
    }
    public func ingest(_ events: [CloudLearningEvent], generation: UInt64, consentVersion: UInt64, installation: UUID,
                       policy: CloudLearningTextPolicy, group: UUID, identity: DeviceIdentity, now: UInt64) async throws -> CloudLearningReceipt {
        guard generation > 0, consentVersion > 0, (1...128).contains(events.count), Set(events.map(\.eventID)).count == events.count else { throw CloudLearningError.invalid }
        for event in events { try event.validate(); guard policy.allowsTerm(event.text) else { throw CloudLearningError.invalid } }
        struct Body: Encodable { let generation, consent_version: UInt64; let installation_id: UUID; let events: [CloudLearningEvent] }
        let receipt: CloudLearningReceipt = try await rpc(4, Body(generation: generation, consent_version: consentVersion, installation_id: installation, events: events), group: group, identity: identity, now: now)
        let acknowledged = receipt.acceptedEventIDs + (receipt.rejectedEventIDs ?? []).map(\.eventID)
        guard receipt.generation == generation, receipt.consentVersion == consentVersion,
              acknowledged.count == events.count, Set(acknowledged) == Set(events.map(\.eventID)),
              receipt.receivedDeviceSeq >= events.map(\.deviceSeq).max()! else { throw CloudLearningError.invalid }
        return receipt
    }
    public func pull(generation: UInt64, fromVersion: UInt64, group: UUID, identity: DeviceIdentity, now: UInt64) async throws -> CloudLearningDelta {
        struct Body: Encodable { let generation, from_version: UInt64; let limit: Int }
        let delta: CloudLearningDelta = try await rpc(5, Body(generation: generation, from_version: fromVersion, limit: 8), group: group, identity: identity, now: now)
        guard delta.generation == generation, delta.fromVersion == fromVersion, delta.toVersion >= fromVersion,
              ["bounded-confirmed-decay-v1", "shared-lexeme-decay-v2"].contains(delta.algorithmVersion), delta.upserts.count <= 5000, delta.tombstones.count <= 5000,
              delta.modelSHA256.utf8.count == 64 else { throw CloudLearningError.invalid }
        return delta
    }
}
