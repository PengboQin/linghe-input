import XCTest
import CryptoKit
@testable import PrivateInputKit

final class SecureMessageTests: XCTestCase {
    let group = UUID(), sender = UUID()
    let signing = Curve25519.Signing.PrivateKey()
    let key = SymmetricKey(size: .bits256)
    var trust: SyncTrust { .init(group: group, epoch: 1, members: [sender: signing.publicKey.rawRepresentation]) }
    func message(_ sequence: UInt64 = 1, domain: SyncDomain = .clipboard) throws -> SecureEnvelope {
        let payload: Data
        if domain == .learning {
            var model = LearningModel(); try model.record(reading: "ni hao", text: "拟好", device: "synthetic")
            payload = try model.export()
        } else { payload = Data("合成剪贴板 · Synthetic fixture 🔒".utf8) }
        return try SecureMessage.seal(payload: payload, domain: domain, groupKey: key, signingKey: signing, trust: trust, sender: sender, sequence: sequence, issuedAt: 1000, expiresAt: 1600)
    }
    func testLearningAndClipboardRoundTripWithoutPlaintextInEnvelope() throws {
        for domain in [SyncDomain.learning, .clipboard] {
            let sealed = try message(domain: domain), bytes = try sealed.encoded()
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("合成剪贴板"))
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("拟好"))
            let opened = try SecureMessage.open(SecureEnvelope.decode(bytes), groupKey: key, trust: trust, ledger: .init(), now: 1010)
            if domain == .clipboard { XCTAssertTrue(String(decoding: opened.payload, as: UTF8.self).contains("合成剪贴板")) }
            else { var model = LearningModel(); try model.merge(opened.payload); XCTAssertEqual(model.entries.count, 1) }
        }
    }
    func testEveryAuthenticatedHeaderFieldAndCiphertextRejectsTampering() throws {
        let original = try message()
        var cases: [SecureEnvelope] = []
        var m = original; m.version = 2; cases.append(m)
        m = original; m.group = UUID(); cases.append(m)
        m = original; m.sender = UUID(); cases.append(m)
        m = original; m.event = UUID(); cases.append(m)
        m = original; m.epoch += 1; cases.append(m)
        m = original; m.sequence += 1; cases.append(m)
        m = original; m.domain = .learning; cases.append(m)
        m = original; m.issuedAt += 1; cases.append(m)
        m = original; m.expiresAt -= 1; cases.append(m)
        m = original; m.ciphertext[m.ciphertext.startIndex] ^= 1; cases.append(m)
        m = original; m.signature[m.signature.startIndex] ^= 1; cases.append(m)
        for item in cases { XCTAssertThrowsError(try SecureMessage.open(item, groupKey: key, trust: trust, ledger: .init(), now: 1010)) }
    }
    func testUntrustedRevokedDeviceAndOldEpochCannotDeliver() throws {
        let sealed = try message()
        let removed = SyncTrust(group: group, epoch: 1, members: [:])
        XCTAssertThrowsError(try SecureMessage.open(sealed, groupKey: key, trust: removed, ledger: .init(), now: 1010))
        let rotated = SyncTrust(group: group, epoch: 2, members: trust.members)
        XCTAssertThrowsError(try SecureMessage.open(sealed, groupKey: key, trust: rotated, ledger: .init(), now: 1010))
        XCTAssertThrowsError(try SecureMessage.open(sealed, groupKey: SymmetricKey(size: .bits256), trust: trust, ledger: .init(), now: 1010))
    }
    func testOutOfOrderAcceptedOnceReplayAndStaleWindowRejectedAfterPersistence() throws {
        var ledger = ReplayLedger()
        for sequence: UInt64 in [3, 1, 2, 70, 69] {
            let opened = try SecureMessage.open(message(sequence), groupKey: key, trust: trust, ledger: ledger, now: 1010)
            ledger = try JSONDecoder().decode(ReplayLedger.self, from: JSONEncoder().encode(opened.ledger))
        }
        for sequence: UInt64 in [70, 69, 2] { XCTAssertThrowsError(try SecureMessage.open(message(sequence), groupKey: key, trust: trust, ledger: ledger, now: 1010)) }
    }
    func testExpiryInvalidPayloadAndFailureDoNotAdvanceLedger() throws {
        let sealed = try message(), ledger = ReplayLedger()
        XCTAssertThrowsError(try SecureMessage.open(sealed, groupKey: key, trust: trust, ledger: ledger, now: 1600))
        XCTAssertThrowsError(try SecureMessage.open(sealed, groupKey: key, trust: trust, ledger: ledger, now: 699))
        XCTAssertEqual(ledger, ReplayLedger())
        XCTAssertThrowsError(try SecureMessage.seal(payload: Data(repeating: 65, count: 65537), domain: .clipboard, groupKey: key, signingKey: signing, trust: trust, sender: sender, sequence: 1, issuedAt: 1000, expiresAt: 1600))
        XCTAssertThrowsError(try SecureMessage.seal(payload: Data("bad learning".utf8), domain: .learning, groupKey: key, signingKey: signing, trust: trust, sender: sender, sequence: 1, issuedAt: 1000, expiresAt: 1600))
        XCTAssertThrowsError(try message(0))
    }
    func testSenderAndDataDomainsUseDifferentKeysAtSameSequence() throws {
        let a = try message(), b = try message(domain: .learning)
        let ka = try SecureMessage.domainKey(groupKey: key, message: a, publicKey: signing.publicKey.rawRepresentation)
        let kb = try SecureMessage.domainKey(groupKey: key, message: b, publicKey: signing.publicKey.rawRepresentation)
        XCTAssertNotEqual(ka, kb)
        var c = a; c.sender = UUID()
        XCTAssertNotEqual(ka, try SecureMessage.domainKey(groupKey: key, message: c, publicKey: signing.publicKey.rawRepresentation))
    }
}
