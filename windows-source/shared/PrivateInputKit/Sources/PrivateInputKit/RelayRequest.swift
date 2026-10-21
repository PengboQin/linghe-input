import Foundation
import CryptoKit

public enum RelayOperation: UInt8, Codable { case membership = 1, pull = 2, acknowledge = 3, keyPackage = 4, pendingPairs = 5, pairChallenge = 6, submitPair = 7, createTicket = 8, quickClaims = 9, cancelTicket = 10 }
public struct SignedRelayRequest: Codable {
    public var version: UInt8 = 1
    public var group: UUID
    public var sender: UUID
    public var nonce: UUID
    public var issuedAt: UInt64
    public var operation: RelayOperation
    public var body: Data
    public var signature: Data
    func canonical() throws -> Data {
        guard version == 1, body.count <= 65536 else { throw SyncSecurityError.invalidEnvelope }
        var bytes = Data("PrivateInput/relay-request/v1\0".utf8)
        bytes.append(version); bytes.appendUUID(group); bytes.appendUUID(sender); bytes.appendUUID(nonce)
        bytes.appendBE(issuedAt); bytes.append(operation.rawValue); bytes.append(Data(SHA256.hash(data: body)))
        return bytes
    }
    public static func sign(group: UUID, identity: DeviceIdentity, operation: RelayOperation, body: Data, now: UInt64) throws -> Self {
        try sign(group: group, sender: identity.device, signingKey: identity.signingKey, operation: operation, body: body, now: now)
    }
    public static func sign(group: UUID, sender: UUID, signingKey: Curve25519.Signing.PrivateKey,
                            operation: RelayOperation, body: Data, now: UInt64) throws -> Self {
        var request = Self(group: group, sender: sender, nonce: UUID(), issuedAt: now,
                           operation: operation, body: body, signature: Data())
        request.signature = Data(try signingKey.signature(for: request.canonical())); return request
    }
    public func encoded() throws -> Data { _ = try canonical(); return try JSONEncoder().encode(self) }
}
