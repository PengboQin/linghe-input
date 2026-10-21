import Foundation
import CryptoKit

public enum MembershipError: Error { case malformed, wrongOwner, invalidSignature, rollback, equivocation, notMember }

public struct DevicePermissions: OptionSet, Codable, Equatable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let learning = Self(rawValue: 1)
    public static let clipboard = Self(rawValue: 2)
    public static let all: Self = [.learning, .clipboard]
}
public struct GroupMember: Codable, Equatable {
    public let device: UUID
    public let signingPublic: Data
    public let exchangePublic: Data
    public let permissions: DevicePermissions
    public init(device: UUID, signingPublic: Data, exchangePublic: Data, permissions: DevicePermissions = .all) {
        self.device = device; self.signingPublic = signingPublic; self.exchangePublic = exchangePublic; self.permissions = permissions
    }
    public init(identity: DeviceIdentity, permissions: DevicePermissions = .all) {
        self.init(device: identity.device, signingPublic: identity.signingKey.publicKey.rawRepresentation,
                  exchangePublic: identity.exchangeKey.publicKey.rawRepresentation, permissions: permissions)
    }
}
public struct SignedMembership: Codable {
    public var version: UInt8 = 1
    public var group: UUID
    public var ownerID: UUID
    public var ownerPublic: Data
    public var revision: UInt64
    public var epoch: UInt64
    public var members: [GroupMember]
    public var signature: Data
    func canonical() throws -> Data {
        guard version == 1, revision > 0, epoch == revision, ownerPublic.count == 32,
              !members.isEmpty, members.count <= 64, Set(members.map(\.device)).count == members.count,
              Set(members.map(\.signingPublic)).count == members.count,
              Set(members.map(\.exchangePublic)).count == members.count else { throw MembershipError.malformed }
        var bytes = Data("PrivateInput/membership/v1\0".utf8)
        bytes.append(version); bytes.appendUUID(group); bytes.appendUUID(ownerID); bytes.append(ownerPublic)
        bytes.appendBE(revision); bytes.appendBE(epoch); bytes.append(UInt8(members.count))
        for member in members.sorted(by: { $0.device.uuidString < $1.device.uuidString }) {
            guard member.signingPublic.count == 32, member.exchangePublic.count == 32,
                  member.permissions.rawValue > 0, member.permissions.rawValue <= 3 else { throw MembershipError.malformed }
            bytes.appendUUID(member.device); bytes.append(member.signingPublic); bytes.append(member.exchangePublic); bytes.append(member.permissions.rawValue)
        }
        return bytes
    }
    public func encoded() throws -> Data {
        _ = try canonical(); let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(self)
    }
    public static func sign(group: UUID, ownerID: UUID, ownerKey: Curve25519.Signing.PrivateKey,
                            revision: UInt64, members: [GroupMember]) throws -> Self {
        var value = Self(group: group, ownerID: ownerID, ownerPublic: ownerKey.publicKey.rawRepresentation,
                         revision: revision, epoch: revision, members: members, signature: Data())
        value.signature = Data(try ownerKey.signature(for: value.canonical())); return value
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 32768 else { throw MembershipError.malformed }
        let value = try JSONDecoder().decode(Self.self, from: data); _ = try value.canonical(); return value
    }
}
public struct MembershipAnchor: Codable, Equatable {
    public let group: UUID
    public let ownerID: UUID
    public let ownerPublic: Data
    public init(group: UUID, ownerID: UUID, ownerPublic: Data) {
        self.group = group; self.ownerID = ownerID; self.ownerPublic = ownerPublic
    }
    public func verify(_ statement: SignedMembership, replacing old: VerifiedMembership? = nil) throws -> VerifiedMembership {
        guard statement.group == group, statement.ownerID == ownerID, statement.ownerPublic == ownerPublic,
              ownerPublic.count == 32 else { throw MembershipError.wrongOwner }
        let bytes = try statement.canonical()
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: ownerPublic)
        guard statement.signature.count == 64, key.isValidSignature(statement.signature, for: bytes) else { throw MembershipError.invalidSignature }
        if let old {
            guard old.anchor == self, statement.revision >= old.statement.revision else { throw MembershipError.rollback }
            if statement.revision == old.statement.revision, bytes != old.canonicalBytes { throw MembershipError.equivocation }
        }
        return VerifiedMembership(anchor: self, statement: statement, canonicalBytes: bytes)
    }
}
public struct VerifiedMembership {
    public let anchor: MembershipAnchor
    public let statement: SignedMembership
    let canonicalBytes: Data
    public var digest: Data { Data(SHA256.hash(data: canonicalBytes)) }
    public func member(_ device: UUID) throws -> GroupMember {
        guard let member = statement.members.first(where: { $0.device == device }) else { throw MembershipError.notMember }
        return member
    }
    public func trust(for domain: SyncDomain) -> SyncTrust {
        let required: DevicePermissions = domain == .learning ? .learning : .clipboard
        return SyncTrust(group: statement.group, epoch: statement.epoch,
                         members: Dictionary(uniqueKeysWithValues: statement.members.filter { $0.permissions.contains(required) }.map { ($0.device, $0.signingPublic) }))
    }
}
