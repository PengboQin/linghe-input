import Foundation
import CryptoKit

public enum SyncSecurityError: Error {
    case invalidEnvelope, untrustedDevice, wrongGroupOrEpoch, invalidSignature, replay, expired, invalidPayload
}
public enum SyncDomain: UInt8, Codable { case learning = 1, clipboard = 2 }

public struct SecureEnvelope: Codable {
    public var version: UInt8 = 1
    public var group: UUID
    public var sender: UUID
    public var event: UUID
    public var epoch: UInt64
    public var sequence: UInt64
    public var domain: SyncDomain
    public var issuedAt: UInt64
    public var expiresAt: UInt64
    public var ciphertext: Data
    public var signature: Data

    // Fixed binary order. JSON field order and base64 spelling never affect AAD.
    func header() throws -> Data {
        guard version == 1, epoch > 0, sequence > 0,
              expiresAt > issuedAt, expiresAt - issuedAt <= (domain == .clipboard ? 600 : 604800),
              ciphertext.count <= (domain == .clipboard ? 65536 : 2097152) + 16 else { throw SyncSecurityError.invalidEnvelope }
        var bytes = Data("PrivateInput/event/v1\0".utf8)
        bytes.append(version); bytes.appendUUID(group); bytes.appendUUID(sender); bytes.appendUUID(event)
        bytes.appendBE(epoch); bytes.appendBE(sequence); bytes.append(domain.rawValue)
        bytes.appendBE(issuedAt); bytes.appendBE(expiresAt)
        return bytes
    }
    func nonce() throws -> ChaChaPoly.Nonce {
        var data = Data(repeating: 0, count: 4); data.appendBE(sequence)
        return try ChaChaPoly.Nonce(data: data)
    }
    public func encoded() throws -> Data {
        _ = try header()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 3 * 1024 * 1024 else { throw SyncSecurityError.invalidEnvelope }
        let envelope = try JSONDecoder().decode(Self.self, from: data)
        _ = try envelope.header()
        guard envelope.signature.count == 64, envelope.ciphertext.count >= 16 else { throw SyncSecurityError.invalidEnvelope }
        return envelope
    }
}

public struct SyncTrust {
    public let group: UUID
    public let epoch: UInt64
    public let members: [UUID: Data]
    // Supplied only by the authenticated member-state layer, never relay JSON.
    public init(group: UUID, epoch: UInt64, members: [UUID: Data]) {
        self.group = group; self.epoch = epoch; self.members = members
    }
}

public struct ReplayLedger: Codable, Equatable {
    private struct Window: Codable, Equatable { var highest: UInt64; var bitmap: UInt64 }
    private var windows: [String: Window] = [:]
    public init() {}
    func accepting(_ message: SecureEnvelope) throws -> Self {
        let id = message.group.uuidString + "/" + String(message.epoch) + "/" + message.sender.uuidString
        var next = self
        if var window = windows[id] {
            if message.sequence > window.highest {
                let distance = message.sequence - window.highest
                window.bitmap = distance >= 64 ? 1 : (window.bitmap << distance) | 1
                window.highest = message.sequence
            } else {
                let distance = window.highest - message.sequence
                guard distance < 64, window.bitmap & (UInt64(1) << distance) == 0 else { throw SyncSecurityError.replay }
                window.bitmap |= UInt64(1) << distance
            }
            next.windows[id] = window
        } else { next.windows[id] = Window(highest: message.sequence, bitmap: 1) }
        return next
    }
}

public struct OpenedSyncMessage {
    public let payload: Data
    public let ledger: ReplayLedger
}

public enum SecureMessage {
    static func domainKey(groupKey: SymmetricKey, message: SecureEnvelope, publicKey: Data) throws -> SymmetricKey {
        guard groupKey.bitCount == 256, publicKey.count == 32 else { throw SyncSecurityError.invalidEnvelope }
        var salt = Data(); salt.appendUUID(message.group); salt.appendBE(message.epoch)
        var info = Data("PrivateInput/sender-domain-key/v1\0".utf8)
        info.appendUUID(message.sender); info.append(publicKey); info.append(message.domain.rawValue)
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: groupKey, salt: salt, info: info, outputByteCount: 32)
    }
    static func validatePayload(_ payload: Data, domain: SyncDomain) throws {
        switch domain {
        case .learning:
            var model = LearningModel(); try model.merge(payload)
        case .clipboard:
            guard !payload.isEmpty, payload.count <= 65536, let text = String(data: payload, encoding: .utf8), !text.contains("\0") else { throw SyncSecurityError.invalidPayload }
        }
    }
    /// sequence must be durably reserved BEFORE sending; never reset with the same
    /// sender/key epoch. This primitive performs no key or sequence persistence.
    public static func seal(payload: Data, domain: SyncDomain, groupKey: SymmetricKey,
                            signingKey: Curve25519.Signing.PrivateKey, trust: SyncTrust,
                            sender: UUID, event: UUID = UUID(), sequence: UInt64,
                            issuedAt: UInt64, expiresAt: UInt64) throws -> SecureEnvelope {
        let publicKey = signingKey.publicKey.rawRepresentation
        guard trust.members[sender] == publicKey else { throw SyncSecurityError.untrustedDevice }
        try validatePayload(payload, domain: domain)
        var envelope = SecureEnvelope(group: trust.group, sender: sender, event: event, epoch: trust.epoch,
                                      sequence: sequence, domain: domain, issuedAt: issuedAt, expiresAt: expiresAt,
                                      ciphertext: Data(), signature: Data())
        let header = try envelope.header()
        let key = try domainKey(groupKey: groupKey, message: envelope, publicKey: publicKey)
        let box = try ChaChaPoly.seal(payload, using: key, nonce: envelope.nonce(), authenticating: header)
        envelope.ciphertext = box.ciphertext + box.tag
        envelope.signature = Data(try signingKey.signature(for: header + envelope.ciphertext))
        return envelope
    }
    /// Persist the returned ledger together with the validated payload's applied
    /// state in one transaction. Failure leaves the supplied ledger untouched.
    public static func open(_ message: SecureEnvelope, groupKey: SymmetricKey, trust: SyncTrust,
                            ledger: ReplayLedger, now: UInt64) throws -> OpenedSyncMessage {
        let header = try message.header()
        guard message.group == trust.group, message.epoch == trust.epoch else { throw SyncSecurityError.wrongGroupOrEpoch }
        guard let publicData = trust.members[message.sender], publicData.count == 32 else { throw SyncSecurityError.untrustedDevice }
        let signer = try Curve25519.Signing.PublicKey(rawRepresentation: publicData)
        guard message.signature.count == 64, signer.isValidSignature(message.signature, for: header + message.ciphertext) else { throw SyncSecurityError.invalidSignature }
        guard now < message.expiresAt, message.issuedAt <= now || message.issuedAt - now <= 300 else { throw SyncSecurityError.expired }
        let nextLedger = try ledger.accepting(message)
        guard message.ciphertext.count >= 16 else { throw SyncSecurityError.invalidEnvelope }
        let key = try domainKey(groupKey: groupKey, message: message, publicKey: publicData)
        let box = try ChaChaPoly.SealedBox(nonce: message.nonce(), ciphertext: message.ciphertext.dropLast(16), tag: message.ciphertext.suffix(16))
        let payload = try ChaChaPoly.open(box, using: key, authenticating: header)
        try validatePayload(payload, domain: message.domain)
        return OpenedSyncMessage(payload: payload, ledger: nextLedger)
    }
}

extension Data {
    mutating func appendBE(_ value: UInt64) {
        var big = value.bigEndian; Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }
    mutating func appendUUID(_ value: UUID) {
        var bytes = value.uuid; Swift.withUnsafeBytes(of: &bytes) { append(contentsOf: $0) }
    }
}
