import XCTest
import CryptoKit
@testable import PrivateInputKit

final class RelayClientTests: XCTestCase {
    func testEndpointRequiresTLSAndAllowsExplicitLoopbackOnly() throws {
        XCTAssertNoThrow(try RelayClient(endpoint: URL(string: "https://192.0.2.1")!))
        XCTAssertThrowsError(try RelayClient(endpoint: URL(string: "http://127.0.0.1:8028")!))
        XCTAssertNoThrow(try RelayClient(endpoint: URL(string: "http://127.0.0.1:8028")!, allowLoopbackHTTP: true))
        XCTAssertThrowsError(try RelayClient(endpoint: URL(string: "http://192.0.2.1:8028")!, allowLoopbackHTTP: true))
        XCTAssertThrowsError(try RelayClient(endpoint: URL(string: "https://user:password@example.invalid")!))
        XCTAssertThrowsError(try RelayClient(endpoint: URL(string: "https://example.invalid/?token=invalid")!))
    }
    #if os(macOS)
    final class PausingTransport: RelaySyncTransport {
        enum Boundary { case pull, push }
        let client: RelayClient
        let gate: SyncConsentGate
        let boundary: Boundary
        let reenable: Bool
        var acknowledgements = 0
        init(client: RelayClient, gate: SyncConsentGate, boundary: Boundary, reenable: Bool = false) {
            self.client = client; self.gate = gate; self.boundary = boundary; self.reenable = reenable
        }
        func pause() throws {
            try gate.update(.init(learning: false, clipboard: false))
            if reenable { try gate.update(.init(learning: true, clipboard: true)) }
        }
        func membership(group: UUID, identity: DeviceIdentity, now: UInt64) async throws -> SignedMembership {
            try await client.membership(group: group, identity: identity, now: now)
        }
        func keyPackage(group: UUID, identity: DeviceIdentity, now: UInt64) async throws -> WrappedGroupKey {
            try await client.keyPackage(group: group, identity: identity, now: now)
        }
        func push(_ wire: Data) async throws {
            try await client.push(wire)
            if boundary == .push { try pause() }
        }
        func pull(group: UUID, identity: DeviceIdentity, now: UInt64, domains: UInt8) async throws -> [Data] {
            let wire = try await client.pull(group: group, identity: identity, now: now, domains: domains)
            if boundary == .pull { try pause() }
            return wire
        }
        func acknowledge(group: UUID, identity: DeviceIdentity, events: [UUID], now: UInt64) async throws {
            acknowledgements += 1
            try await client.acknowledge(group: group, identity: identity, events: events, now: now)
        }
    }
    struct Peer {
        let root: URL
        let vault: DeviceIdentityVault
        let identity: DeviceIdentity
        let store: SecureReplicaStore
    }
    func peer(_ directory: URL) throws -> Peer {
        let vault = try DeviceIdentityVault(store: SyntheticIdentityStore(), directory: directory.appendingPathComponent("Identity"))
        let identity = try vault.create()
        return Peer(root: directory, vault: vault, identity: identity,
                    store: try SecureReplicaStore(directory: directory.appendingPathComponent("Sync"), vault: vault))
    }
    func server(_ root: URL) throws -> (Process, RelayClient) {
        guard let python = ProcessInfo.processInfo.environment["PRIVATE_INPUT_RELAY_PYTHON"],
              let script = ProcessInfo.processInfo.environment["PRIVATE_INPUT_RELAY_SCRIPT"] else { throw XCTSkip("Run scripts/test_network_sync.sh for the real loopback server process") }
        let process = Process(); process.executableURL = URL(fileURLWithPath: python)
        let ready = root.appendingPathComponent("ready.json")
        process.arguments = [script, "--database", root.appendingPathComponent("relay.sqlite").path, "--port", "0", "--ready-file", ready.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        for _ in 0..<400 {
            if !process.isRunning { XCTFail("Owned relay process exited before readiness"); throw RelayClientError.invalidResponse }
            if FileManager.default.fileExists(atPath: ready.path) {
                struct Ready: Decodable { let loopback_port: Int }
                let port = try JSONDecoder().decode(Ready.self, from: Data(contentsOf: ready)).loopback_port
                return (process, try RelayClient(endpoint: URL(string: "http://127.0.0.1:\(port)")!, allowLoopbackHTTP: true))
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.terminate(); process.waitUntilExit(); throw RelayClientError.invalidResponse
    }
    func setup(_ root: URL, _ client: RelayClient, now: UInt64) async throws -> (Peer, Peer, UUID) {
        let a = try peer(root.appendingPathComponent("A")), b = try peer(root.appendingPathComponent("B"))
        let initial = try GroupSetup.create(owner: a.identity), group = initial.membership.anchor.group
        try a.store.initializeGroup(initial); try await client.register(initial.membership)
        let request = try PairRequest.create(identity: b.identity, now: now)
        try await client.submitPair(request, group: group, identity: b.identity, now: now)
        let requests = try await client.pendingPairs(group: group, owner: a.identity, now: now)
        XCTAssertEqual(requests.count, 1)
        let pending = try a.store.beginPairing(requests[0], group: group, permissions: .all, now: now)
        try await client.publishChallenge(pending.challenge, session: request.session)
        let challenge = try await client.pairChallenge(group: group, session: request.session, identity: b.identity, now: now)
        XCTAssertEqual(challenge.anchor, initial.membership.anchor)
        let code = try DevicePairing.authenticationCode(challenge, request: request, recipient: b.identity, now: now)
        XCTAssertEqual(code, pending.code)
        let package = try a.store.finishPairing(session: request.session, confirmedCode: code, now: now)
        try await client.publishMembership(a.store.group(group).membership)
        try await client.publishKey(package)
        let fetched = try await client.keyPackage(group: group, identity: b.identity, now: now)
        try b.store.acceptPairing(fetched, challenge: challenge, request: request, confirmedCode: code, now: now)
        return (a, b, group)
    }
    func testRealSwiftClientsExchangeEncryptedLearningAndClipboardThroughPythonHTTP() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PrivateInput-Network-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (process, client) = try server(root)
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let now = UInt64(Date().timeIntervalSince1970), (a, b, group) = try await setup(root, client, now: now)
        var learned = LearningModel(); try learned.setDeviceCount(reading: "ni hao", text: "拟好", device: a.identity.device.uuidString, count: 12)
        let learning = try a.store.enqueue(learned.export(), domain: .learning, group: group, sharingEnabled: true, now: now)
        let clip = "合成真实HTTP共享文本 🔒"
        _ = try a.store.enqueue(Data(clip.utf8), domain: .clipboard, group: group, sharingEnabled: true, now: now)
        let all = SyncConsent(learning: true, clipboard: true)
        let sent = try await RelaySyncPass.run(group: group, store: a.store, vault: a.vault, client: client, consent: all, now: now)
        XCTAssertEqual(sent.submitted, 2)
        let received = try await RelaySyncPass.run(group: group, store: b.store, vault: b.vault, client: client, consent: all, now: now)
        XCTAssertEqual(received.received, 2)
        XCTAssertEqual(try b.store.clipboard(group: group, now: now).map(\.text), [clip])
        var imported = LearningModel(); try imported.merge(b.store.learningArchive(group: group))
        XCTAssertEqual(imported.entries.values.first?.frequency, 12)
        let reopened = try SecureReplicaStore(directory: b.root.appendingPathComponent("Sync"), vault: b.vault)
        try await client.push(learning.encoded()) // Lost producer ack retry after receiver ack.
        let repeated = try await client.pull(group: group, identity: b.identity, now: now)
        XCTAssertEqual(repeated.count, 0)
        XCTAssertEqual(try reopened.clipboard(group: group, now: now).count, 1)
        XCTAssertEqual(try a.store.pendingMessages(now: now).count, 0)
        if let driver = ProcessInfo.processInfo.environment["PRIVATE_INPUT_ENGINE_DRIVER"], let resources = ProcessInfo.processInfo.environment["PRIVATE_INPUT_RIME_RESOURCES"] {
            let file = root.appendingPathComponent("received.tsv")
            try RimeLearningFormat.importTSV(from: imported).write(to: file)
            let engine = Process(); engine.executableURL = URL(fileURLWithPath: driver)
            engine.arguments = [resources, root.appendingPathComponent("ReceiverEngine").path, "import-rank", file.path]
            let pipe = Pipe(); engine.standardOutput = pipe; engine.standardError = pipe
            try engine.run(); let output = pipe.fileHandleForReading.readDataToEndOfFile(); engine.waitUntilExit()
            XCTAssertEqual(engine.terminationStatus, 0)
            XCTAssertEqual(String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "拟好")
        } else { XCTFail("Network integration must include the actual receiving engine fixture") }
        process.terminate(); process.waitUntilExit()
        let publicFixture = Data(clip.utf8), key = try a.store.group(group).key.withUnsafeBytes { Data($0) }
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where file.lastPathComponent.hasPrefix("relay.sqlite") {
            let bytes = try Data(contentsOf: file)
            XCTAssertNil(bytes.range(of: publicFixture)); XCTAssertNil(bytes.range(of: key))
        }
    }
    func testPausedClipboardCannotBlockLearningBehindItInServerQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PrivateInput-Domain-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let (process, client) = try server(root); defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let now = UInt64(Date().timeIntervalSince1970), (a, b, group) = try await setup(root, client, now: now)
        for index in 0..<3 { _ = try a.store.enqueue(Data("合成暂停文本\(index)".utf8), domain: .clipboard, group: group, sharingEnabled: true, now: now) }
        var model = LearningModel(); try model.record(reading: "ni hao", text: "拟好", device: a.identity.device.uuidString)
        _ = try a.store.enqueue(model.export(), domain: .learning, group: group, sharingEnabled: true, now: now)
        _ = try await RelaySyncPass.run(group: group, store: a.store, vault: a.vault, client: client, consent: .init(learning: true, clipboard: true), now: now)
        let pass = try await RelaySyncPass.run(group: group, store: b.store, vault: b.vault, client: client, consent: .init(learning: true, clipboard: false), now: now)
        XCTAssertEqual(pass.received, 1); XCTAssertTrue(try b.store.clipboard(group: group, now: now).isEmpty)
        let resumed = try await RelaySyncPass.run(group: group, store: b.store, vault: b.vault, client: client, consent: .init(learning: false, clipboard: true), now: now)
        XCTAssertEqual(resumed.received, 2)
    }
    func testPauseAtPullReturnPreventsApplyAndAckEvenAfterReenable() async throws {
        for reenable in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("PrivateInput-PausePull-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let (process, client) = try server(root)
            defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
            let now = UInt64(Date().timeIntervalSince1970), (a, b, group) = try await setup(root, client, now: now)
            var model = LearningModel(); try model.record(reading: "ni hao", text: "拟好", device: a.identity.device.uuidString)
            _ = try a.store.enqueue(model.export(), domain: .learning, group: group, sharingEnabled: true, now: now)
            _ = try a.store.enqueue(Data("合成在途暂停文本".utf8), domain: .clipboard, group: group, sharingEnabled: true, now: now)
            let all = SyncConsent(learning: true, clipboard: true)
            _ = try await RelaySyncPass.run(group: group, store: a.store, vault: a.vault, client: client, consent: all, now: now)
            let gate = SyncConsentGate(all), transport = PausingTransport(client: client, gate: gate, boundary: .pull, reenable: reenable)
            do {
                _ = try await RelaySyncPass.run(group: group, store: b.store, vault: b.vault, client: transport, consent: all, now: now, authorization: gate)
                XCTFail("A retired pass applied returned ciphertext after pause")
            } catch ReplicaStoreError.sharingDisabled {}
            XCTAssertEqual(transport.acknowledgements, 0)
            XCTAssertTrue(try b.store.clipboard(group: group, now: now).isEmpty)
            var retained = LearningModel(); try retained.merge(b.store.learningArchive(group: group))
            XCTAssertTrue(retained.entries.isEmpty)
            // Ciphertext stays pending at the relay; only a new authorized
            // pass can decrypt/apply it, without resetting identity or data.
            try gate.update(all)
            let resumed = try await RelaySyncPass.run(group: group, store: b.store, vault: b.vault, client: client, consent: all, now: now, authorization: gate)
            XCTAssertEqual(resumed.received, 2)
            XCTAssertEqual(try b.store.clipboard(group: group, now: now).map(\.text), ["合成在途暂停文本"])
        }
    }
    func testPauseAtPushReturnRetainsQueueAndRetryDoesNotDuplicate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PrivateInput-PausePush-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (process, client) = try server(root)
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let now = UInt64(Date().timeIntervalSince1970), (a, b, group) = try await setup(root, client, now: now)
        _ = try a.store.enqueue(Data("合成已发送响应暂停".utf8), domain: .clipboard, group: group, sharingEnabled: true, now: now)
        let all = SyncConsent(learning: true, clipboard: true), gate = SyncConsentGate(all)
        let transport = PausingTransport(client: client, gate: gate, boundary: .push)
        do {
            _ = try await RelaySyncPass.run(group: group, store: a.store, vault: a.vault, client: transport, consent: all, now: now, authorization: gate)
            XCTFail("A paused sender advanced its local queue")
        } catch ReplicaStoreError.sharingDisabled {}
        XCTAssertEqual(try a.store.pendingMessages(now: now).count, 1)
        try gate.update(all)
        let retry = try await RelaySyncPass.run(group: group, store: a.store, vault: a.vault, client: client, consent: all, now: now, authorization: gate)
        XCTAssertEqual(retry.submitted, 1)
        let received = try await RelaySyncPass.run(group: group, store: b.store, vault: b.vault, client: client, consent: all, now: now)
        XCTAssertEqual(received.received, 1)
        XCTAssertEqual(try b.store.clipboard(group: group, now: now).count, 1)
    }
    func testNewMemberReceivesNetworkGrantAndOfflinePeerRotatesWithoutLosingLearning() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PrivateInput-Rotation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let (process, client) = try server(root); defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let now = UInt64(Date().timeIntervalSince1970), (a, b, group) = try await setup(root, client, now: now)
        var offline = LearningModel(); try offline.setDeviceCount(reading: "ni hao", text: "你好", device: b.identity.device.uuidString, count: 3)
        _ = try b.store.enqueue(offline.export(), domain: .learning, group: group, sharingEnabled: true, now: now)
        let c = try peer(root.appendingPathComponent("C")), request = try PairRequest.create(identity: c.identity, now: now)
        let challenge = try a.store.beginPairing(request, group: group, permissions: .all, now: now)
        let code = try DevicePairing.authenticationCode(challenge.challenge, request: request, recipient: c.identity, now: now)
        XCTAssertEqual(code, challenge.code)
        let grant = try a.store.finishPairing(session: request.session, confirmedCode: code, now: now)
        try await client.publishMembership(a.store.group(group).membership)
        try await client.publishKey(grant)
        let fetched = try await client.keyPackage(group: group, identity: c.identity, now: now)
        try c.store.acceptPairing(fetched, challenge: challenge.challenge, request: request, confirmedCode: code, now: now)
        let all = SyncConsent(learning: true, clipboard: true)
        do {
            _ = try await RelaySyncPass.run(group: group, store: b.store, vault: b.vault, client: client, consent: all, now: now)
            XCTFail("A member must not update state without its authenticated epoch key")
        } catch RelayClientError.httpStatus(let status) { XCTAssertEqual(status, 404) }
        XCTAssertEqual(try b.store.group(group).membership.statement.epoch, 2)
        try await client.publishKey(a.store.rotationPackage(group: group, recipient: b.identity.device, now: now))
        let resumed = try await RelaySyncPass.run(group: group, store: b.store, vault: b.vault, client: client, consent: all, now: now)
        XCTAssertEqual(resumed.submitted, 1)
        XCTAssertEqual(try b.store.group(group).membership.statement.epoch, 3)
        XCTAssertTrue(try a.store.group(group).key == b.store.group(group).key)
        _ = try await RelaySyncPass.run(group: group, store: a.store, vault: a.vault, client: client, consent: all, now: now)
        var received = LearningModel(); try received.merge(a.store.learningArchive(group: group))
        XCTAssertEqual(received.entries.values.first?.counts[b.identity.device.uuidString], 3)
        try a.store.changeMembers(group: group, members: [GroupMember(identity: a.identity), GroupMember(identity: b.identity)])
        try await client.publishMembership(a.store.group(group).membership)
        do { _ = try await client.keyPackage(group: group, identity: c.identity, now: now); XCTFail("Revoked device still has relay access") }
        catch RelayClientError.httpStatus(let status) { XCTAssertEqual(status, 403) }
    }
    func testEncryptedExplicitWordAndPhraseOfflineMergeAndDeleteOverHTTP() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let (process,client)=try server(root);defer { process.terminate();process.waitUntilExit() }
        let now=UInt64(Date().timeIntervalSince1970),all=SyncConsent(learning:true,clipboard:true)
        let (a,b,group)=try await setup(root,client,now:now)
        let leftStore=PersonalLexiconStore(directory:a.root.appendingPathComponent("Personal"))
        let rightStore=PersonalLexiconStore(directory:b.root.appendingPathComponent("Personal"))
        var left=PersonalLexicon(),right=PersonalLexicon()
        let word=PersonalLexicon.Entry(kind:.word,text:"合成同步词",trigger:"he cheng tong bu ci")
        let phrase=PersonalLexicon.Entry(kind:.phrase,text:"合成同步短语\n第二行",trigger:"tbdy")
        try left.upsert(word);try right.upsert(phrase);try leftStore.save(left);try rightStore.save(right)
        func queue(_ peer:Peer,_ personal:PersonalLexiconStore) throws {
            var archive=LearningModel();try archive.mergePersonalLexicon(personal.syncSnapshot())
            _ = try peer.store.enqueue(archive.export(),domain:.learning,group:group,sharingEnabled:true,now:now)
        }
        try queue(a,leftStore);try queue(b,rightStore)
        for _ in 0..<2 {
            _ = try await RelaySyncPass.run(group:group,store:a.store,vault:a.vault,client:client,consent:all,now:now)
            _ = try await RelaySyncPass.run(group:group,store:b.store,vault:b.vault,client:client,consent:all,now:now)
        }
        var receivedA=LearningModel(),receivedB=LearningModel()
        try receivedA.merge(a.store.learningArchive(group:group));try receivedB.merge(b.store.learningArchive(group:group))
        XCTAssertEqual(receivedA.personalLexicon,receivedB.personalLexicon)
        XCTAssertEqual(try XCTUnwrap(receivedB.personalLexicon).materialized().entries.count,2)
        _ = try leftStore.mergeSynchronized(XCTUnwrap(receivedA.personalLexicon))
        _ = try rightStore.mergeSynchronized(XCTUnwrap(receivedB.personalLexicon))
        let stale=try rightStore.syncSnapshot()
        var deleted=try leftStore.load();deleted.remove(id:word.id);try leftStore.save(deleted)
        try queue(a,leftStore)
        _ = try await RelaySyncPass.run(group:group,store:a.store,vault:a.vault,client:client,consent:all,now:now)
        _ = try await RelaySyncPass.run(group:group,store:b.store,vault:b.vault,client:client,consent:all,now:now)
        var final=LearningModel();try final.merge(b.store.learningArchive(group:group))
        var merged=try XCTUnwrap(final.personalLexicon);try merged.merge(stale)
        XCTAssertEqual(try merged.materialized().entries.map(\.id),[phrase.id])
        // Relay database stores encrypted envelopes, never the synthetic phrase.
        let bytes=try Data(contentsOf:root.appendingPathComponent("relay.sqlite"))
        XCTAssertNil(bytes.range(of:Data(phrase.text.utf8)))
    }
    #endif
}
