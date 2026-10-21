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
    // Flat public predecessor proof: no private keys and no nested histories.
    public var issuer: UUID? = nil
    public var parent: Data? = nil
    public var history: [SignedMembership]? = nil
    func canonical() throws -> Data {
        guard (version == 1 || version == 2), revision > 0, epoch == revision, ownerPublic.count == 32,
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
        if version == 2 {
            guard let issuer, let parent, parent.count == 32 else { throw MembershipError.malformed }
            bytes.appendUUID(issuer); bytes.append(parent)
        } else if issuer != nil || parent != nil || history != nil { throw MembershipError.malformed }
        return bytes
    }
    public func authorizationPublic() throws -> Data {
        if version == 1 { return ownerPublic }
        guard let previous=history?.last, let issuer,
              let member=previous.members.first(where:{$0.device==issuer}),member.permissions == .all else { throw MembershipError.notMember }
        return member.signingPublic
    }
    public static func successor(of current: VerifiedMembership, members:[GroupMember], signer:DeviceIdentity) throws -> Self {
        let member=try current.member(signer.device)
        guard member.permissions == .all,member.signingPublic == signer.signingKey.publicKey.rawRepresentation,
              current.statement.revision < UInt64.max else {throw MembershipError.notMember}
        var predecessor=current.statement; predecessor.history=nil
        let proof=(current.statement.history ?? [])+[predecessor]
        guard proof.count<=1024 else {throw MembershipError.malformed}
        var next=Self(version:2,group:current.anchor.group,ownerID:current.anchor.ownerID,ownerPublic:current.anchor.ownerPublic,
                      revision:current.statement.revision+1,epoch:current.statement.epoch+1,members:members,signature:Data(),
                      issuer:signer.device,parent:current.digest,history:proof)
        next.signature=try signer.signingKey.signature(for:next.canonical()); _ = try current.anchor.verify(next,replacing:current)
        return next
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
        guard data.count <= 2 * 1024 * 1024 else { throw MembershipError.malformed }
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
        let proof=statement.history ?? []
        guard proof.count<=1024, proof.allSatisfy({$0.history == nil}),
              statement.version == 1 ? proof.isEmpty : !proof.isEmpty else {throw MembershipError.malformed}
        var previous:SignedMembership?;var previousBytes:Data?
        var retainedDigest:Data? = nil
        for item in proof+[statement] {
            guard item.group==group,item.ownerID==ownerID,item.ownerPublic==ownerPublic else {throw MembershipError.wrongOwner}
            let canonical=try item.canonical(),publicKey:Data
            if let prior=previous,let priorBytes=previousBytes {
                guard item.version==2,item.parent==Data(SHA256.hash(data:priorBytes)),
                      prior.revision<UInt64.max,item.revision==prior.revision+1,
                      let issuer=item.issuer,let member=prior.members.first(where:{$0.device==issuer}),member.permissions == .all else {throw MembershipError.notMember}
                publicKey=member.signingPublic
            } else {guard item.version==1 else {throw MembershipError.malformed};publicKey=ownerPublic}
            let key=try Curve25519.Signing.PublicKey(rawRepresentation:publicKey)
            guard item.signature.count==64,key.isValidSignature(item.signature,for:canonical) else {throw MembershipError.invalidSignature}
            if let old,item.revision==old.statement.revision {retainedDigest=Data(SHA256.hash(data:canonical))}
            previous=item;previousBytes=canonical
        }
        if let old {
            guard old.anchor==self,statement.revision>=old.statement.revision else {throw MembershipError.rollback}
            if statement.version==2 {guard retainedDigest==old.digest else {throw MembershipError.equivocation}}
            else if statement.revision==old.statement.revision,bytes != old.canonicalBytes {throw MembershipError.equivocation}
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

extension SignedMembership {
    func signingKey(for identity:DeviceIdentity) throws -> Curve25519.Signing.PrivateKey {
        if version==1 {
            guard identity.ownerID==ownerID,identity.ownerSigningKey.publicKey.rawRepresentation==ownerPublic else {throw MembershipError.wrongOwner}
            return identity.ownerSigningKey
        }
        guard issuer==identity.device,try authorizationPublic()==identity.signingKey.publicKey.rawRepresentation else {throw MembershipError.notMember}
        return identity.signingKey
    }
}
