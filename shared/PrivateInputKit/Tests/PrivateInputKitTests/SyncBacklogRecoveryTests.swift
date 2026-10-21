import XCTest
import CryptoKit
import CSQLite
@testable import PrivateInputKit

/// Real encrypted stores, receipts, vaults and group keys. Only transport/relay
/// quota is synthetic; no production group or user text is read.
final class SyncBacklogRecoveryTests: XCTestCase {
    struct Peer { let root: URL; let vault: DeviceIdentityVault; let identity: DeviceIdentity; let store: SecureReplicaStore }
    var roots: [URL] = []
    let now: UInt64 = 1010
    let all = SyncConsent(learning: true, clipboard: true)
    override func tearDownWithError() throws { for root in roots { try FileManager.default.removeItem(at: root) } }
    func peer() throws -> Peer {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PrivateInput-Drain-" + UUID().uuidString)
        roots.append(root)
        let vault = try DeviceIdentityVault(store: SyntheticIdentityStore(), directory: root.appendingPathComponent("Identity"))
        let identity = try vault.create()
        return Peer(root: root, vault: vault, identity: identity, store: try SecureReplicaStore(directory: root.appendingPathComponent("Sync"), vault: vault))
    }
    func pair() throws -> (Peer, Peer, UUID) {
        let a = try peer(), b = try peer(), setup = try GroupSetup.create(owner: a.identity), group = setup.membership.anchor.group
        try a.store.initializeGroup(setup)
        let request = try PairRequest.create(identity: b.identity, now: 1000)
        let pending = try a.store.beginPairing(request, group: group, permissions: .all, now: 1001)
        let package = try a.store.finishPairing(session: request.session, confirmedCode: pending.code, now: 1003)
        try b.store.acceptPairing(package, challenge: pending.challenge, request: request, confirmedCode: pending.code, now: 1004)
        return (a, b, group)
    }
    final class Relay: RelaySyncTransport {
        var membershipValue: SignedMembership
        var package: WrappedGroupKey?
        var inbound: [Data] = []
        var calls: [String] = []
        var free = 0, outboundCost = 1
        var onPull: (() throws -> Void)?
        var onAck: ((UUID) throws -> Void)?
        var onPush: (() throws -> Void)?
        init(_ membership: SignedMembership) { membershipValue = membership }
        func membership(group: UUID, identity: DeviceIdentity, now: UInt64) async throws -> SignedMembership { calls.append("membership"); return membershipValue }
        func keyPackage(group: UUID, identity: DeviceIdentity, now: UInt64) async throws -> WrappedGroupKey {
            calls.append("key"); guard let package else { throw RelayClientError.rotationRequired }; return package
        }
        func pull(group: UUID, identity: DeviceIdentity, now: UInt64, domains: UInt8) async throws -> [Data] {
            calls.append("pull"); try onPull?(); return Array(inbound.prefix(2))
        }
        func acknowledge(group: UUID, identity: DeviceIdentity, events: [UUID], now: UInt64) async throws {
            calls.append("ack"); XCTAssertEqual(events.count, 1)
            for event in events {
                try onAck?(event)
                let before = inbound.count
                inbound.removeAll { (try? SecureEnvelope.decode($0).event) == event }
                free += before - inbound.count
            }
        }
        func push(_ wire: Data) async throws {
            calls.append("push"); try onPush?()
            guard free >= outboundCost else { throw RelayClientError.httpStatus(429) }
            free -= outboundCost
        }
    }
    func enqueue(_ peer: Peer, _ group: UUID, _ index: Int) throws -> Data {
        try peer.store.enqueue(Data("合成排空文本\(index)".utf8), domain: .clipboard, group: group, sharingEnabled: true, now: now).encoded()
    }
    func reopened(_ peer: Peer) throws -> SecureReplicaStore { try SecureReplicaStore(directory: peer.root.appendingPathComponent("Sync"), vault: peer.vault) }
    func run(_ peer: Peer, _ group: UUID, _ relay: Relay, gate: SyncConsentGate? = nil) async throws -> SyncPassResult {
        try await RelaySyncPass.run(group: group, store: peer.store, vault: peer.vault, client: relay, consent: all, now: now, authorization: gate)
    }
    func testFullRelayDrainsDurablyBeforeOfflineOutboxPush() async throws {
        let (a,b,group) = try pair(), relay = Relay(try a.store.group(group).membership.statement)
        relay.inbound = [try enqueue(a,group,1)]
        _ = try enqueue(b,group,2)
        relay.onAck = { event in
            let disk = try self.reopened(b)
            XCTAssertEqual(try disk.clipboard(group: group, now: self.now).map(\.id), [event])
            XCTAssertEqual(try disk.receive(relay.inbound[0], now: self.now, receivingEnabled: true), .duplicate)
        }
        let result = try await run(b,group,relay)
        XCTAssertEqual(result.received,1); XCTAssertEqual(result.submitted,1)
        XCTAssertEqual(relay.calls,["membership","pull","ack","push"])
        XCTAssertTrue(try b.store.pendingMessages(now: now).isEmpty)
    }
    func testQuotaAfterTwoReceivesRetainsOutboxAndNextBoundedPassProgresses() async throws {
        let (a,b,group) = try pair(), relay = Relay(try a.store.group(group).membership.statement)
        relay.inbound = try (1...4).map { try enqueue(a,group,$0) }
        let pending = try enqueue(b,group,5); relay.outboundCost = 3
        do { _ = try await run(b,group,relay); XCTFail("Expected quota until another bounded pass") }
        catch RelayClientError.httpStatus(let status) { XCTAssertEqual(status,429) }
        XCTAssertEqual(try reopened(b).clipboard(group: group, now: now).count,2)
        XCTAssertEqual(try b.store.pendingMessages(now: now),[pending]); XCTAssertEqual(relay.inbound.count,2)
        let result = try await run(b,group,relay)
        XCTAssertEqual(result.received,2); XCTAssertEqual(result.submitted,1)
        XCTAssertEqual(try reopened(b).clipboard(group: group, now: now).count,4)
        XCTAssertEqual(relay.calls.filter { $0 == "pull" }.count,2)
    }
    func testInvalidSignatureNeverAcknowledgedOrPushed() async throws {
        let (a,b,group) = try pair(), relay = Relay(try a.store.group(group).membership.statement)
        var object = try JSONSerialization.jsonObject(with: enqueue(a,group,1)) as! [String:Any]
        object["signature"] = Data(repeating:0,count:64).base64EncodedString()
        relay.inbound = [try JSONSerialization.data(withJSONObject:object)]; _ = try enqueue(b,group,2)
        do { _ = try await run(b,group,relay); XCTFail("Invalid signature accepted") } catch {}
        XCTAssertEqual(relay.calls,["membership","pull"])
        XCTAssertTrue(try b.store.clipboard(group: group, now: now).isEmpty)
        XCTAssertEqual(try b.store.pendingMessages(now: now).count,1)
    }
    func testFailedDurableTransactionNeverAcknowledgedAndRetryAppliesOnce() async throws {
        let (a,b,group) = try pair(), relay = Relay(try a.store.group(group).membership.statement)
        relay.inbound = [try enqueue(a,group,1)]
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(b.root.appendingPathComponent("Sync/replica-v1.sqlite").path,&db),SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db,"CREATE TRIGGER synthetic_failure BEFORE UPDATE ON groups BEGIN SELECT RAISE(ABORT,'synthetic'); END",nil,nil,nil),SQLITE_OK)
        do { _ = try await run(b,group,relay); XCTFail("Persistence failure acknowledged") } catch {}
        XCTAssertEqual(relay.calls,["membership","pull"])
        XCTAssertEqual(sqlite3_exec(db,"DROP TRIGGER synthetic_failure",nil,nil,nil),SQLITE_OK)
        XCTAssertTrue(try b.store.clipboard(group: group, now: now).isEmpty)
        let result = try await run(b,group,relay); XCTAssertEqual(result.received,1)
    }
    func testConsentRetiredAtPullReturnDoesNotReceiveAckOrPushEvenAfterReenable() async throws {
        for reenable in [false,true] {
            let (a,b,group) = try pair(), relay = Relay(try a.store.group(group).membership.statement), gate = SyncConsentGate(all)
            relay.inbound = [try enqueue(a,group,1)]; _ = try enqueue(b,group,2)
            relay.onPull = { try gate.update(.init(learning:false,clipboard:false)); if reenable { try gate.update(self.all) } }
            do { _ = try await run(b,group,relay,gate:gate); XCTFail("Retired consent lease accepted") }
            catch ReplicaStoreError.sharingDisabled {}
            XCTAssertEqual(relay.calls,["membership","pull"]); XCTAssertTrue(try b.store.clipboard(group:group,now:now).isEmpty)
        }
    }
    func testConsentRetiredDuringAckStopsNextReceiveAndOutbound() async throws {
        let (a,b,group) = try pair(), relay = Relay(try a.store.group(group).membership.statement), gate = SyncConsentGate(all)
        relay.inbound = [try enqueue(a,group,1), try enqueue(a,group,2)]; _ = try enqueue(b,group,3)
        relay.onAck = { _ in try gate.update(.init(learning:false,clipboard:false)) }
        do { _ = try await run(b,group,relay,gate:gate); XCTFail("Retired pass continued") } catch ReplicaStoreError.sharingDisabled {}
        XCTAssertEqual(relay.calls,["membership","pull","ack"])
        XCTAssertEqual(try b.store.clipboard(group:group,now:now).count,1)
        XCTAssertEqual(try b.store.pendingMessages(now:now).count,1)
    }
    func testLocalMembershipRotationAtPullReturnStopsOldEpochPass() async throws {
        let (a,b,group) = try pair(), relay = Relay(try a.store.group(group).membership.statement)
        relay.inbound = [try enqueue(a,group,1)]
        relay.onPull = { try b.store.applyRotation(a.store.rotationPackage(group:group,recipient:b.identity.device,now:self.now),now:self.now) }
        // Rotate the owner's membership only after taking the relay snapshot.
        try a.store.changeMembers(group:group,members:[GroupMember(identity:a.identity),GroupMember(identity:b.identity)])
        do { _ = try await run(b,group,relay); XCTFail("Old membership pass continued") } catch ReplicaStoreError.changedState {}
        XCTAssertEqual(relay.calls,["membership","pull"])
        XCTAssertTrue(try b.store.clipboard(group:group,now:now).isEmpty)
    }
    func testRemoteRotationRequiresAuthenticatedPackageBeforePullOrPush() async throws {
        let (a,b,group) = try pair()
        try a.store.changeMembers(group:group,members:[GroupMember(identity:a.identity),GroupMember(identity:b.identity)])
        let relay = Relay(try a.store.group(group).membership.statement); _ = try enqueue(b,group,2)
        do { _ = try await run(b,group,relay); XCTFail("Rotation bypassed key package") } catch RelayClientError.rotationRequired {}
        XCTAssertEqual(relay.calls,["membership","key"])
        XCTAssertEqual(try b.store.pendingMessages(now:now).count,1)
    }
    func testLostAckRetryRecognizesDurableReceiptAndAcksWithoutDuplicateApply() async throws {
        let (a,b,group) = try pair(), relay = Relay(try a.store.group(group).membership.statement)
        relay.inbound = [try enqueue(a,group,1)]; var first = true
        relay.onAck = { _ in if first { first = false; throw RelayClientError.httpStatus(503) } }
        do { _ = try await run(b,group,relay); XCTFail("Lost ACK expected") } catch RelayClientError.httpStatus {}
        XCTAssertEqual(try reopened(b).clipboard(group:group,now:now).count,1)
        let result = try await run(b,group,relay)
        XCTAssertEqual(result.received,0); XCTAssertTrue(relay.inbound.isEmpty)
        XCTAssertEqual(try reopened(b).clipboard(group:group,now:now).count,1)
    }
}
