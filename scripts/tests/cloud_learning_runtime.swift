import Foundation
import CryptoKit
import PrivateInputKit

private final class Secrets: IdentitySecretStore {
    var value: Data?
    func read() throws -> Data? { value }
    func insert(_ data: Data) throws { value = data }
    func replace(_ data: Data) throws { value = data }
}
private actor FixtureTransport: CloudLearningTransport {
    let fixture: [String: Any]
    let publicKey: Curve25519.Signing.PublicKey
    init(_ fixture: [String: Any], publicKey: Curve25519.Signing.PublicKey) { self.fixture = fixture; self.publicKey = publicKey }
    func send(_ request: CloudLearningRequest) async throws -> Data {
        guard publicKey.isValidSignature(request.signature, for: try request.canonical()) else { throw CloudLearningError.invalid }
        let key = request.operation == 4 ? "receipt" : request.operation == 5 ? "pull" : "status"
        var result = fixture[key] as! [String: Any]; result["operation"] = Int(request.operation)
        return try JSONSerialization.data(withJSONObject: result)
    }
}
@main struct CloudLearningRuntime {
    static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: message, code: 1) }; checks += 1
        }
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: input)) as! [String: Any]
        let decoder = JSONDecoder()
        let textPolicy = try CloudLearningTextPolicy(standardCharacters: Data(contentsOf: URL(fileURLWithPath: "resources/rime/charset/standard-8105.txt")))
        try check(textPolicy.allowsTerm("淘宝") && !textPolicy.allowsTerm("淘寶") && !textPolicy.allowsTerm("apple"), "cloud-shared-text-policy")
        for spelling in ["hao\n", "hao\r\n", " hao", "hao  hao", "hao''hao"] {
            do { _ = try CloudLearningEvent(deviceSeq: 1, kind: .confirm, reading: spelling, text: "好", layout: .pinyin26, observedAt: 0); throw NSError(domain: "invalid-reading-enqueued", code: 1) }
            catch CloudLearningError.invalid { checks += 1 }
        }
        func decode<T: Decodable>(_ type: T.Type, _ key: String) throws -> T {
            try decoder.decode(T.self, from: JSONSerialization.data(withJSONObject: (fixture[key] as! [String: Any])["result"]!))
        }
        let group = UUID(uuidString: fixture["group"] as! String)!, device = UUID(uuidString: fixture["device"] as! String)!
        let installation = UUID(uuidString: fixture["installation"] as! String)!, now = (fixture["issued_at"] as! NSNumber).uint64Value
        let status = try decode(CloudLearningStatus.self, "status")
        try check(status.enabled && status.generation == 1 && status.consent?.enabled == true, "python-status")
        let delta = try decode(CloudLearningDelta.self, "pull")
        let events = try decoder.decode([CloudLearningEvent].self, from: JSONSerialization.data(withJSONObject: fixture["events"]!))
        try check(try CloudLearningReplica.hash(generation: 1, terms: delta.upserts, watermarks: delta.watermarks, algorithmVersion: delta.algorithmVersion, producers: delta.producerWatermarks) == delta.modelSHA256, "python-swift-full-model-hash")
        var state = try CloudLearningReplica(group: group, device: device, installation: installation, generation: 1, consentVersion: 1)
        for event in events { try state.record(kind: event.kind, reading: event.reading, text: event.text, layout: event.layout, now: now, policy: textPolicy) }
        let batch = state.pendingUpload()
        let localReceipt = try decoder.decode(CloudLearningReceipt.self, from: JSONSerialization.data(withJSONObject: [
            "accepted_event_ids": batch.map { $0.eventID.uuidString }, "received_device_seq": 2, "generation": 1, "consent_version": 1,
            "term_generations": [], "rejected_event_ids": []] as [String: Any]))
        try state.receive(localReceipt, batch: batch)
        try check(state.pendingUpload().isEmpty && state.observations.count == 2, "ingest-ack-is-not-learning-ack")
        try state.receive(localReceipt, batch: batch)
        try check(state.localPendingCount(reading: "hao", text: "好", layout: .pinyin26) == 1, "retry-not-double-local-overlay")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("linghe-cloud-fixture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let persisted = CloudLearningReplicaStore(directory: temporary, activatedReplica: state)
        try persisted.transaction { $0 = state }
        try persisted.transaction { try $0.stage(delta, policy: textPolicy) }
        state = try persisted.read()
        try check(state.observations.isEmpty && state.modelVersion == 1 && state.terms.count == 2, "durable-worker-ack-retires-overlay")
        var bad = fixture["pull"] as! [String: Any], badResult = bad["result"] as! [String: Any]
        badResult["from_version"] = 1; badResult["model_sha256"] = String(repeating: "0", count: 64); bad["result"] = badResult
        let badDelta = try decoder.decode(CloudLearningDelta.self, from: JSONSerialization.data(withJSONObject: badResult))
        let before = try state.persistedData()
        do { try persisted.transaction { try $0.stage(badDelta, policy: textPolicy) }; throw NSError(domain: "accepted-invalid-hash", code: 1) }
        catch CloudLearningError.badHash { checks += 1 }
        let durable = try persisted.read()
        try check(durable.modelVersion == 1 && durable.observations.isEmpty, "failed-model-leaves-durable-state")
        try state.record(kind: .reset, reading: "hao", text: "好", layout: .pinyin26, now: now, policy: textPolicy)
        try check(state.effectiveTerm(reading: "hao", text: "好", layout: .pinyin26)?.weight == 0, "local-reset-overrides-old-cloud-weight-immediately")
        let afterReset = try state.record(kind: .confirm, reading: "hao", text: "好", layout: .pinyin26, now: now, policy: textPolicy)
        try check(afterReset.termGeneration == 1 && state.localPendingCount(reading: "hao", text: "好", layout: .pinyin26) == 1, "reset-fences-following-local-learning")
        try check(state.effectiveTerm(reading: "hao", text: "好", layout: .pinyin26)?.weight == 1000, "local-post-reset-count-does-not-add-old-cloud-count")
        try state.record(kind: .remove, reading: "hao", text: "好", layout: .pinyin26, now: now, policy: textPolicy)
        try check(state.effectiveTerm(reading: "hao", text: "好", layout: .pinyin26) == nil, "local-remove-hides-old-cloud-row")
        try state.record(kind: .pin, reading: "hao", text: "好", layout: .pinyin26, now: now, policy: textPolicy)
        try check(state.effectiveTerm(reading: "hao", text: "好", layout: .pinyin26) == nil, "pin-is-not-restore-for-a-removed-term")
        try state.record(kind: .restore, reading: "hao", text: "好", layout: .pinyin26, now: now, policy: textPolicy)
        try state.record(kind: .confirm, reading: "hao", text: "好", layout: .pinyin26, now: now, policy: textPolicy)
        try check(state.effectiveTerm(reading: "hao", text: "好", layout: .pinyin26)?.weight == 1000, "explicit-restore-reenables-new-learning")
        try check(try CloudLearningReplica.restore(before).terms.count == 2, "crash-restore-model")
        var broken = try JSONSerialization.jsonObject(with: state.persistedData()) as! [String: Any]
        var history = broken["observations"] as! [[String: Any]]; history.removeFirst(); broken["observations"] = history
        do { _ = try CloudLearningReplica.restore(JSONSerialization.data(withJSONObject: broken)); throw NSError(domain: "restored-sequence-gap", code: 1) }
        catch CloudLearningError.invalid { checks += 1 }
        let identity = try DeviceIdentityVault(store: Secrets(), directory: temporary.appendingPathComponent("Identity")).create()
        let client = CloudLearningClient(transport: FixtureTransport(fixture, publicKey: identity.signingKey.publicKey))
        let response = try await client.status(group: group, identity: identity, now: now)
        try check(response.enabled, "signed-client-status")
        let receipt = try await client.ingest(events, generation: 1, consentVersion: 1, installation: installation, policy: textPolicy, group: group, identity: identity, now: now)
        try check(receipt.receivedDeviceSeq == 2, "signed-client-ingest-python-receipt")
        let pulled = try await client.pull(generation: 1, fromVersion: 0, group: group, identity: identity, now: now)
        try check(pulled.modelSHA256 == delta.modelSHA256, "signed-client-pull")
        let request = try CloudLearningRequest.sign(group: group, identity: identity, operation: 1, body: Data("{}".utf8), now: now)
        let recencySetup = try GroupSetup.create(owner: identity), knownEvent = UUID().uuidString
        let recencyRequest = try SignedRecencyRequest.sign(group: recencySetup.membership.statement.group, identity: identity, operation: 1,
                                                         body: JSONSerialization.data(withJSONObject: ["knownEvent": knownEvent]), now: now)
        var conditionalStatus: [String: Any] = ["version": 1, "group": recencyRequest.group.uuidString, "sender": identity.device.uuidString,
            "nonce": recencyRequest.nonce.uuidString, "epoch": recencySetup.membership.statement.epoch, "membershipRevision": recencySetup.membership.statement.revision,
            "serverTime": now, "referenceDay": now / 86400, "ready": true, "missing": [String](), "publishedEvent": knownEvent, "conditionalSnapshots": true]
        try decoder.decode(RecentLearningServerStatus.self, from: JSONSerialization.data(withJSONObject: conditionalStatus)).validate(request: recencyRequest, setup: recencySetup)
        checks += 1
        conditionalStatus["publishedEvent"] = UUID().uuidString
        do { try decoder.decode(RecentLearningServerStatus.self, from: JSONSerialization.data(withJSONObject: conditionalStatus)).validate(request: recencyRequest, setup: recencySetup); throw NSError(domain: "omitted-unknown-own-snapshot", code: 1) }
        catch RecentLearningSyncError.invalidWire { checks += 1 }
        conditionalStatus["publishedEvent"] = knownEvent; conditionalStatus.removeValue(forKey: "conditionalSnapshots")
        do { try decoder.decode(RecentLearningServerStatus.self, from: JSONSerialization.data(withJSONObject: conditionalStatus)).validate(request: recencyRequest, setup: recencySetup); throw NSError(domain: "legacy-response-omitted-own-snapshot", code: 1) }
        catch RecentLearningSyncError.invalidWire { checks += 1 }
        let vector = try JSONSerialization.data(withJSONObject: ["fixture_kind": "synthetic_only", "public_key": identity.signingKey.publicKey.rawRepresentation.base64EncodedString(),
            "request": JSONSerialization.jsonObject(with: JSONEncoder().encode(request))], options: [.sortedKeys])
        try vector.write(to: input.deletingLastPathComponent().appendingPathComponent("swift-request-vector.json"), options: .atomic)

        var source = LearningModel(), peer = LearningModel()
        for i in 0..<100 { try source.record(reading: "ci", text: "词\(i)", device: "a") }
        let full = try source.export(), initial = try LearningDeltaPublication.prepare(archive: source.export(), group: group, epoch: 1, previous: nil)
        try check(initial.checkpoint.entries.keys.allSatisfy { $0.count == 44 }, "local-checkpoint-uses-bounded-hashed-term-ids")
        try check(try LearningDeltaPublication.prepare(archive: full, group: UUID(), epoch: 1, previous: initial.checkpoint).bootstrap, "new-group-bootstrap")
        try check(try LearningDeltaPublication.prepare(archive: full, group: group, epoch: 2, previous: initial.checkpoint).bootstrap, "new-epoch-bootstrap")
        try peer.merge(initial.payload!)
        try source.record(reading: "ci", text: "词1", device: "a")
        let change = try LearningDeltaPublication.prepare(archive: source.export(), group: group, epoch: 1, previous: initial.checkpoint)
        try check(change.changedEntries == 1 && change.payload!.count * 10 < full.count, "legacy-delta-one-word-not-whole-dictionary")
        try peer.merge(change.payload!); try peer.merge(change.payload!)
        try check(try peer.export() == source.export(), "legacy-delta-retry-converges")
        try source.resetFrequency(reading: "ci", text: "词1")
        let reset = try LearningDeltaPublication.prepare(archive: source.export(), group: group, epoch: 1, previous: change.checkpoint)
        try peer.merge(reset.payload!); try peer.merge(change.payload!)
        try check(peer.entries["ci\u{001F}词1"]?.frequency == 0, "late-delta-cannot-revive-reset")
        var personal = PersonalLexiconSync(), personalSource = LearningModel(), personalPeer = LearningModel()
        let author = UUID()
        for i in 0..<50 { try personal.change(.init(kind: .word, text: "名字\(i)", trigger: "ming zi"), deleted: false, replica: author) }
        try personalSource.mergePersonalLexicon(personal)
        let p0 = try LearningDeltaPublication.prepare(archive: personalSource.export(), group: group, epoch: 1, previous: nil)
        try personalPeer.merge(p0.payload!)
        var edited = personal.records.values.first!.entry; edited.text = "新名字"
        try personal.change(edited, deleted: false, replica: author); try personalSource.mergePersonalLexicon(personal)
        let p1 = try LearningDeltaPublication.prepare(archive: personalSource.export(), group: group, epoch: 1, previous: p0.checkpoint)
        let smallPersonal = try decoder.decode(LearningArchive.self, from: p1.payload!)
        try check(smallPersonal.personalLexicon?.records.count == 1, "personal-word-and-phrase-delta-is-one-record")
        try personalPeer.merge(p1.payload!)
        try check(try personalPeer.export() == personalSource.export(), "personal-delta-preserves-other-records")
        try personal.change(edited, deleted: true, replica: author); try personalSource.mergePersonalLexicon(personal)
        let p2 = try LearningDeltaPublication.prepare(archive: personalSource.export(), group: group, epoch: 1, previous: p1.checkpoint)
        try personalPeer.merge(p2.payload!); try personalPeer.merge(p1.payload!)
        try check(personalPeer.personalLexicon?.records[edited.id.uuidString]?.deleted == true, "personal-tombstone-wins-over-late-edit")
        try Data(UUID().uuidString.utf8).write(to: temporary.appendingPathComponent("privacy-reset-generation-v1.txt"), options: .atomic)
        do { _ = try persisted.read(); throw NSError(domain: "stale-owner-read-after-reset", code: 1) }
        catch InputDataError.invalidRecord { checks += 1 }
        let report: [String: Any] = ["passed": checks, "fullArchiveBytes": full.count, "oneChangedWordBytes": change.payload!.count,
                                  "pythonSwiftModelHashEqual": true, "syntheticOnly": true, "realGroupOrDeviceChanged": false]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]), as: UTF8.self))
    }
}
