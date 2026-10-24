import Foundation

public protocol ActivityArchiveTransport {
    func send(_ request: SignedActivityRequest) async throws -> Data
}
/// No shared cookies/cache, redirects, certificate overrides, plaintext body logs or credentials in URLs.
public struct ActivityHTTPTransport: ActivityArchiveTransport {
    public let endpoint: URL
    public init(endpoint: URL, allowLoopbackHTTP: Bool = false) throws {
        guard let host = endpoint.host, !host.isEmpty, endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil else { throw ActivityError.invalidEndpoint }
        let loopback = ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased())
        guard endpoint.scheme == "https" || (allowLoopbackHTTP && endpoint.scheme == "http" && loopback) else { throw ActivityError.invalidEndpoint }
        self.endpoint = endpoint
    }
    public func send(_ request: SignedActivityRequest) async throws -> Data {
        var url = endpoint
        for part in ["v1", "activity", "rpc"] { url.appendPathComponent(part) }
        var http = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        http.httpMethod = "POST"; http.httpBody = try request.encoded()
        http.setValue("application/json", forHTTPHeaderField: "Content-Type"); http.setValue("application/json", forHTTPHeaderField: "Accept")
        let session = PrivateInputHTTPSessions.activity
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(for: http)
        guard let response = response as? HTTPURLResponse else { throw ActivityError.invalidResponse }
        let maximum = 2 * 1024 * 1024
        guard response.expectedContentLength <= Int64(maximum) else { throw ActivityError.responseTooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximum else { throw ActivityError.responseTooLarge }; data.append(byte)
        }
        guard response.statusCode == 200 else {
            // Only surface a bounded machine code, never an arbitrary server string/body.
            if let error = try? JSONDecoder().decode(ActivityRPCFailure.self, from: data), error.version == 1,
               error.error.utf8.count <= 96, error.error.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }) {
                throw ActivityError.remote(error.error)
            }
            throw ActivityError.httpStatus(response.statusCode)
        }
        return data
    }
}
private struct ActivityRPCFailure: Decodable { let version: Int; let error: String }
private struct ActivityRPCResponse<T: Decodable>: Decodable { let version: Int; let operation: ActivityOperation; let result: T }

public struct ActivityDeviceConsent: Codable, Equatable {
    public let version: UInt64
    public let enabled: Bool
    public let providers: [String]
    public let readers: [UUID]
}
public struct ActivityArchiveLimits: Decodable {
    public let maxBatchEvents: Int
    public let maxEventBytes: Int
    public let maxBodyBytes: Int
    public let retentionDays: Int
    public let maxGroupBytes: Int64
    enum CodingKeys: String, CodingKey {
        case maxBatchEvents = "max_batch_events", maxEventBytes = "max_event_bytes", maxBodyBytes = "max_body_bytes"
        case retentionDays = "retention_days", maxGroupBytes = "max_group_bytes"
    }
}
public struct ActivityServerStatus: Decodable {
    public let group: UUID
    public let device: UUID
    public let enabled: Bool
    public let policyVersion: UInt64
    public let membershipRevision: UInt64
    public let consent: ActivityDeviceConsent?
    public let limits: ActivityArchiveLimits
    enum CodingKeys: String, CodingKey { case group, device, enabled, policyVersion = "policy_version", membershipRevision = "membership_revision", consent, limits }
}
public struct ActivityGroupPolicy: Decodable {
    public let policyVersion: UInt64
    public let enabled: Bool
    public let retentionDays: Int
    public let maxGroupBytes: Int64
    enum CodingKeys: String, CodingKey { case policyVersion = "policy_version", enabled, retentionDays = "retention_days", maxGroupBytes = "max_group_bytes" }
}
public struct ActivityConsentResult: Decodable {
    public let consentVersion: UInt64
    public let consent: ActivityDeviceConsent
    enum CodingKeys: String, CodingKey { case consentVersion = "consent_version", consent }
}
public struct ActivityDelegateRegistration: Decodable {
    public let registered: Bool
    public let consentVersion: UInt64
    enum CodingKeys: String, CodingKey { case registered, consentVersion = "consent_version" }
}
public struct ActivityIngestReceipt: Decodable {
    public struct ReceivedRange: Decodable {
        public let installationID: UUID
        public let ranges: [[UInt64]]
        public let contiguousThrough: UInt64
        enum CodingKeys: String, CodingKey { case installationID = "installation_id", ranges, contiguousThrough = "contiguous_through" }
    }
    public let batchID: UUID
    public let acceptedEventIDs: [UUID]
    public let duplicateEventIDs: [UUID]
    public let receivedRanges: [ReceivedRange]
    public let serverReceivedAt: String
    public let highWatermark: UInt64
    enum CodingKeys: String, CodingKey {
        case batchID = "batch_id", acceptedEventIDs = "accepted_event_ids", duplicateEventIDs = "duplicate_event_ids"
        case receivedRanges = "received_ranges", serverReceivedAt = "server_received_at", highWatermark = "high_watermark"
    }
}
public struct ActivityArchiveClient {
    public let transport: any ActivityArchiveTransport
    public let endpoint: URL?
    public init(transport: any ActivityArchiveTransport) { self.transport = transport; endpoint = (transport as? ActivityHTTPTransport)?.endpoint }
    public init(endpoint: URL) throws { transport = try ActivityHTTPTransport(endpoint: endpoint); self.endpoint = endpoint }
    private func rpc<T: Decodable>(group: UUID, identity: DeviceIdentity, operation: ActivityOperation, body: Data, now: UInt64, result: T.Type) async throws -> T {
        try await rpc(group: group, signer: ActivityRequestSigner(identity: identity), operation: operation, body: body, now: now, result: result)
    }
    private func rpc<T: Decodable>(group: UUID, signer: ActivityRequestSigner, operation: ActivityOperation, body: Data, now: UInt64, result: T.Type) async throws -> T {
        let request = try SignedActivityRequest.sign(group: group, signer: signer, operation: operation, body: body, now: now)
        let data = try await transport.send(request)
        guard data.count <= 2 * 1024 * 1024 else { throw ActivityError.responseTooLarge }
        let response = try JSONDecoder().decode(ActivityRPCResponse<T>.self, from: data)
        guard response.version == 1, response.operation == operation else { throw ActivityError.invalidResponse }
        return response.result
    }
    public func status(group: UUID, identity: DeviceIdentity, now: UInt64) async throws -> ActivityServerStatus {
        try await status(group: group, signer: ActivityRequestSigner(identity: identity), now: now)
    }
    public func status(group: UUID, signer: ActivityRequestSigner, now: UInt64) async throws -> ActivityServerStatus {
        let value = try await rpc(group: group, signer: signer, operation: .status, body: Data("{}".utf8), now: now, result: ActivityServerStatus.self)
        guard value.group == group, value.device == signer.device else { throw ActivityError.invalidResponse }
        return value
    }
    /// Explicit user action only; observing remote status never grants local permission.
    public func setGroupPolicy(group: UUID, identity: DeviceIdentity, expectedVersion: UInt64, enabled: Bool,
                               retentionDays: Int = 30, maxGroupBytes: Int64 = 4294967296, now: UInt64) async throws -> ActivityGroupPolicy {
        struct Body: Encodable {
            let expected_version: UInt64; let enabled: Bool; let retention_days: Int; let max_group_bytes: Int64
        }
        guard (1...3650).contains(retentionDays), (1048576...4294967296).contains(maxGroupBytes) else { throw ActivityError.invalidConfiguration }
        let body = try JSONEncoder().encode(Body(expected_version: expectedVersion, enabled: enabled, retention_days: retentionDays, max_group_bytes: maxGroupBytes))
        return try await rpc(group: group, identity: identity, operation: .groupPolicy, body: body, now: now, result: ActivityGroupPolicy.self)
    }
    /// Readers are explicit. Membership alone never implies cross-device plaintext access.
    public func setDeviceConsent(group: UUID, identity: DeviceIdentity, expectedVersion: UInt64, enabled: Bool,
                                 providers: Set<String>, readers: Set<UUID>, now: UInt64) async throws -> ActivityConsentResult {
        struct Body: Encodable { let expected_version: UInt64; let enabled: Bool; let providers: [String]; let readers: [UUID] }
        guard !providers.isEmpty, providers.count <= 32, providers.allSatisfy(ActivityEvent.validProvider),
              !readers.isEmpty, readers.count <= 128 else { throw ActivityError.invalidConfiguration }
        let body = try JSONEncoder().encode(Body(expected_version: expectedVersion, enabled: enabled, providers: providers.sorted(), readers: readers.sorted { $0.uuidString < $1.uuidString }))
        let value = try await rpc(group: group, identity: identity, operation: .deviceConsent, body: body, now: now, result: ActivityConsentResult.self)
        guard value.consentVersion > expectedVersion, value.consentVersion == value.consent.version,
              value.consent.enabled == enabled, Set(value.consent.providers) == providers,
              Set(value.consent.readers) == readers else { throw ActivityError.invalidResponse }
        return value
    }
    public func registerDelegate(group: UUID, identity: DeviceIdentity, expectedConsentVersion: UInt64,
                                 publicKey: Data, now: UInt64) async throws -> ActivityDelegateRegistration {
        struct Body: Encodable { let expected_consent_version: UInt64; let public_key: Data }
        guard publicKey.count == 32, expectedConsentVersion > 0 else { throw ActivityError.invalidConfiguration }
        let body = try JSONEncoder().encode(Body(expected_consent_version: expectedConsentVersion, public_key: publicKey))
        let result = try await rpc(group: group, identity: identity, operation: .registerDelegate, body: body, now: now, result: ActivityDelegateRegistration.self)
        guard result.registered, result.consentVersion == expectedConsentVersion else { throw ActivityError.invalidResponse }
        return result
    }
    public func ingest(_ batch: ActivityBatch, group: UUID, identity: DeviceIdentity, now: UInt64) async throws -> ActivityIngestReceipt {
        try await ingest(batch, group: group, signer: ActivityRequestSigner(identity: identity), now: now)
    }
    public func ingest(_ batch: ActivityBatch, group: UUID, signer: ActivityRequestSigner, now: UInt64) async throws -> ActivityIngestReceipt {
        guard !batch.events.isEmpty, batch.events.count <= 128, batch.events.allSatisfy({ $0.deviceGroup == group && $0.deviceID == signer.device }) else { throw ActivityError.invalidEvent }
        let value = try await rpc(group: group, signer: signer, operation: .ingest, body: batch.encoded(), now: now, result: ActivityIngestReceipt.self)
        let allIDs = value.acceptedEventIDs + value.duplicateEventIDs
        guard value.batchID == batch.batchID, allIDs.count == Set(allIDs).count,
              Set(allIDs) == Set(batch.events.map(\.eventID)) else { throw ActivityError.invalidAcknowledgement }
        return value
    }
}

public struct ActivitySyncPassResult: Equatable {
    public let acknowledged: Int
    public let pending: Int
}
/// A short, bounded pass. Platform scheduling supplies lifetime and local trusted
/// membership revision; this worker never invents always-on iOS background execution.
public final class ActivityArchiveWorker {
    private let queue: ActivityLocalEventQueue
    private let client: ActivityArchiveClient
    private let stateLock = NSLock()
    private var running = false
    public init(queue: ActivityLocalEventQueue, client: ActivityArchiveClient) { self.queue = queue; self.client = client }
    public func flush(identity: DeviceIdentity, membershipRevision: UInt64, now: UInt64, maxBatches: Int = 4) async throws -> ActivitySyncPassResult {
        try await flush(signer: ActivityRequestSigner(identity: identity), membershipRevision: membershipRevision, now: now, maxBatches: maxBatches)
    }
    public func flush(signer: ActivityRequestSigner, membershipRevision: UInt64, now: UInt64, maxBatches: Int = 4) async throws -> ActivitySyncPassResult {
        guard begin() else { throw ActivityError.staleAuthorization }
        defer { end() }
        guard signer.device == queue.device else { throw ActivityError.invalidConfiguration }
        let lease = try queue.authorizationLease()
        if let endpoint = client.endpoint, endpoint != lease.configuration.endpoint { throw ActivityError.invalidEndpoint }
        if now > 86400 { try queue.pruneAcknowledged(before: now - 86400) }
        let status = try await fenced(lease) { try await self.client.status(group: self.queue.group, signer: signer, now: now) }
        guard status.enabled else { try queue.invalidateAuthorization(); throw ActivityError.serverDisabled }
        // A capture-only delegate never learns readers, group keys or management roles
        // from a newer server revision. Its fixed endpoint/group/device and unchanged
        // consent still authorize the same one-way plaintext write. Never accept rollback.
        guard signer.scope == .captureDelegate ? status.membershipRevision >= membershipRevision : status.membershipRevision == membershipRevision else { throw ActivityError.staleAuthorization }
        guard let consent = status.consent, consent.enabled, consent.version == lease.configuration.consentVersion,
              Set(consent.providers) == lease.configuration.providers else { try queue.invalidateAuthorization(); throw ActivityError.consentMismatch }
        var count = 0
        for _ in 0..<max(1, min(maxBatches, 16)) {
            try Task.checkCancellation(); try queue.validate(lease)
            guard let batch = try queue.nextBatch(lease: lease, now: now, limit: min(64, status.limits.maxBatchEvents)) else { break }
            do {
                let receipt = try await fenced(lease) { try await self.client.ingest(batch, group: self.queue.group, signer: signer, now: now) }
                try queue.acknowledge(batch, eventIDs: Set(receipt.acceptedEventIDs + receipt.duplicateEventIDs), lease: lease, now: now)
                count += batch.events.count
            } catch {
                try? queue.recordFailure(batch, lease: lease, now: now)
                throw error
            }
        }
        return ActivitySyncPassResult(acknowledged: count, pending: try queue.status().pending)
    }
    private func begin() -> Bool { stateLock.lock(); defer { stateLock.unlock() }; guard !running else { return false }; running = true; return true }
    private func end() { stateLock.lock(); running = false; stateLock.unlock() }
    private func fenced<T>(_ lease: ActivityAuthorizationLease, action: @escaping () async throws -> T) async throws -> T {
        try queue.validate(lease)
        // Cancellation cannot recall bytes the server has already durably received.
        // The device-consent endpoint blocks new server writes after remote revocation.
        // The persistent local fence detects another process pausing within 50ms and
        // cancels URLSession work; a returned response is rechecked before local ACK.
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try Task.checkCancellation(); try self.queue.validate(lease); return try await action() }
            group.addTask {
                while true { try await Task.sleep(nanoseconds: 50_000_000); try self.queue.validate(lease) }
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw ActivityError.invalidResponse }
            try queue.validate(lease); return value
        }
    }
}
