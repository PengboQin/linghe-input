import Foundation
import CryptoKit

public enum PairingError: Error { case malformed, expired, invalidSignature, wrongRecipient, confirmationMismatch }
public enum WrappedKeyPurpose: UInt8, Codable { case pairing = 1, rotation = 2 }

public struct PairRequest: Codable {
    public var version: UInt8 = 1
    public var session: UUID
    public var member: GroupMember
    public var challenge: Data
    public var issuedAt: UInt64
    public var expiresAt: UInt64
    public var signature: Data
    func canonical() throws -> Data {
        guard version == 1, member.signingPublic.count == 32, member.exchangePublic.count == 32,
              member.permissions == .all, challenge.count == 32,
              expiresAt > issuedAt, expiresAt - issuedAt <= 600 else { throw PairingError.malformed }
        var bytes = Data("PrivateInput/pair-request/v1\0".utf8)
        bytes.append(version); bytes.appendUUID(session); bytes.appendUUID(member.device)
        bytes.append(member.signingPublic); bytes.append(member.exchangePublic); bytes.append(challenge)
        bytes.appendBE(issuedAt); bytes.appendBE(expiresAt); return bytes
    }
    public var digest: Data { get throws { Data(SHA256.hash(data: try canonical())) } }
    public func validate(now: UInt64) throws {
        let bytes = try canonical()
        guard now < expiresAt, issuedAt <= now || issuedAt - now <= 300 else { throw PairingError.expired }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: member.signingPublic)
        guard signature.count == 64, key.isValidSignature(signature, for: bytes) else { throw PairingError.invalidSignature }
    }
    public static func create(identity: DeviceIdentity, now: UInt64) throws -> Self {
        guard now <= UInt64.max - 600 else { throw PairingError.malformed }
        let challenge = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        var request = Self(session: UUID(), member: GroupMember(identity: identity), challenge: challenge,
                           issuedAt: now, expiresAt: now + 600, signature: Data())
        request.signature = Data(try identity.signingKey.signature(for: request.canonical())); return request
    }
    public func encoded() throws -> Data { _ = try canonical(); return try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 4096 else { throw PairingError.malformed }
        let value = try JSONDecoder().decode(Self.self, from: data); _ = try value.canonical(); return value
    }
}

public struct GroupSetup {
    public let membership: VerifiedMembership
    public let key: SymmetricKey
    public static func create(owner: DeviceIdentity) throws -> Self {
        let group = UUID()
        let statement = try SignedMembership.sign(group: group, ownerID: owner.ownerID, ownerKey: owner.ownerSigningKey,
                                                   revision: 1, members: [GroupMember(identity: owner)])
        let anchor = MembershipAnchor(group: group, ownerID: owner.ownerID, ownerPublic: owner.ownerSigningKey.publicKey.rawRepresentation)
        return Self(membership: try anchor.verify(statement), key: SymmetricKey(size: .bits256))
    }
    /// Every member/permission change rotates epoch AND content key. Existing
    /// recipients still need their own authenticated key packages delivered.
    public func changingMembers(_ members: [GroupMember], owner: DeviceIdentity) throws -> Self {
        guard owner.ownerID == membership.anchor.ownerID,
              owner.ownerSigningKey.publicKey.rawRepresentation == membership.anchor.ownerPublic,
              membership.statement.revision < UInt64.max else { throw MembershipError.wrongOwner }
        let statement = try SignedMembership.sign(group: membership.anchor.group, ownerID: owner.ownerID,
                                                   ownerKey: owner.ownerSigningKey, revision: membership.statement.revision + 1, members: members)
        return Self(membership: try membership.anchor.verify(statement, replacing: membership), key: SymmetricKey(size: .bits256))
    }
}

/// Public signed member state plus a recipient-specific encrypted 32-byte key.
/// The owner root private key is never included in a package.
public struct WrappedGroupKey: Codable {
    public var version: UInt8 = 1
    public var purpose: WrappedKeyPurpose
    public var recipient: UUID
    public var ephemeralPublic: Data
    public var context: Data
    public var membership: SignedMembership
    public var issuedAt: UInt64
    public var expiresAt: UInt64
    public var sealedKey: Data
    public var signature: Data
    func header() throws -> Data {
        guard version == 1, ephemeralPublic.count == 32, context.count == 32,
              expiresAt > issuedAt, expiresAt - issuedAt <= (purpose == .pairing ? 600 : 2592000),
              purpose == .pairing ? context != Data(repeating: 0, count: 32) : context == Data(repeating: 0, count: 32) else { throw PairingError.malformed }
        guard let member = membership.members.first(where: { $0.device == recipient }) else { throw PairingError.wrongRecipient }
        var bytes = Data("PrivateInput/wrapped-group-key/v1\0".utf8)
        bytes.append(version); bytes.append(purpose.rawValue); bytes.appendUUID(recipient); bytes.append(member.exchangePublic)
        bytes.append(ephemeralPublic); bytes.append(context)
        bytes.append(Data(SHA256.hash(data: try membership.canonical())))
        bytes.appendBE(issuedAt); bytes.appendBE(expiresAt); return bytes
    }
    static func wrappingKey(secret: SharedSecret, header: Data) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(SHA256.hash(data: header)),
                                      sharedInfo: Data("PrivateInput/wrapping-key/v1\0".utf8), outputByteCount: 32)
    }
    static func confirmationCode(secret: SharedSecret, header: Data) -> String {
        let key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(SHA256.hash(data: header)),
                                                 sharedInfo: Data("PrivateInput/pair-confirm/v1\0".utf8), outputByteCount: 32)
        let bytes = key.withUnsafeBytes { Array($0) }
        let value = bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return String(format: "%06u", value % 1_000_000)
    }
    static func seal(setup: GroupSetup, for recipient: UUID, context: Data, owner: DeviceIdentity,
                            now: UInt64, expiresAt: UInt64) throws -> (package: Self, confirmationCode: String) {
        guard owner.ownerID == setup.membership.anchor.ownerID,
              owner.ownerSigningKey.publicKey.rawRepresentation == setup.membership.anchor.ownerPublic,
              setup.key.bitCount == 256 else { throw MembershipError.wrongOwner }
        let member = try setup.membership.member(recipient)
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: member.exchangePublic)
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: peer)
        var package = Self(purpose: context == Data(repeating: 0, count: 32) ? .rotation : .pairing,
                           recipient: recipient, ephemeralPublic: ephemeral.publicKey.rawRepresentation,
                           context: context, membership: setup.membership.statement, issuedAt: now,
                           expiresAt: expiresAt, sealedKey: Data(), signature: Data())
        let header = try package.header()
        let content = setup.key.withUnsafeBytes { Data($0) }
        package.sealedKey = try ChaChaPoly.seal(content, using: wrappingKey(secret: secret, header: header), authenticating: header).combined
        package.signature = Data(try owner.ownerSigningKey.signature(for: header + package.sealedKey))
        return (package, confirmationCode(secret: secret, header: header))
    }
    func inspect(recipient identity: DeviceIdentity, expectedContext: Data, now: UInt64,
                 anchor: MembershipAnchor?, replacing old: VerifiedMembership?) throws -> (group: GroupSetup, code: String) {
        guard recipient == identity.device, context == expectedContext, sealedKey.count == 60 else { throw PairingError.wrongRecipient }
        let header = try self.header()
        guard now < expiresAt, issuedAt <= now || issuedAt - now <= 300 else { throw PairingError.expired }
        let claimedAnchor = MembershipAnchor(group: membership.group, ownerID: membership.ownerID, ownerPublic: membership.ownerPublic)
        guard anchor == nil || anchor == claimedAnchor else { throw MembershipError.wrongOwner }
        let verified = try claimedAnchor.verify(membership, replacing: old)
        let member = try verified.member(recipient)
        guard member.signingPublic == identity.signingKey.publicKey.rawRepresentation,
              member.exchangePublic == identity.exchangeKey.publicKey.rawRepresentation else { throw PairingError.wrongRecipient }
        let signer = try Curve25519.Signing.PublicKey(rawRepresentation: claimedAnchor.ownerPublic)
        guard signature.count == 64, signer.isValidSignature(signature, for: header + sealedKey) else { throw PairingError.invalidSignature }
        let ephemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralPublic)
        let secret = try identity.exchangeKey.sharedSecretFromKeyAgreement(with: ephemeral)
        let box = try ChaChaPoly.SealedBox(combined: sealedKey)
        let plaintext = try ChaChaPoly.open(box, using: Self.wrappingKey(secret: secret, header: header), authenticating: header)
        guard plaintext.count == 32 else { throw PairingError.malformed }
        return (GroupSetup(membership: verified, key: SymmetricKey(data: plaintext)), Self.confirmationCode(secret: secret, header: header))
    }
    /// Existing members already trust the owner root. Key rotation needs no new
    /// human pairing but still checks recipient, signed version and old state.
    public func openRotation(recipient: DeviceIdentity, current: VerifiedMembership, now: UInt64) throws -> GroupSetup {
        guard purpose == .rotation else { throw PairingError.malformed }
        return try inspect(recipient: recipient, expectedContext: Data(repeating: 0, count: 32), now: now,
                    anchor: current.anchor, replacing: current).group
    }
    public func encoded() throws -> Data { _ = try header(); return try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 65536 else { throw PairingError.malformed }
        let value = try JSONDecoder().decode(Self.self, from: data); _ = try value.header(); return value
    }
}

public enum DevicePairing {
    public static func beginApproval(_ request: PairRequest, current: GroupSetup, owner: DeviceIdentity,
                                     permissions: DevicePermissions, now: UInt64) throws -> PendingPairingApproval {
        try request.validate(now: now)
        guard !current.membership.statement.members.contains(where: { $0.device == request.member.device }) else { throw MembershipError.malformed }
        let approved = GroupMember(device: request.member.device, signingPublic: request.member.signingPublic,
                                   exchangePublic: request.member.exchangePublic, permissions: permissions)
        let next = try current.changingMembers(current.membership.statement.members + [approved], owner: owner)
        guard now <= UInt64.max - 600 else { throw PairingError.malformed }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        var proposed = next.membership.statement
        proposed.signature = Data() // Challenge is not a publishable authorization.
        var template = WrappedGroupKey(purpose: .pairing, recipient: approved.device, ephemeralPublic: ephemeral.publicKey.rawRepresentation,
                                       context: try request.digest, membership: proposed, issuedAt: now,
                                       expiresAt: min(request.expiresAt, now + 600), sealedKey: Data(), signature: Data())
        let header = try template.header()
        template.signature = Data(try owner.ownerSigningKey.signature(for: header))
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: approved.exchangePublic))
        // No group key is released in the challenge. Persist pending secrets only
        // in the encrypted local store, never in a relay request or QR code.
        return PendingPairingApproval(parentDigest: current.membership.digest, group: next, ephemeral: ephemeral,
                                      challenge: PairingChallenge(template: template),
                                      confirmationCode: WrappedGroupKey.confirmationCode(secret: secret, header: header))
    }
    public static func authenticationCode(_ challenge: PairingChallenge, request: PairRequest,
                                           recipient: DeviceIdentity, now: UInt64) throws -> String {
        try request.validate(now: now)
        try challenge.validate(request: request, recipient: recipient, now: now)
        let template = challenge.template
        let secret = try recipient.exchangeKey.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: template.ephemeralPublic))
        return WrappedGroupKey.confirmationCode(secret: secret, header: try template.header())
    }
    public static func finishApproval(_ pending: PendingPairingApproval, owner: DeviceIdentity,
                                      confirmedCode: String, now: UInt64) throws -> (group: GroupSetup, package: WrappedGroupKey) {
        guard now < pending.challenge.template.expiresAt else { throw PairingError.expired }
        guard confirmedCode == pending.confirmationCode, confirmedCode.count == 6 else { throw PairingError.confirmationMismatch }
        guard owner.ownerID == pending.group.membership.anchor.ownerID,
              owner.ownerSigningKey.publicKey.rawRepresentation == pending.group.membership.anchor.ownerPublic else { throw MembershipError.wrongOwner }
        var package = pending.challenge.template
        package.membership = pending.group.membership.statement
        let member = try pending.group.membership.member(package.recipient)
        let secret = try pending.ephemeral.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: member.exchangePublic))
        let header = try package.header()
        let content = pending.group.key.withUnsafeBytes { Data($0) }
        package.sealedKey = try ChaChaPoly.seal(content, using: WrappedGroupKey.wrappingKey(secret: secret, header: header), authenticating: header).combined
        package.signature = Data(try owner.ownerSigningKey.signature(for: header + package.sealedKey))
        return (pending.group, package)
    }
    /// Caller displays codes on BOTH devices, accepts an explicit user confirm,
    /// and transactionally marks request.session consumed with group import.
    public static func accept(_ package: WrappedGroupKey, challenge: PairingChallenge, request: PairRequest, recipient: DeviceIdentity,
                              confirmedCode: String, now: UInt64) throws -> GroupSetup {
        try request.validate(now: now)
        try challenge.validate(request: request, recipient: recipient, now: now)
        guard request.member == GroupMember(identity: recipient) else { throw PairingError.wrongRecipient }
        guard try package.header() == challenge.template.header() else { throw PairingError.wrongRecipient }
        let checked = try package.inspect(recipient: recipient, expectedContext: request.digest, now: now, anchor: nil, replacing: nil)
        guard confirmedCode.count == 6, confirmedCode == checked.code else { throw PairingError.confirmationMismatch }
        return checked.group
    }
}

public struct PairingChallenge: Codable {
    let template: WrappedGroupKey
    public var expiresAt: UInt64 { template.expiresAt }
    public var anchor: MembershipAnchor { MembershipAnchor(group: template.membership.group, ownerID: template.membership.ownerID, ownerPublic: template.membership.ownerPublic) }
    func validate(request: PairRequest, recipient: DeviceIdentity, now: UInt64) throws {
        guard template.purpose == .pairing, template.sealedKey.isEmpty, template.recipient == recipient.device, template.context == (try request.digest),
              now < template.expiresAt, template.expiresAt <= request.expiresAt else { throw PairingError.malformed }
        let anchor = MembershipAnchor(group: template.membership.group, ownerID: template.membership.ownerID,
                                      ownerPublic: template.membership.ownerPublic)
        guard template.membership.signature.isEmpty else { throw PairingError.malformed }
        _ = try template.membership.canonical()
        guard let member = template.membership.members.first(where: { $0.device == recipient.device }) else { throw PairingError.wrongRecipient }
        guard member.signingPublic == recipient.signingKey.publicKey.rawRepresentation,
              member.exchangePublic == recipient.exchangeKey.publicKey.rawRepresentation else { throw PairingError.wrongRecipient }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: anchor.ownerPublic)
        guard template.signature.count == 64, key.isValidSignature(template.signature, for: try template.header()) else { throw PairingError.invalidSignature }
    }
    public func encoded() throws -> Data {
        guard template.sealedKey.isEmpty, template.membership.signature.isEmpty else { throw PairingError.malformed }
        return try JSONEncoder().encode(self)
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 65536 else { throw PairingError.malformed }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.template.sealedKey.isEmpty, value.template.membership.signature.isEmpty else { throw PairingError.malformed }
        _ = try value.template.header(); return value
    }
}

public struct PendingPairingApproval {
    let parentDigest: Data
    let group: GroupSetup
    let ephemeral: Curve25519.KeyAgreement.PrivateKey
    public let challenge: PairingChallenge
    public let confirmationCode: String
}
