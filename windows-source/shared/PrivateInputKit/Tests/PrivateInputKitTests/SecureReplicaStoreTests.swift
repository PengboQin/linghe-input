import XCTest
import CryptoKit
import CSQLite
@testable import PrivateInputKit

final class SecureReplicaStoreTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDownWithError() throws { for root in roots { try FileManager.default.removeItem(at: root) }; roots = [] }
    struct Peer {
        let root: URL
        let vault: DeviceIdentityVault
        let identity: DeviceIdentity
        let store: SecureReplicaStore
    }
    func peer() throws -> Peer {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PrivateInput-Replica-" + UUID().uuidString)
        roots.append(root)
        let vault = try DeviceIdentityVault(store: SyntheticIdentityStore(), directory: root.appendingPathComponent("Identity"))
        let identity = try vault.create()
        return Peer(root: root, vault: vault, identity: identity,
                    store: try SecureReplicaStore(directory: root.appendingPathComponent("Sync"), vault: vault))
    }
    func pair() throws -> (owner: Peer, joiner: Peer, group: UUID) {
        let a = try peer(), b = try peer(), setup = try GroupSetup.create(owner: a.identity)
        try a.store.initializeGroup(setup)
        let request = try PairRequest.create(identity: b.identity, now: 1000)
        let pending = try a.store.beginPairing(request, group: setup.membership.anchor.group, permissions: .all, now: 1001)
        let code = try DevicePairing.authenticationCode(pending.challenge, request: request, recipient: b.identity, now: 1002)
        XCTAssertEqual(code, pending.code)
        XCTAssertEqual(try a.store.group(setup.membership.anchor.group).membership.statement.members.count, 1)
        let package = try a.store.finishPairing(session: request.session, confirmedCode: code, now: 1003)
        try b.store.acceptPairing(package, challenge: pending.challenge, request: request, confirmedCode: code, now: 1004)
        return (a, b, setup.membership.anchor.group)
    }
    func sampleLearning(_ peer: Peer, text: String, count: UInt64) throws -> Data {
        var model = LearningModel(); try model.setDeviceCount(reading: "ni hao", text: text, device: peer.identity.device.uuidString, count: count)
        return try model.export()
    }
    func sqlite(_ peer: Peer, _ sql: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(peer.root.appendingPathComponent("Sync/replica-v1.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw ReplicaStoreError.corrupt }
    }
    func testTwoPeersConvergeWithOfflineLearningAndDuplicateDelivery() throws {
        let peers = try pair()
        let a = try peers.owner.store.enqueue(sampleLearning(peers.owner, text: "你好", count: 4), domain: .learning, group: peers.group, sharingEnabled: true, now: 1010)
        let b = try peers.joiner.store.enqueue(sampleLearning(peers.joiner, text: "拟好", count: 9), domain: .learning, group: peers.group, sharingEnabled: true, now: 1011)
        XCTAssertEqual(try peers.owner.store.receive(b.encoded(), now: 1012, receivingEnabled: true), .applied)
        XCTAssertEqual(try peers.joiner.store.receive(a.encoded(), now: 1012, receivingEnabled: true), .applied)
        XCTAssertEqual(try peers.owner.store.receive(b.encoded(), now: 1013, receivingEnabled: true), .duplicate)
        XCTAssertEqual(try peers.joiner.store.receive(a.encoded(), now: 1013, receivingEnabled: true), .duplicate)
        var left = LearningModel(), right = LearningModel()
        try left.merge(peers.owner.store.learningArchive(group: peers.group)); try right.merge(peers.joiner.store.learningArchive(group: peers.group))
        XCTAssertEqual(left.entries, right.entries)
        XCTAssertEqual(left.entries.values.first(where: { $0.text == "拟好" })?.frequency, 9)
        XCTAssertEqual(left.entries.values.first(where: { $0.text == "你好" })?.frequency, 4)
    }
    func testOutboxRestartReturnsOriginalWireAndExpiresBeforeSending() throws {
        let peers = try pair(), payload = Data("SHARE-ONLY-SYNTHETIC-私享文本".utf8)
        let first = try peers.owner.store.enqueue(payload, domain: .clipboard, group: peers.group, sharingEnabled: true, now: 1010)
        let original = try peers.owner.store.pendingMessages(now: 1011)
        let reopened = try SecureReplicaStore(directory: peers.owner.root.appendingPathComponent("Sync"), vault: peers.owner.vault)
        XCTAssertEqual(try reopened.pendingMessages(now: 1012), original)
        let second = try reopened.enqueue(payload, domain: .clipboard, group: peers.group, sharingEnabled: true, now: 1012)
        XCTAssertGreaterThan(second.sequence, first.sequence)
        try reopened.acknowledgeSent(first.event)
        XCTAssertEqual(try reopened.pendingMessages(now: 1013).count, 1)
        XCTAssertTrue(try reopened.pendingMessages(now: 1612).isEmpty)
    }
    func testDisabledSharingNeverQueuesOrReservesNonce() throws {
        let peer = try peer(), setup = try GroupSetup.create(owner: peer.identity)
        try peer.store.initializeGroup(setup)
        XCTAssertThrowsError(try peer.store.enqueue(Data("合成文本".utf8), domain: .clipboard, group: setup.membership.anchor.group, sharingEnabled: false, now: 1000))
        XCTAssertTrue(try peer.store.pendingMessages(now: 1001).isEmpty)
        XCTAssertEqual(try peer.vault.reserveSequence().sequence, 1)
    }
    func testPausedReceivingDoesNotDecryptOrAdvanceLedger() throws {
        let peers = try pair()
        let message = try peers.owner.store.enqueue(Data("合成暂停收件文本".utf8), domain: .clipboard, group: peers.group, sharingEnabled: true, now: 1010)
        XCTAssertThrowsError(try peers.joiner.store.receive(message.encoded(), now: 1011, receivingEnabled: false))
        XCTAssertTrue(try peers.joiner.store.clipboard(group: peers.group, now: 1011).isEmpty)
        XCTAssertEqual(try peers.joiner.store.receive(message.encoded(), now: 1012, receivingEnabled: true), .applied)
    }
    func testReceiptAndStateRollbackTogetherOnSQLiteFailure() throws {
        let peers = try pair()
        let message = try peers.owner.store.enqueue(Data("合成事务失败文本".utf8), domain: .clipboard, group: peers.group, sharingEnabled: true, now: 1010)
        try sqlite(peers.joiner, "CREATE TRIGGER synthetic_failure BEFORE UPDATE ON groups BEGIN SELECT RAISE(ABORT,'synthetic failure'); END")
        XCTAssertThrowsError(try peers.joiner.store.receive(message.encoded(), now: 1011, receivingEnabled: true))
        try sqlite(peers.joiner, "DROP TRIGGER synthetic_failure")
        XCTAssertTrue(try peers.joiner.store.clipboard(group: peers.group, now: 1012).isEmpty)
        XCTAssertEqual(try peers.joiner.store.receive(message.encoded(), now: 1013, receivingEnabled: true), .applied)
        let reopened = try SecureReplicaStore(directory: peers.joiner.root.appendingPathComponent("Sync"), vault: peers.joiner.vault)
        XCTAssertEqual(try reopened.receive(message.encoded(), now: 1014, receivingEnabled: true), .duplicate)
        XCTAssertEqual(try reopened.clipboard(group: peers.group, now: 1014).map(\.text), ["合成事务失败文本"])
    }
    func testPairingSurvivesRestartAndConsumedSessionCannotRejoin() throws {
        let a = try peer(), b = try peer(), initial = try GroupSetup.create(owner: a.identity), group = initial.membership.anchor.group
        try a.store.initializeGroup(initial)
        let request = try PairRequest.create(identity: b.identity, now: 1000)
        let pending = try a.store.beginPairing(request, group: group, permissions: .all, now: 1001)
        let reopened = try SecureReplicaStore(directory: a.root.appendingPathComponent("Sync"), vault: a.vault)
        let repeated = try reopened.beginPairing(request, group: group, permissions: .all, now: 1002)
        XCTAssertEqual(repeated.code, pending.code)
        XCTAssertEqual(try repeated.challenge.template.header(), try pending.challenge.template.header())
        XCTAssertThrowsError(try reopened.finishPairing(session: request.session, confirmedCode: "wrong", now: 1003))
        XCTAssertEqual(try reopened.group(group).membership.statement.members.count, 1)
        let package = try reopened.finishPairing(session: request.session, confirmedCode: pending.code, now: 1004)
        let again = try reopened.finishPairing(session: request.session, confirmedCode: pending.code, now: 1005)
        XCTAssertEqual(package.sealedKey, again.sealedKey)
        try b.store.acceptPairing(package, challenge: pending.challenge, request: request, confirmedCode: pending.code, now: 1005)
        let second = try SecureReplicaStore(directory: b.root.appendingPathComponent("Sync"), vault: b.vault)
        XCTAssertThrowsError(try second.acceptPairing(package, challenge: pending.challenge, request: request, confirmedCode: pending.code, now: 1006))
    }
    func testClipboardExpiresAndRevocationRemovesOldSenderCacheAndOutbox() throws {
        let peers = try pair()
        let message = try peers.joiner.store.enqueue(Data("合成旧设备文本".utf8), domain: .clipboard, group: peers.group, sharingEnabled: true, now: 1010)
        _ = try peers.owner.store.receive(message.encoded(), now: 1011, receivingEnabled: true)
        XCTAssertEqual(try peers.owner.store.clipboard(group: peers.group, now: 1012).count, 1)
        _ = try peers.owner.store.enqueue(Data("合成待发文本".utf8), domain: .clipboard, group: peers.group, sharingEnabled: true, now: 1012)
        try peers.owner.store.changeMembers(group: peers.group, members: [GroupMember(identity: peers.owner.identity)])
        XCTAssertTrue(try peers.owner.store.clipboard(group: peers.group, now: 1013).isEmpty)
        XCTAssertTrue(try peers.owner.store.pendingMessages(now: 1013).isEmpty)
        XCTAssertThrowsError(try peers.owner.store.receive(message.encoded(), now: 1013, receivingEnabled: true))
        XCTAssertThrowsError(try peers.owner.store.rotationPackage(group: peers.group, recipient: peers.joiner.identity.device, now: 1013))
        // A separate still-trusted pair proves TTL removes received local text.
        let other = try pair(), clip = try other.owner.store.enqueue(Data("合成过期文本".utf8), domain: .clipboard, group: other.group, sharingEnabled: true, now: 1010)
        _ = try other.joiner.store.receive(clip.encoded(), now: 1011, receivingEnabled: true)
        XCTAssertTrue(try other.joiner.store.clipboard(group: other.group, now: 1610).isEmpty)
        XCTAssertThrowsError(try other.joiner.store.receive(clip.encoded(), now: 1610, receivingEnabled: true))
    }
    func testDatabaseAndWALContainNoSyntheticPlaintextOrGroupKey() throws {
        let peers = try pair(), text = "SHARE-ONLY-SYNTHETIC-私享文本-🔒"
        let message = try peers.owner.store.enqueue(Data(text.utf8), domain: .clipboard, group: peers.group, sharingEnabled: true, now: 1010)
        _ = try peers.joiner.store.receive(message.encoded(), now: 1011, receivingEnabled: true)
        let master = try peers.joiner.store.group(peers.group).key.withUnsafeBytes { Data($0) }
        let directory = peers.joiner.root.appendingPathComponent("Sync")
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let bytes = try Data(contentsOf: file)
            XCTAssertNil(bytes.range(of: Data(text.utf8)))
            XCTAssertNil(bytes.range(of: master)); XCTAssertNil(bytes.range(of: Data(master.base64EncodedString().utf8)))
        }
        try sqlite(peers.joiner, "UPDATE groups SET sealed=zeroblob(128)")
        XCTAssertThrowsError(try peers.joiner.store.group(peers.group))
        // Corruption is reported; no schema reset or new identity is performed.
    }
    func testEncryptedPeerLearningChangesRealReceivingEngine() throws {
        #if os(macOS)
        guard let driver = ProcessInfo.processInfo.environment["PRIVATE_INPUT_ENGINE_DRIVER"], let resources = ProcessInfo.processInfo.environment["PRIVATE_INPUT_RIME_RESOURCES"] else { throw XCTSkip("Run scripts/test_rime_bridge.sh for real engine integration") }
        let peers = try pair(), learned = try sampleLearning(peers.owner, text: "拟好", count: 12)
        let message = try peers.owner.store.enqueue(learned, domain: .learning, group: peers.group, sharingEnabled: true, now: 1010)
        _ = try peers.joiner.store.receive(message.encoded(), now: 1011, receivingEnabled: true)
        var model = LearningModel(); try model.merge(peers.joiner.store.learningArchive(group: peers.group))
        let tsv = peers.joiner.root.appendingPathComponent("synthetic-import.tsv")
        try RimeLearningFormat.importTSV(from: model).write(to: tsv)
        let process = Process(); process.executableURL = URL(fileURLWithPath: driver)
        process.arguments = [resources, peers.joiner.root.appendingPathComponent("Engine").path, "import-rank", tsv.path]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run(); let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "拟好")
        #endif
    }
}
