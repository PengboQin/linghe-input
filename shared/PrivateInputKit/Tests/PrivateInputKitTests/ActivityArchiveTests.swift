import XCTest
import CryptoKit
@testable import PrivateInputKit

private actor ActivityFixtureTransport: ActivityArchiveTransport {
    let group: UUID
    let device: UUID
    let version: UInt64
    var revision: UInt64 = 7
    var providers = ["ime.commit.v1", "clipboard.observed.v1"]
    var enabled = true
    var wrongACK = false
    var failIngest = false
    var suspendIngest = false
    var ingestStarted = false
    var operations: [ActivityOperation] = []
    init(group: UUID, device: UUID, version: UInt64 = 1) { self.group = group; self.device = device; self.version = version }
    func set(wrongACK: Bool = false, fail: Bool = false, suspended: Bool = false, enabled: Bool = true) {
        self.wrongACK = wrongACK; failIngest = fail; suspendIngest = suspended; self.enabled = enabled
    }
    func setRevision(_ revision: UInt64) { self.revision = revision }
    func setProviders(_ providers: [String]) { self.providers = providers }
    func send(_ request: SignedActivityRequest) async throws -> Data {
        operations.append(request.operation)
        XCTAssertEqual(request.group, group); XCTAssertEqual(request.sender, device)
        let result: [String: Any]
        switch request.operation {
        case .status:
            result = ["group": group.uuidString, "device": device.uuidString, "enabled": enabled,
                      "policy_version": 1, "membership_revision": revision,
                      "consent": ["version": version, "enabled": true, "providers": providers, "readers": [device.uuidString]],
                      "limits": ["max_batch_events": 128, "max_event_bytes": 262144, "max_body_bytes": 524288, "retention_days": 30, "max_group_bytes": 104857600]]
        case .ingest:
            ingestStarted = true
            if suspendIngest { try await Task.sleep(nanoseconds: 5_000_000_000) }
            if failIngest { throw ActivityError.httpStatus(503) }
            let batch = try JSONDecoder().decode(ActivityBatch.self, from: request.body)
            result = ["batch_id": batch.batchID.uuidString,
                      "accepted_event_ids": wrongACK ? [UUID().uuidString] : batch.events.map { $0.eventID.uuidString },
                      "duplicate_event_ids": [], "received_ranges": [], "server_received_at": "2026-10-18T00:00:00.000Z", "high_watermark": batch.events.count]
        default: throw ActivityError.invalidResponse
        }
        return try JSONSerialization.data(withJSONObject: ["version": 1, "operation": Int(request.operation.rawValue), "result": result])
    }
}

final class ActivityArchiveTests: XCTestCase {
    private var directories: [URL] = []
    override func tearDownWithError() throws { for url in directories { try? FileManager.default.removeItem(at: url) }; directories = [] }
    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PrivateInput-Activity-Synthetic-" + UUID().uuidString)
        directories.append(url); return url
    }
    private func identity() throws -> DeviceIdentity {
        try DeviceIdentityVault(store: SyntheticIdentityStore(), directory: directory()).create()
    }
    private func queue(group: UUID = UUID(), device: UUID = UUID()) throws -> ActivityLocalEventQueue {
        try ActivityLocalEventQueue(file: directory().appendingPathComponent("activity.sqlite"), group: group, device: device)
    }
    private func config(consent: UInt64 = 1, events: Int = 20000) -> ActivityConfiguration {
        ActivityConfiguration(enabled: true, endpoint: URL(string: "https://archive.example.invalid")!,
                              providers: ["ime.commit.v1", "clipboard.observed.v1"], consentVersion: consent, maxQueueEvents: events)
    }
    private func draft(_ text: String = "合成测试文本", clipboard: String? = nil) -> ActivityEventDraft {
        ActivityEventDraft(providerID: clipboard == nil ? "ime.commit.v1" : "clipboard.observed.v1",
                           eventType: clipboard == nil ? .inputCommit : .clipboardObserved, text: text,
                           observedAt: Date(timeIntervalSince1970: 1792281600), timeZone: TimeZone(identifier: "Asia/Shanghai")!,
                           sourceKind: clipboard == nil ? "ime" : "clipboard", commitConfirmation: clipboard == nil ? .insertRequested : .notApplicable,
                           observationID: clipboard)
    }
    func testDefaultsOffAndSafetyExcludedProvidersDoNotPersistText() throws {
        let q = try queue()
        XCTAssertFalse(try q.configuration().enabled)
        XCTAssertThrowsError(try q.authorizationLease())
        let lease = try q.configure(config())
        for safety: ActivityFieldSafety in [.unknown, .secure] {
            XCTAssertThrowsError(try q.capture(draft(), safety: safety, lease: lease)) { XCTAssertEqual($0 as? ActivityError, .unsafeField) }
        }
        var d = draft(); d.providerID = "unknown.provider"
        XCTAssertThrowsError(try q.capture(d, safety: .safe, lease: lease))
        var excluded = config(); excluded.excludedSourceApps = ["synthetic.secret.editor"]
        let excludedLease = try q.configure(excluded); d = draft(); d.sourceApp = "synthetic.secret.editor"
        XCTAssertThrowsError(try q.capture(d, safety: .safe, lease: excludedLease)) { XCTAssertEqual($0 as? ActivityError, .excludedSource) }
        XCTAssertEqual(try q.status().payloadBytes, 0); XCTAssertEqual(try q.status().lastSequence, 0)
    }
    func testUnicodeSequenceAndReopenAreDurableWithoutTextNormalization() throws {
        let group = UUID(), device = UUID(), path = directory().appendingPathComponent("events.sqlite")
        let q = try ActivityLocalEventQueue(file: path, group: group, device: device), lease = try q.configure(config())
        let text = "中英e\u{301}é 👨‍👩‍👧‍👦\n\"quote\"\u{0000}尾"
        let first = try q.capture(draft(text), safety: .safe, lease: lease)
        let reopened = try ActivityLocalEventQueue(file: path, group: group, device: device)
        let second = try reopened.capture(draft("第二次"), safety: .safe, lease: reopened.authorizationLease())
        XCTAssertEqual(first.deviceSeq, 1); XCTAssertEqual(second.deviceSeq, 2)
        XCTAssertEqual(first.installationID, second.installationID)
        let batch = try XCTUnwrap(reopened.nextBatch(lease: reopened.authorizationLease(), now: 1000))
        XCTAssertEqual(Array(batch.events[0].content.text.utf8), Array(text.utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: first.encoded()) as? [String: Any])
        XCTAssertEqual(json["device_seq"] as? Int, 1); XCTAssertEqual(json["commit_confirmation"] as? String, "insert_requested")
        XCTAssertEqual(json["utc_offset_minutes"] as? Int, 480)
        XCTAssertNil(json["server_received_at"])
        XCTAssertThrowsError(try ActivityLocalEventQueue(file: path, group: UUID(), device: device))
    }
    func testDisablePauseAndReenableFenceOldObservationAndPendingQueue() throws {
        let q = try queue(), old = try q.configure(config())
        _ = try q.capture(draft("旧队列"), safety: .safe, lease: old)
        var paused = config(); paused.paused = true
        _ = try q.configure(paused)
        XCTAssertThrowsError(try q.capture(draft("已暂停不得记录"), safety: .safe, lease: old))
        let fresh = try q.configure(config())
        XCTAssertNotEqual(old.generation, fresh.generation)
        XCTAssertThrowsError(try q.capture(draft("过期异步任务"), safety: .safe, lease: old))
        XCTAssertNil(try q.nextBatch(lease: fresh, now: 1000))
        _ = try q.capture(draft("新授权"), safety: .safe, lease: fresh)
        XCTAssertEqual(try q.status().held, 1)
        XCTAssertEqual(try XCTUnwrap(q.nextBatch(lease: fresh, now: 1000)).events.map(\.content.text), ["新授权"])
    }
    func testQuotaAndOversizeFailuresRollbackSequenceWithoutTruncation() throws {
        let q = try queue(), lease = try q.configure(config(events: 1))
        XCTAssertThrowsError(try q.capture(draft(String(repeating: "甲", count: 90000)), safety: .safe, lease: lease))
        XCTAssertEqual(try q.status().lastSequence, 0)
        _ = try q.capture(draft(), safety: .safe, lease: lease)
        XCTAssertThrowsError(try q.capture(draft("必须完整而非截断"), safety: .safe, lease: lease)) { XCTAssertEqual($0 as? ActivityError, .quotaExceeded) }
        XCTAssertEqual(try q.status().lastSequence, 1); XCTAssertEqual(try q.status().pending, 1)
    }
    func testClipboardVersionDedupDoesNotDedupSameContentAgain() throws {
        let q = try queue(), lease = try q.configure(config())
        let a = try q.capture(draft("一样的文字", clipboard: "boot-a:4"), safety: .safe, lease: lease)
        let retry = try q.capture(draft("一样的文字", clipboard: "boot-a:4"), safety: .safe, lease: lease)
        let b = try q.capture(draft("一样的文字", clipboard: "boot-a:5"), safety: .safe, lease: lease)
        XCTAssertEqual(a.eventID, retry.eventID); XCTAssertNotEqual(a.eventID, b.eventID)
        XCTAssertEqual(try q.status().pending, 2)
        XCTAssertThrowsError(try q.capture(draft("冲突内容", clipboard: "boot-a:4"), safety: .safe, lease: lease))
        let batch = try XCTUnwrap(q.nextBatch(lease: lease, now: 1000))
        try q.acknowledge(batch, eventIDs: Set(batch.events.map(\.eventID)), lease: lease, now: 1000)
        try q.pruneAcknowledged(before: 1001)
        XCTAssertThrowsError(try q.capture(draft("一样的文字", clipboard: "boot-a:4"), safety: .safe, lease: lease)) { XCTAssertEqual($0 as? ActivityError, .alreadyObserved) }
    }
    func testStableBatchRetryBackoffAndExactAcknowledgement() throws {
        let q = try queue(), lease = try q.configure(config())
        _ = try q.capture(draft("一"), safety: .safe, lease: lease)
        _ = try q.capture(draft("二"), safety: .safe, lease: lease)
        let batch = try XCTUnwrap(q.nextBatch(lease: lease, now: 1000))
        try q.recordFailure(batch, lease: lease, now: 1000)
        XCTAssertNil(try q.nextBatch(lease: lease, now: 1000))
        let retry = try XCTUnwrap(q.nextBatch(lease: lease, now: 1010))
        XCTAssertEqual(batch.batchID, retry.batchID); XCTAssertEqual(try batch.encoded(), try retry.encoded())
        XCTAssertThrowsError(try q.acknowledge(batch, eventIDs: [batch.events[1].eventID], lease: lease, now: 1010))
        XCTAssertThrowsError(try q.acknowledge(batch, eventIDs: [UUID()], lease: lease, now: 1010))
        XCTAssertEqual(try q.status().pending, 2)
        try q.acknowledge(batch, eventIDs: Set(batch.events.map(\.eventID)), lease: lease, now: 1010)
        XCTAssertEqual(try q.status().acknowledged, 2)
        XCTAssertNil(try q.nextBatch(lease: lease, now: 1010))
    }
    func testForgedPayloadCannotAcknowledgeOwnIDs() throws {
        let q = try queue(), lease = try q.configure(config())
        _ = try q.capture(draft(), safety: .safe, lease: lease)
        let batch = try XCTUnwrap(q.nextBatch(lease: lease, now: 1000))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: batch.encoded()) as? [String: Any])
        var events = try XCTUnwrap(object["events"] as? [[String: Any]])
        events[0]["content"] = ["text": "伪造不同内容"]
        object["events"] = events
        let forged = try JSONDecoder().decode(ActivityBatch.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try q.acknowledge(forged, eventIDs: Set(forged.events.map(\.eventID)), lease: lease, now: 1000))
        XCTAssertEqual(try q.status().pending, 1)
    }
    func testConfirmedDeparturePurgesOnlyItsOwnQueueAndFencesOldLease() throws {
        let q = try queue(), other = try queue(), lease = try q.configure(config()), otherLease = try other.configure(config())
        _ = try q.capture(draft(), safety: .safe, lease: lease)
        _ = try other.capture(draft(), safety: .safe, lease: otherLease)
        let installation = try q.status().installationID
        try q.purgeForConfirmedDeparture()
        XCTAssertEqual(try q.status().payloadBytes, 0); XCTAssertEqual(try q.status().installationID, installation)
        XCTAssertFalse(try q.configuration().enabled); XCTAssertEqual(try other.status().pending, 1)
        XCTAssertThrowsError(try q.validate(lease))
        let next = try q.configure(config(consent: 2))
        XCTAssertEqual(try q.capture(draft(), safety: .safe, lease: next).deviceSeq, 2)
    }
    func testSignedDomainAndBodyDigestCoverEveryField() throws {
        let id = try identity(), group = UUID(), body = Data("{\"text\":\"合成\"}".utf8)
        let request = try SignedActivityRequest.sign(group: group, identity: id, operation: .ingest, body: body, now: 1000)
        XCTAssertTrue(id.signingKey.publicKey.isValidSignature(request.signature, for: try request.canonical()))
        XCTAssertTrue(try request.canonical().starts(with: Data("PrivateInput/activity-request/v1\0".utf8)))
        let relay = try SignedRelayRequest.sign(group: group, identity: id, operation: .membership, body: body, now: 1000)
        XCTAssertFalse(id.signingKey.publicKey.isValidSignature(request.signature, for: try relay.canonical()))
        XCTAssertThrowsError(try SignedActivityRequest.sign(group: group, identity: id, operation: .ingest, body: Data(repeating: 65, count: 524289), now: 1000))
    }
    func testTLSOnlyCredentialsAndRedirectPolicyEndpointValidation() throws {
        for text in ["http://example.invalid", "https://user:password@example.invalid", "https://example.invalid?token=bad", "https://example.invalid#bad", "file:///tmp/data"] {
            XCTAssertThrowsError(try ActivityHTTPTransport(endpoint: URL(string: text)!))
        }
        XCTAssertNoThrow(try ActivityHTTPTransport(endpoint: URL(string: "https://example.invalid/archive")!))
        XCTAssertNoThrow(try ActivityHTTPTransport(endpoint: URL(string: "http://127.0.0.1:9999")!, allowLoopbackHTTP: true))
        XCTAssertThrowsError(try ActivityHTTPTransport(endpoint: URL(string: "http://example.invalid")!, allowLoopbackHTTP: true))
    }
    func testWorkerStatusBeforeIngestAndSuccessfulExactACK() async throws {
        let id = try identity(), group = UUID(), q = try queue(group: group, device: id.device), lease = try q.configure(config())
        _ = try q.capture(draft(), safety: .safe, lease: lease)
        let transport = ActivityFixtureTransport(group: group, device: id.device)
        let worker = ActivityArchiveWorker(queue: q, client: ActivityArchiveClient(transport: transport))
        let result = try await worker.flush(identity: id, membershipRevision: 7, now: 1000)
        XCTAssertEqual(result.acknowledged, 1); XCTAssertEqual(result.pending, 0)
        let operations = await transport.operations
        XCTAssertEqual(operations, [.status, .ingest])
    }
    func testWorkerRejectsUnknownACKAndDoesNotLosePendingData() async throws {
        let id = try identity(), group = UUID(), q = try queue(group: group, device: id.device), lease = try q.configure(config())
        _ = try q.capture(draft(), safety: .safe, lease: lease)
        let transport = ActivityFixtureTransport(group: group, device: id.device)
        await transport.set(wrongACK: true)
        let worker = ActivityArchiveWorker(queue: q, client: ActivityArchiveClient(transport: transport))
        do { _ = try await worker.flush(identity: id, membershipRevision: 7, now: 1000); XCTFail("must reject mismatched receipt") }
        catch { XCTAssertEqual(error as? ActivityError, .invalidAcknowledgement) }
        XCTAssertEqual(try q.status().pending, 1); XCTAssertEqual(try q.status().acknowledged, 0)
    }
    func testWorkerLocalMembershipAndRemoteDisableNeverIngest() async throws {
        let id = try identity(), group = UUID(), q = try queue(group: group, device: id.device), lease = try q.configure(config())
        _ = try q.capture(draft(), safety: .safe, lease: lease)
        let transport = ActivityFixtureTransport(group: group, device: id.device)
        let worker = ActivityArchiveWorker(queue: q, client: ActivityArchiveClient(transport: transport))
        do { _ = try await worker.flush(identity: id, membershipRevision: 8, now: 1000); XCTFail("must reject changed membership") } catch {}
        await transport.set(enabled: false)
        do { _ = try await worker.flush(identity: id, membershipRevision: 7, now: 1000); XCTFail("must reject disabled policy") }
        catch { XCTAssertEqual(error as? ActivityError, .serverDisabled) }
        let operations = await transport.operations
        XCTAssertEqual(operations, [.status, .status]); XCTAssertEqual(try q.status().held, 1)
    }
    func testCrossProcessPauseCancelsInFlightWithoutACKOrAutomaticResume() async throws {
        let id = try identity(), group = UUID(), file = directory().appendingPathComponent("shared.sqlite")
        let q = try ActivityLocalEventQueue(file: file, group: group, device: id.device), lease = try q.configure(config())
        _ = try q.capture(draft(), safety: .safe, lease: lease)
        let transport = ActivityFixtureTransport(group: group, device: id.device)
        await transport.set(suspended: true)
        let worker = ActivityArchiveWorker(queue: q, client: ActivityArchiveClient(transport: transport))
        let task = Task { try await worker.flush(identity: id, membershipRevision: 7, now: 1000) }
        for _ in 0..<100 { if await transport.ingestStarted { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        let second = try ActivityLocalEventQueue(file: file, group: group, device: id.device)
        var paused = config(); paused.paused = true
        _ = try second.configure(paused)
        do { _ = try await task.value; XCTFail("must fence in-flight request") } catch {}
        XCTAssertEqual(try q.status().acknowledged, 0); XCTAssertEqual(try q.status().held, 1)
        let newLease = try q.configure(config())
        XCTAssertNil(try q.nextBatch(lease: newLease, now: 2000))
    }
    func testPythonCanonicalVectorAndEd25519Signature() throws {
        // Fixed synthetic Python vector from server/activity_archive/fixtures/activity-request-v1.json.
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../server/activity_archive/fixtures/activity-request-v1.json").standardizedFileURL
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        let request = try JSONDecoder().decode(SignedActivityRequest.self, from: JSONSerialization.data(withJSONObject: try XCTUnwrap(object["envelope"])))
        let canonical = try request.canonical()
        XCTAssertEqual(canonical.map { String(format: "%02x", $0) }.joined(), object["canonical_hex"] as? String)
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: XCTUnwrap(Data(base64Encoded: try XCTUnwrap(object["public_base64"] as? String))))
        XCTAssertTrue(key.isValidSignature(request.signature, for: canonical))
        let changed = try SignedActivityRequest.sign(group: request.group,
                                                     signer: ActivityRequestSigner(device: request.sender, signingKey: .init()),
                                                     operation: .status, body: request.body, now: request.issuedAt)
        XCTAssertFalse(key.isValidSignature(changed.signature, for: try changed.canonical()))
    }
    func testCaptureDelegateAllowsForwardMembershipWithoutGainingReadOrManagement() async throws {
        let id = try identity(), group = UUID(), q = try queue(group: group, device: id.device), lease = try q.configure(config())
        _ = try q.capture(draft(), safety: .safe, lease: lease)
        let transport = ActivityFixtureTransport(group: group, device: id.device)
        await transport.setRevision(8)
        let delegate = ActivityRequestSigner(device: id.device, signingKey: .init())
        let worker = ActivityArchiveWorker(queue: q, client: ActivityArchiveClient(transport: transport))
        let result = try await worker.flush(signer: delegate, membershipRevision: 7, now: 1000)
        XCTAssertEqual(result.acknowledged, 1)
        let operations = await transport.operations
        XCTAssertEqual(operations, [.status, .ingest])
    }
    func testCaptureDelegateRejectsMembershipRollbackAndChangedProviderConsent() async throws {
        let id = try identity(), group = UUID(), q = try queue(group: group, device: id.device), lease = try q.configure(config())
        _ = try q.capture(draft(), safety: .safe, lease: lease)
        let transport = ActivityFixtureTransport(group: group, device: id.device)
        let delegate = ActivityRequestSigner(device: id.device, signingKey: .init())
        let worker = ActivityArchiveWorker(queue: q, client: ActivityArchiveClient(transport: transport))
        await transport.setRevision(6)
        do { _ = try await worker.flush(signer: delegate, membershipRevision: 7, now: 1000); XCTFail("rollback must be rejected") }
        catch { XCTAssertEqual(error as? ActivityError, .staleAuthorization) }
        await transport.setRevision(8); await transport.setProviders(["ime.commit.v1"])
        do { _ = try await worker.flush(signer: delegate, membershipRevision: 7, now: 1000); XCTFail("provider authorization must not change implicitly") }
        catch { XCTAssertEqual(error as? ActivityError, .consentMismatch) }
        XCTAssertFalse(try q.configuration().enabled); XCTAssertEqual(try q.status().held, 1)
        let operations = await transport.operations; XCTAssertEqual(operations, [.status, .status])
    }
    func testSeparateConnectionsAllocateUniqueSequencesAtomically() throws {
        let group = UUID(), device = UUID(), file = directory().appendingPathComponent("concurrent.sqlite")
        let first = try ActivityLocalEventQueue(file: file, group: group, device: device)
        let lease = try first.configure(config())
        let second = try ActivityLocalEventQueue(file: file, group: group, device: device)
        let resultsLock = NSLock(); var sequences: [UInt64] = []; var errors = 0
        DispatchQueue.concurrentPerform(iterations: 24) { index in
            do {
                let q = index.isMultiple(of: 2) ? first : second
                let event = try q.capture(self.draft("合成并发\(index)"), safety: .safe, lease: lease)
                resultsLock.lock(); sequences.append(event.deviceSeq); resultsLock.unlock()
            } catch { resultsLock.lock(); errors += 1; resultsLock.unlock() }
        }
        XCTAssertEqual(errors, 0); XCTAssertEqual(sequences.sorted(), Array(1...24).map(UInt64.init))
        XCTAssertEqual(try first.status().pending, 24); XCTAssertEqual(try second.status().lastSequence, 24)
    }
    func testDatabaseLeafSymlinkIsRejectedWithoutChangingTarget() throws {
        let root = directory(), target = root.appendingPathComponent("unrelated-synthetic.txt"), link = root.appendingPathComponent("events.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("unrelated synthetic file".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try ActivityLocalEventQueue(file: link, group: UUID(), device: UUID()))
        XCTAssertEqual(try Data(contentsOf: target), Data("unrelated synthetic file".utf8))
    }
}
