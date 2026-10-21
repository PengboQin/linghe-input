import XCTest
import CryptoKit
@testable import PrivateInputKit

final class SyntheticIdentityStore: IdentitySecretStore {
    var data: Data?
    var failWrite = false
    func read() throws -> Data? { data }
    func insert(_ data: Data) throws {
        if failWrite { throw IdentityStoreError.busy }
        guard self.data == nil else { throw IdentityStoreError.alreadyExists }; self.data = data
    }
    func replace(_ data: Data) throws {
        if failWrite { throw IdentityStoreError.busy }
        guard self.data != nil else { throw IdentityStoreError.absent }; self.data = data
    }
}

final class IdentityAndPairingTests: XCTestCase {
    private var temporary: [URL] = []
    override func tearDownWithError() throws { for path in temporary { try FileManager.default.removeItem(at: path) }; temporary = [] }
    func directory() -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("PrivateInput-Secure-" + UUID().uuidString)
        temporary.append(path); return path
    }
    func identity() throws -> DeviceIdentity {
        try DeviceIdentityVault(store: SyntheticIdentityStore(), directory: directory()).create()
    }
    func testReservationPersistsBeforeReturnAndSurvivesNewVaultInstance() throws {
        let store = SyntheticIdentityStore(), path = directory()
        let vault = try DeviceIdentityVault(store: store, directory: path), id = try vault.create()
        XCTAssertEqual(try vault.reserveSequence().sequence, 1)
        store.failWrite = true
        XCTAssertThrowsError(try vault.reserveSequence())
        store.failWrite = false
        let reopened = try DeviceIdentityVault(store: store, directory: path)
        let reserved = try reopened.reserveSequence()
        XCTAssertEqual(reserved.sequence, 2); XCTAssertEqual(reserved.identity.device, id.device)
        XCTAssertEqual(reserved.identity.signingKey.publicKey.rawRepresentation, id.signingKey.publicKey.rawRepresentation)
        XCTAssertThrowsError(try reopened.create())
        // Simulate a crash after reservation but before outbox commit: skip it.
        _ = try reopened.reserveSequence()
        XCTAssertEqual(try DeviceIdentityVault(store: store, directory: path).reserveSequence().sequence, 4)
    }
    func testAbsentCorruptAndExhaustedIdentityNeverRegenerates() throws {
        let store = SyntheticIdentityStore(), vault = try DeviceIdentityVault(store: store, directory: directory())
        XCTAssertThrowsError(try vault.load()); XCTAssertNil(store.data)
        _ = try vault.create(); store.data = Data("corrupt".utf8)
        XCTAssertThrowsError(try vault.load()); XCTAssertEqual(store.data, Data("corrupt".utf8))
        let fresh = SyntheticIdentityStore(), second = try DeviceIdentityVault(store: fresh, directory: directory())
        _ = try second.create()
        var record = try JSONDecoder().decode(StoredDeviceIdentity.self, from: XCTUnwrap(fresh.data))
        record.reservedSequence = UInt64.max; fresh.data = try JSONEncoder().encode(record)
        XCTAssertThrowsError(try second.reserveSequence())
    }
    func testSeparateVaultInstancesReserveUniqueSequencesUnderContention() throws {
        let store = SyntheticIdentityStore(), path = directory()
        let first = try DeviceIdentityVault(store: store, directory: path), second = try DeviceIdentityVault(store: store, directory: path)
        _ = try first.create()
        let resultsGate = NSLock(); var sequences: [UInt64] = []; var failures = 0
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            let vault = index % 2 == 0 ? first : second
            for _ in 0..<1000 {
                do {
                    let value = try vault.reserveSequence().sequence
                    resultsGate.lock(); sequences.append(value); resultsGate.unlock(); return
                } catch IdentityStoreError.busy { usleep(1000) }
                catch { break }
            }
            resultsGate.lock(); failures += 1; resultsGate.unlock()
        }
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(sequences.sorted(), Array(UInt64(1)...UInt64(32)))
    }
    func testOSKeychainOwnRecordReloadAndSequence() throws {
        guard ProcessInfo.processInfo.environment["PRIVATE_INPUT_TEST_OS_KEYCHAIN"] == "1" else { throw XCTSkip("Run scripts/test_secure_storage.sh for scoped OS Keychain validation") }
        let store = try KeychainIdentityStore(account: "synthetic-" + UUID().uuidString, testing: true)
        defer { do { try store.removeTestRecord() } catch { XCTFail("Own synthetic Keychain record cleanup failed") } }
        let path = directory(), vault = try DeviceIdentityVault(store: store, directory: path)
        let id = try vault.create(); _ = try vault.reserveSequence()
        let reopened = try DeviceIdentityVault(store: store, directory: path)
        XCTAssertEqual(try reopened.reserveSequence().sequence, 2)
        XCTAssertEqual(try reopened.load().device, id.device)
        XCTAssertTrue(try reopened.load().storageKey == id.storageKey)
    }
    func paired(_ owner: DeviceIdentity, _ joiner: DeviceIdentity) throws -> (GroupSetup, GroupSetup, PairRequest, PairingChallenge, WrappedGroupKey) {
        let initial = try GroupSetup.create(owner: owner), request = try PairRequest.create(identity: joiner, now: 1000)
        let pending = try DevicePairing.beginApproval(request, current: initial, owner: owner, permissions: .all, now: 1001)
        let challenge = try PairingChallenge.decode(pending.challenge.encoded())
        let code = try DevicePairing.authenticationCode(challenge, request: request, recipient: joiner, now: 1002)
        XCTAssertEqual(code, pending.confirmationCode)
        let released = try DevicePairing.finishApproval(pending, owner: owner, confirmedCode: code, now: 1003)
        let package = try WrappedGroupKey.decode(released.package.encoded())
        let joined = try DevicePairing.accept(package, challenge: challenge, request: request, recipient: joiner, confirmedCode: code, now: 1004)
        return (released.group, joined, request, challenge, package)
    }
    func testPairingDoesNotReleaseGroupKeyBeforeOwnerConfirmation() throws {
        let owner = try identity(), joiner = try identity(), initial = try GroupSetup.create(owner: owner)
        let request = try PairRequest.create(identity: joiner, now: 1000)
        let pending = try DevicePairing.beginApproval(request, current: initial, owner: owner, permissions: .all, now: 1001)
        XCTAssertTrue(pending.challenge.template.sealedKey.isEmpty)
        XCTAssertTrue(pending.challenge.template.membership.signature.isEmpty)
        XCTAssertThrowsError(try initial.membership.anchor.verify(pending.challenge.template.membership), "Challenge must not authorize server membership before confirmation")
        var forgedAuthorization = pending.challenge.template.membership
        forgedAuthorization.signature = pending.challenge.template.signature
        XCTAssertThrowsError(try initial.membership.anchor.verify(forgedAuthorization), "A challenge signature cannot be reused as membership authorization")
        XCTAssertEqual(initial.membership.statement.members.count, 1)
        let bytes = try pending.challenge.encoded(), master = pending.group.key.withUnsafeBytes { Data($0) }.base64EncodedString()
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(master))
        XCTAssertThrowsError(try DevicePairing.finishApproval(pending, owner: owner, confirmedCode: "not-confirmed", now: 1002))
        XCTAssertThrowsError(try DevicePairing.finishApproval(pending, owner: owner, confirmedCode: pending.confirmationCode, now: 1600))
        // Owner root is a separate authority from the sender's device signature.
        XCTAssertNotEqual(owner.ownerSigningKey.publicKey.rawRepresentation, owner.signingKey.publicKey.rawRepresentation)
    }
    func testAllowedClockSkewCannotExtendOrInvalidatePairingChallengeLifetime() throws {
        let owner = try identity(), joiner = try identity(), initial = try GroupSetup.create(owner: owner)
        let request = try PairRequest.create(identity: joiner, now: 1299)
        let pending = try DevicePairing.beginApproval(request, current: initial, owner: owner, permissions: .all, now: 1000)
        XCTAssertEqual(pending.challenge.template.expiresAt, 1600)
        XCTAssertEqual(try DevicePairing.authenticationCode(pending.challenge, request: request, recipient: joiner, now: 1299), pending.confirmationCode)
    }
    func testPairingGrantEncryptsAndBindsRecipientOwnerContextAndBothKeys() throws {
        let owner = try identity(), joiner = try identity(), attacker = try identity()
        let (approved, joined, request, challenge, package) = try paired(owner, joiner)
        XCTAssertTrue(approved.key == joined.key)
        XCTAssertEqual(approved.membership.digest, joined.membership.digest)
        let code = try DevicePairing.authenticationCode(challenge, request: request, recipient: joiner, now: 1005)
        XCTAssertThrowsError(try DevicePairing.accept(package, challenge: challenge, request: request, recipient: attacker, confirmedCode: code, now: 1005))
        XCTAssertThrowsError(try DevicePairing.accept(package, challenge: challenge, request: request, recipient: joiner, confirmedCode: "wrong-code", now: 1005))
        var altered = package; altered.sealedKey[altered.sealedKey.startIndex] ^= 1
        XCTAssertThrowsError(try DevicePairing.accept(altered, challenge: challenge, request: request, recipient: joiner, confirmedCode: code, now: 1005))
        altered = package; altered.context[altered.context.startIndex] ^= 1
        XCTAssertThrowsError(try DevicePairing.accept(altered, challenge: challenge, request: request, recipient: joiner, confirmedCode: code, now: 1005))
        var tamperedRequest = request; tamperedRequest.member = GroupMember(identity: attacker)
        XCTAssertThrowsError(try tamperedRequest.validate(now: 1005))
        XCTAssertThrowsError(try request.validate(now: 1600))
    }
    func testOwnerSignedStateRejectsRollbackEquivocationAndRelayAddedMember() throws {
        let owner = try identity(), joiner = try identity(), attacker = try identity()
        let initial = try GroupSetup.create(owner: owner)
        let next = try initial.changingMembers(initial.membership.statement.members + [GroupMember(identity: joiner)], owner: owner)
        XCTAssertThrowsError(try initial.membership.anchor.verify(initial.membership.statement, replacing: next.membership))
        var forged = next.membership.statement; forged.members.append(GroupMember(identity: attacker))
        XCTAssertThrowsError(try initial.membership.anchor.verify(forged, replacing: initial.membership))
        let different = try SignedMembership.sign(group: initial.membership.anchor.group, ownerID: owner.ownerID, ownerKey: owner.ownerSigningKey,
                                                   revision: next.membership.statement.revision, members: [GroupMember(identity: owner), GroupMember(identity: attacker)])
        XCTAssertThrowsError(try initial.membership.anchor.verify(different, replacing: next.membership))
        // A new randomized signature over unchanged state is not equivocation.
        let repeatStatement = try SignedMembership.sign(group: next.membership.anchor.group, ownerID: owner.ownerID, ownerKey: owner.ownerSigningKey,
                                                         revision: next.membership.statement.revision, members: next.membership.statement.members)
        XCTAssertEqual(try next.membership.anchor.verify(repeatStatement, replacing: next.membership).digest, next.membership.digest)
    }
    func testRevocationRotatesKeyAndRejectsOldSenderAndEpoch() throws {
        let owner = try identity(), joiner = try identity()
        let (approved, joined, _, _, _) = try paired(owner, joiner)
        let oldMessage = try SecureMessage.seal(payload: Data("合成文本".utf8), domain: .clipboard, groupKey: joined.key,
                                                signingKey: joiner.signingKey, trust: joined.membership.trust(for: .clipboard),
                                                sender: joiner.device, sequence: 1, issuedAt: 1000, expiresAt: 1600)
        let revoked = try approved.changingMembers([GroupMember(identity: owner)], owner: owner)
        XCTAssertFalse(revoked.key == approved.key)
        XCTAssertEqual(revoked.membership.statement.epoch, approved.membership.statement.epoch + 1)
        XCTAssertThrowsError(try SecureMessage.open(oldMessage, groupKey: revoked.key, trust: revoked.membership.trust(for: .clipboard), ledger: .init(), now: 1010))
        XCTAssertThrowsError(try WrappedGroupKey.seal(setup: revoked, for: joiner.device, context: Data(repeating: 0, count: 32), owner: owner, now: 1010, expiresAt: 1600))
        let forOwner = try WrappedGroupKey.seal(setup: revoked, for: owner.device, context: Data(repeating: 0, count: 32), owner: owner, now: 1010, expiresAt: 1600)
        XCTAssertTrue(try forOwner.package.openRotation(recipient: owner, current: approved.membership, now: 1011).key == revoked.key)
    }
    func testDomainPermissionsAreEnforcedFromVerifiedMemberState() throws {
        let owner = try identity(), joiner = try identity(), initial = try GroupSetup.create(owner: owner)
        let next = try initial.changingMembers([GroupMember(identity: owner), GroupMember(identity: joiner, permissions: .learning)], owner: owner)
        XCTAssertNotNil(next.membership.trust(for: .learning).members[joiner.device])
        XCTAssertNil(next.membership.trust(for: .clipboard).members[joiner.device])
        XCTAssertThrowsError(try SecureMessage.seal(payload: Data("合成文本".utf8), domain: .clipboard, groupKey: next.key,
                                                    signingKey: joiner.signingKey, trust: next.membership.trust(for: .clipboard), sender: joiner.device,
                                                    sequence: 1, issuedAt: 1000, expiresAt: 1600))
    }
}
