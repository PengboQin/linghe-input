import Foundation
import CryptoKit

public enum RecentLearningSyncError: Error { case invalidWire, unsupported, notReady, wrongContext, invalidTime, httpStatus(Int), oversized }
public struct SignedRecencyRequest: Codable {
    public var version: UInt8 = 1
    public let group: UUID
    public let sender: UUID
    public let nonce: UUID
    public let issuedAt: UInt64
    public let operation: UInt8
    public let body: Data
    public var signature: Data
    public func canonical() throws -> Data {
        guard version == 1, (1...3).contains(operation), body.count <= 3 * 1024 * 1024 else { throw RecentLearningSyncError.invalidWire }
        var value = Data("PrivateInput/recency-request/v1\0".utf8)
        value.append(version); value.appendUUID(group); value.appendUUID(sender); value.appendUUID(nonce)
        value.appendBE(issuedAt); value.append(operation); value.append(contentsOf: SHA256.hash(data: body)); return value
    }
    public static func sign(group: UUID, identity: DeviceIdentity, operation: UInt8, body: Data, now: UInt64) throws -> Self {
        var request = Self(group: group, sender: identity.device, nonce: UUID(), issuedAt: now, operation: operation, body: body, signature: Data())
        request.signature = try identity.signingKey.signature(for: request.canonical()); return request
    }
    public func encoded() throws -> Data { _ = try canonical(); return try JSONEncoder().encode(self) }
}

public struct RecentLearningEnvelope: Codable {
    public var version: UInt8 = 1
    public let group: UUID
    public let sender: UUID
    public let event: UUID
    public let epoch: UInt64
    public let issuedAt: UInt64
    public let expiresAt: UInt64
    public var sealed: Data
    public var signature: Data
    public func header() throws -> Data {
        guard version == 1, epoch > 0, expiresAt > issuedAt, expiresAt - issuedAt <= 604800,
              sealed.count <= RecentLearningModel.byteLimit + 28 else { throw RecentLearningSyncError.invalidWire }
        var data = Data("PrivateInput/recent-learning-envelope/v1\0".utf8)
        data.append(version); data.appendUUID(group); data.appendUUID(sender); data.appendUUID(event)
        data.appendBE(epoch); data.appendBE(issuedAt); data.appendBE(expiresAt); return data
    }
    private func key(master: SymmetricKey, publicKey: Data) throws -> SymmetricKey {
        guard master.bitCount == 256, publicKey.count == 32 else { throw RecentLearningSyncError.invalidWire }
        var salt = Data(); salt.appendUUID(group); salt.appendBE(epoch)
        var info = Data("PrivateInput/recent-learning-key/v1\0".utf8); info.appendUUID(sender); info.append(publicKey)
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: salt, info: info, outputByteCount: 32)
    }
    public static func seal(_ payload: Data, group: GroupSetup, identity: DeviceIdentity, now: UInt64,
                            policy: RecentLearningPolicy) throws -> Self {
        guard now <= UInt64.max - 604800 else { throw RecentLearningSyncError.invalidTime }
        let trust = group.membership.trust(for: .learning)
        guard trust.members[identity.device] == identity.signingKey.publicKey.rawRepresentation else { throw RecentLearningSyncError.wrongContext }
        var check = RecentLearningModel(); try check.merge(payload, policy: policy)
        var message = Self(group: trust.group, sender: identity.device, event: UUID(), epoch: trust.epoch,
                           issuedAt: now, expiresAt: now + 604800, sealed: Data(), signature: Data())
        let header = try message.header(), key = try message.key(master: group.key, publicKey: identity.signingKey.publicKey.rawRepresentation)
        message.sealed = try ChaChaPoly.seal(payload, using: key, authenticating: header).combined
        message.signature = try identity.signingKey.signature(for: header + message.sealed)
        return message
    }
    public func open(group setup: GroupSetup, now: UInt64, policy: RecentLearningPolicy) throws -> Data {
        let trust = setup.membership.trust(for: .learning), header = try self.header()
        guard group == trust.group, epoch == trust.epoch, let publicKey = trust.members[sender] else { throw RecentLearningSyncError.wrongContext }
        guard expiresAt > now, issuedAt <= now || issuedAt - now <= 300 else { throw RecentLearningSyncError.invalidTime }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        guard signature.count == 64, sealed.count >= 28, key.isValidSignature(signature, for: header + sealed) else { throw RecentLearningSyncError.invalidWire }
        let payload = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: sealed), using: self.key(master: setup.key, publicKey: publicKey), authenticating: header)
        var check = RecentLearningModel(); try check.merge(payload, policy: policy); return payload
    }
}

public struct RecentLearningServerStatus: Codable {
    public let version: Int
    public let group: UUID
    public let sender: UUID
    public let nonce: UUID
    public let epoch: UInt64
    public let membershipRevision: UInt64
    public let serverTime: UInt64
    public let referenceDay: Int
    public let ready: Bool
    public let missing: [UUID]
    public let publishedEvent: String
    public let accepted: Bool?
    public let event: UUID?
    public let envelope: RecentLearningEnvelope?
    public let next: String?
    public func validate(request: SignedRecencyRequest, setup: GroupSetup) throws {
        guard version == 1, group == request.group, sender == request.sender, nonce == request.nonce,
              group == setup.membership.statement.group, epoch == setup.membership.statement.epoch,
              membershipRevision == setup.membership.statement.revision, missing.count <= 64,
              Set(missing).count == missing.count, ready == missing.isEmpty else { throw RecentLearningSyncError.wrongContext }
        guard publishedEvent.isEmpty || UUID(uuidString: publishedEvent) != nil else { throw RecentLearningSyncError.invalidWire }
        guard serverTime / 86400 <= 3_000_000, referenceDay == Int(serverTime / 86400), referenceDay >= 90,
              serverTime >= request.issuedAt ? serverTime - request.issuedAt < 300 : request.issuedAt - serverTime < 300 else { throw RecentLearningSyncError.invalidTime }
        if request.operation == 2 { guard accepted == true, event != nil else { throw RecentLearningSyncError.invalidWire } }
        if request.operation == 1 {
            guard (envelope == nil) == publishedEvent.isEmpty else { throw RecentLearningSyncError.invalidWire }
            if let envelope { guard envelope.sender == sender, envelope.event.uuidString == publishedEvent else { throw RecentLearningSyncError.invalidWire } }
        }
        if request.operation == 3 {
            guard let next, next.isEmpty || UUID(uuidString: next) != nil else { throw RecentLearningSyncError.invalidWire }
            guard (envelope == nil) == next.isEmpty else { throw RecentLearningSyncError.invalidWire }
            if let envelope { guard envelope.sender.uuidString == next, envelope.sender != sender else { throw RecentLearningSyncError.invalidWire } }
        }
    }
    public var policy: RecentLearningPolicy { get throws { try .init(referenceDay: referenceDay) } }
}
public struct TimedRecentLearningStatus {
    public let status: RecentLearningServerStatus
    /// Server time sampled before this instant, never extrapolated from a peer.
    public let responseUptime: Double
}

public protocol RecentLearningTransport { func send(_ request: SignedRecencyRequest) async throws -> Data }
private final class RecencyDenyRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
public struct RecentLearningHTTPTransport: RecentLearningTransport {
    public let endpoint: URL
    public init(endpoint: URL, allowLoopbackHTTP: Bool = false) throws {
        _ = try RelayClient(endpoint: endpoint, allowLoopbackHTTP: allowLoopbackHTTP); self.endpoint = endpoint
    }
    public func send(_ request: SignedRecencyRequest) async throws -> Data {
        var url = endpoint
        for part in ["v1", "groups", request.group.uuidString, "recency"] { url.appendPathComponent(part) }
        var http = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 10)
        http.httpMethod = "POST"; http.httpBody = try request.encoded(); http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
        config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config, delegate: RecencyDenyRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, raw) = try await session.bytes(for: http)
        guard let response = raw as? HTTPURLResponse else { throw RecentLearningSyncError.invalidWire }
        if response.statusCode == 404 { throw RecentLearningSyncError.unsupported }
        guard response.statusCode == 200 else { throw RecentLearningSyncError.httpStatus(response.statusCode) }
        guard response.expectedContentLength <= 4 * 1024 * 1024 else { throw RecentLearningSyncError.oversized }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 4 * 1024 * 1024 else { throw RecentLearningSyncError.oversized }; data.append(byte)
        }
        return data
    }
}

public struct RecentLearningClient {
    public let transport: any RecentLearningTransport
    public init(transport: any RecentLearningTransport) { self.transport = transport }
    private func rpc(operation: UInt8, body: Data, setup: GroupSetup, identity: DeviceIdentity, now: UInt64) async throws -> TimedRecentLearningStatus {
        let request = try SignedRecencyRequest.sign(group: setup.membership.statement.group, identity: identity, operation: operation, body: body, now: now)
        let began = ProcessInfo.processInfo.systemUptime
        let data = try await transport.send(request), ended = ProcessInfo.processInfo.systemUptime
        guard ended >= began, ended - began <= 10 else { throw RecentLearningSyncError.invalidTime }
        guard data.count <= 4 * 1024 * 1024 else { throw RecentLearningSyncError.oversized }
        let result = try JSONDecoder().decode(RecentLearningServerStatus.self, from: data)
        try result.validate(request: request, setup: setup)
        return .init(status: result, responseUptime: ended)
    }
    public func hello(setup: GroupSetup, identity: DeviceIdentity, roles: [String], now: UInt64) async throws -> TimedRecentLearningStatus {
        guard !roles.isEmpty, roles.count <= 4, Set(roles).count == roles.count,
              roles.allSatisfy({ ["app","keyboard","desktop","ime"].contains($0) }), roles.contains("keyboard") || roles.contains("ime") else { throw RecentLearningSyncError.invalidWire }
        struct Body: Encodable { let epoch: UInt64; let membershipRevision: UInt64; let roles: [String] }
        return try await rpc(operation: 1, body: JSONEncoder().encode(Body(epoch: setup.membership.statement.epoch, membershipRevision: setup.membership.statement.revision, roles: roles)), setup: setup, identity: identity, now: now)
    }
    public func push(_ envelope: RecentLearningEnvelope, expectedEvent: String, setup: GroupSetup, identity: DeviceIdentity, now: UInt64) async throws -> TimedRecentLearningStatus {
        struct Body: Encodable { let epoch: UInt64; let membershipRevision: UInt64; let envelope: RecentLearningEnvelope; let expectedEvent: String }
        guard envelope.group == setup.membership.statement.group, envelope.sender == identity.device else { throw RecentLearningSyncError.wrongContext }
        guard expectedEvent.isEmpty || UUID(uuidString: expectedEvent) != nil else { throw RecentLearningSyncError.invalidWire }
        let result = try await rpc(operation: 2, body: JSONEncoder().encode(Body(epoch: setup.membership.statement.epoch, membershipRevision: setup.membership.statement.revision, envelope: envelope, expectedEvent: expectedEvent)), setup: setup, identity: identity, now: now)
        guard result.status.event == envelope.event, result.status.publishedEvent == envelope.event.uuidString else { throw RecentLearningSyncError.invalidWire }; return result
    }
    public func pull(after: String, setup: GroupSetup, identity: DeviceIdentity, now: UInt64) async throws -> TimedRecentLearningStatus {
        struct Body: Encodable { let epoch: UInt64; let membershipRevision: UInt64; let after: String }
        guard after.isEmpty || UUID(uuidString: after) != nil else { throw RecentLearningSyncError.invalidWire }
        let result = try await rpc(operation: 3, body: JSONEncoder().encode(Body(epoch: setup.membership.statement.epoch, membershipRevision: setup.membership.statement.revision, after: after)), setup: setup, identity: identity, now: now)
        if let next = result.status.next, !next.isEmpty { guard next > after else { throw RecentLearningSyncError.invalidWire } }
        return result
    }
}
