import Foundation

public enum RelayClientError: Error { case invalidEndpoint, responseTooLarge, invalidResponse, httpStatus(Int), rotationRequired }
private final class DenyRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Transport lives in the containing app/sync agent. No cookies, body logs,
/// persistent cache, certificate overrides or silent redirects to another host.
public struct RelayClient: RelaySyncTransport {
    public let endpoint: URL
    public init(endpoint: URL, allowLoopbackHTTP: Bool = false) throws {
        guard let host = endpoint.host, !host.isEmpty, endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil else { throw RelayClientError.invalidEndpoint }
        let loopback = ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased())
        guard endpoint.scheme == "https" || (allowLoopbackHTTP && endpoint.scheme == "http" && loopback) else { throw RelayClientError.invalidEndpoint }
        self.endpoint = endpoint
    }
    private func request(_ method: String, path: [String], body: Data, maximum: Int = 8 * 1024 * 1024) async throws -> Data {
        var url = endpoint
        for segment in path { url.appendPathComponent(segment) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = method; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil; configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: DenyRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw RelayClientError.invalidResponse }
        guard http.statusCode == 200 else { throw RelayClientError.httpStatus(http.statusCode) }
        guard response.expectedContentLength <= Int64(maximum) else { throw RelayClientError.responseTooLarge }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximum else { throw RelayClientError.responseTooLarge }
            data.append(byte)
        }
        return data
    }
    private struct Acceptance: Decodable { let accepted: Bool; var event: UUID? }
    private func accepted(_ data: Data, event: UUID? = nil) throws {
        let result = try JSONDecoder().decode(Acceptance.self, from: data)
        guard result.accepted, event == nil || result.event == event else { throw RelayClientError.invalidResponse }
    }
    public func register(_ initial: VerifiedMembership) async throws {
        try accepted(await request("POST", path: ["v1", "groups"], body: initial.statement.encoded()))
    }
    public func publishMembership(_ membership: VerifiedMembership) async throws {
        try accepted(await request("PUT", path: ["v1", "groups", membership.anchor.group.uuidString, "membership"], body: membership.statement.encoded()))
    }
    public func push(_ wire: Data) async throws {
        let message = try SecureEnvelope.decode(wire)
        try accepted(await request("POST", path: ["v1", "groups", message.group.uuidString, "events"], body: wire), event: message.event)
    }
    public func publishKey(_ package: WrappedGroupKey) async throws {
        try accepted(await request("POST", path: ["v1", "groups", package.membership.group.uuidString, "keys"], body: package.encoded()))
    }
    public func submitPair(_ pair: PairRequest, group: UUID, identity: DeviceIdentity, now: UInt64) async throws {
        try accepted(await rpc(group: group, identity: identity, operation: .submitPair, body: pair.encoded(), now: now))
    }
    public func pendingPairs(group: UUID, owner: DeviceIdentity, now: UInt64) async throws -> [PairRequest] {
        struct Response: Decodable { let requests: [PairRequest] }
        let request = try SignedRelayRequest.sign(group: group, sender: owner.ownerID, signingKey: owner.ownerSigningKey, operation: .pendingPairs, body: Data(), now: now)
        let data = try await self.request("POST", path: ["v1", "groups", group.uuidString, "rpc"], body: request.encoded())
        let values = try JSONDecoder().decode(Response.self, from: data).requests
        guard values.count <= 8 else { throw RelayClientError.invalidResponse }
        for value in values { try value.validate(now: now) }
        return values
    }
    public func publishChallenge(_ challenge: PairingChallenge, session: UUID) async throws {
        struct Body: Encodable { let session: UUID; let challenge: PairingChallenge }
        try accepted(await request("POST", path: ["v1", "groups", challenge.anchor.group.uuidString, "pair-challenge"], body: JSONEncoder().encode(Body(session: session, challenge: challenge))))
    }
    public func pairChallenge(group: UUID, session: UUID, identity: DeviceIdentity, now: UInt64) async throws -> PairingChallenge {
        struct Body: Encodable { let session: UUID }
        struct Response: Decodable { let challenge: PairingChallenge }
        let data = try await rpc(group: group, identity: identity, operation: .pairChallenge, body: JSONEncoder().encode(Body(session: session)), now: now)
        let value = try JSONDecoder().decode(Response.self, from: data).challenge
        return try PairingChallenge.decode(value.encoded())
    }
    public func createTicket(invitation:DeviceInvitation,ticket:UUID,secretHash:Data,expiresAt:UInt64,identity:DeviceIdentity,now:UInt64) async throws -> QuickPairTicket {
        struct Body:Encodable { let ticket:UUID;let secretHash:Data;let invitation:DeviceInvitation;let expiresAt:UInt64 }
        let body=try JSONEncoder().encode(Body(ticket:ticket,secretHash:secretHash,invitation:invitation,expiresAt:expiresAt))
        let response=try await rpc(group:invitation.anchor.group,identity:identity,operation:.createTicket,body:body,now:now)
        let result=try JSONDecoder().decode(QuickPairTicket.self,from:response)
        guard result.ticket==ticket,result.expiresAt>now,result.expiresAt<=expiresAt,result.code.count==6,result.code.utf8.allSatisfy({$0>=48 && $0<=57}) else { throw RelayClientError.invalidResponse }
        return result
    }
    public func cancelTicket(_ ticket:UUID,group:UUID,identity:DeviceIdentity,now:UInt64) async throws {
        struct Body:Encodable { let ticket:UUID }
        try accepted(await rpc(group:group,identity:identity,operation:.cancelTicket,body:JSONEncoder().encode(Body(ticket:ticket)),now:now))
    }
    public func quickClaims(group:UUID,owner:DeviceIdentity,now:UInt64) async throws -> [QuickPairClaim] {
        struct Response:Decodable { let claims:[QuickPairClaim] }
        let signed=try SignedRelayRequest.sign(group:group,sender:owner.ownerID,signingKey:owner.ownerSigningKey,operation:.quickClaims,body:Data(),now:now)
        let data=try await request("POST",path:["v1","groups",group.uuidString,"rpc"],body:signed.encoded())
        let values=try JSONDecoder().decode(Response.self,from:data).claims
        guard values.count<=64 else { throw RelayClientError.invalidResponse }
        for value in values { try value.request.validate(now:now);guard value.expiresAt>now else { throw PairingError.expired } }
        return values
    }
    public func claimTicket(code:String,request pair:PairRequest) async throws -> DeviceInvitation {
        struct Body:Encodable {let code:String;let request:PairRequest}
        return try await claimTicketBody(JSONEncoder().encode(Body(code:code,request:pair)))
    }
    public func claimTicket(qr:QuickPairQR,request pair:PairRequest) async throws -> DeviceInvitation {
        struct Body:Encodable {let ticket:UUID;let secret:Data;let request:PairRequest}
        return try await claimTicketBody(JSONEncoder().encode(Body(ticket:qr.ticket,secret:qr.secret,request:pair)))
    }
    private func claimTicketBody(_ body:Data) async throws -> DeviceInvitation {
        struct Response:Decodable {let invitation:DeviceInvitation}
        let data=try await request("POST",path:["v1","pairing","claim"],body:body,maximum:8192)
        let invitation=try JSONDecoder().decode(Response.self,from:data).invitation
        guard invitation.endpoint==endpoint else { throw RelayClientError.invalidResponse }
        _ = try invitation.link(allowLoopbackHTTP:true)
        return invitation
    }
    private func rpc(group: UUID, identity: DeviceIdentity, operation: RelayOperation, body: Data, now: UInt64) async throws -> Data {
        let signed = try SignedRelayRequest.sign(group: group, identity: identity, operation: operation, body: body, now: now)
        return try await request("POST", path: ["v1", "groups", group.uuidString, "rpc"], body: signed.encoded())
    }
    public func membership(group: UUID, identity: DeviceIdentity, now: UInt64) async throws -> SignedMembership {
        struct Response: Decodable { let membership: SignedMembership }
        let data = try await rpc(group: group, identity: identity, operation: .membership, body: Data(), now: now)
        let value = try JSONDecoder().decode(Response.self, from: data).membership
        return try SignedMembership.decode(value.encoded())
    }
    public func keyPackage(group: UUID, identity: DeviceIdentity, now: UInt64) async throws -> WrappedGroupKey {
        struct Response: Decodable { let package: WrappedGroupKey }
        let data = try await rpc(group: group, identity: identity, operation: .keyPackage, body: Data(), now: now)
        let value = try JSONDecoder().decode(Response.self, from: data).package
        return try WrappedGroupKey.decode(value.encoded())
    }
    public func pull(group: UUID, identity: DeviceIdentity, now: UInt64, domains: UInt8 = 3) async throws -> [Data] {
        struct Response: Decodable { let events: [SecureEnvelope] }
        guard domains > 0, domains <= 3 else { throw ReplicaStoreError.sharingDisabled }
        let data = try await rpc(group: group, identity: identity, operation: .pull, body: Data(("{\"limit\":2,\"domains\":" + String(domains) + "}").utf8), now: now)
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.events.count <= 2 else { throw RelayClientError.invalidResponse }
        return try response.events.map { let wire = try $0.encoded(); _ = try SecureEnvelope.decode(wire); return wire }
    }
    public func acknowledge(group: UUID, identity: DeviceIdentity, events: [UUID], now: UInt64) async throws {
        struct Body: Encodable { let events: [UUID] }
        guard events.count <= 100 else { throw RelayClientError.invalidResponse }
        try accepted(await rpc(group: group, identity: identity, operation: .acknowledge, body: JSONEncoder().encode(Body(events: events)), now: now))
    }
}

public struct SyncConsent: Equatable {
    public let learning: Bool
    public let clipboard: Bool
    public init(learning: Bool, clipboard: Bool) { self.learning = learning; self.clipboard = clipboard }
    public func allows(_ domain: SyncDomain) -> Bool { domain == .learning ? learning : clipboard }
}
public struct SyncPassResult { public let submitted: Int; public let received: Int }
public protocol RelaySyncTransport {
    func membership(group: UUID, identity: DeviceIdentity, now: UInt64) async throws -> SignedMembership
    func keyPackage(group: UUID, identity: DeviceIdentity, now: UInt64) async throws -> WrappedGroupKey
    func push(_ wire: Data) async throws
    func pull(group: UUID, identity: DeviceIdentity, now: UInt64, domains: UInt8) async throws -> [Data]
    func acknowledge(group: UUID, identity: DeviceIdentity, events: [UUID], now: UInt64) async throws
}
public enum RelaySyncPass {
    /// All network awaits run outside the input callback; state and ledger are
    /// committed before receiver ack. A failed pass retains unacked wire data.
    public static func run(group: UUID, store: SecureReplicaStore, vault: DeviceIdentityVault, client: any RelaySyncTransport,
                           consent: SyncConsent, now: UInt64, authorization: SyncConsentGate? = nil,
                           authorizationLease: SyncConsentGate.Lease? = nil) async throws -> SyncPassResult {
        guard consent.learning || consent.clipboard else { throw ReplicaStoreError.sharingDisabled }
        let gate = authorization ?? SyncConsentGate(consent), lease = authorizationLease ?? gate.lease()
        func permitted<T>(_ action: () throws -> T) throws -> T {
            try gate.withLease(lease) { current in
                guard current == consent else { throw ReplicaStoreError.sharingDisabled }
                return try action()
            }
        }
        try permitted {}
        let identity = try vault.load(); var local = try store.group(group)
        let remote = try await client.membership(group: group, identity: identity, now: now)
        let verified = try permitted { try local.membership.anchor.verify(remote, replacing: local.membership) }
        if verified.digest != local.membership.digest {
            let package = try await client.keyPackage(group: group, identity: identity, now: now)
            try permitted {
                let supplied = try local.membership.anchor.verify(package.membership, replacing: local.membership)
                guard supplied.digest == verified.digest else { throw RelayClientError.rotationRequired }
                try store.applyRotation(package, now: now); local = try store.group(group)
                if consent.learning, try local.membership.member(identity.device).permissions.contains(.learning) {
                    _ = try store.enqueue(store.learningArchive(group: group), domain: .learning, group: group, sharingEnabled: true, now: now)
                }
            }
        }
        var submitted = 0, received = 0
        let domains: [SyncDomain] = [.learning, .clipboard].filter { consent.allows($0) }
        for wire in try permitted({ try store.pendingMessages(group: group, domains: domains, now: now) }) {
            let message = try SecureEnvelope.decode(wire)
            guard message.group == group, consent.allows(message.domain) else { continue }
            try permitted {}
            try await client.push(wire)
            try permitted { try store.acknowledgeSent(message.event); submitted += 1 }
        }
        let mask: UInt8 = (consent.learning ? 1 : 0) | (consent.clipboard ? 2 : 0)
        try permitted {}
        for wire in try await client.pull(group: group, identity: identity, now: now, domains: mask) {
            let message = try SecureEnvelope.decode(wire)
            guard consent.allows(message.domain) else { continue }
            try permitted {
                let result = try store.receive(wire, now: now, receivingEnabled: true)
                if result == .applied { received += 1 }
            }
            try permitted {}
            try await client.acknowledge(group: group, identity: identity, events: [message.event], now: now)
        }
        try permitted {}
        return SyncPassResult(submitted: submitted, received: received)
    }
}
