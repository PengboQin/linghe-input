import Foundation
import CryptoKit
import PrivateInputKit

private final class Secrets: IdentitySecretStore {
    var value: Data?
    func read() throws -> Data? { value }
    func insert(_ data: Data) throws { value = data }
    func replace(_ data: Data) throws { value = data }
}
@main enum Check {
    static func main() throws {
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: input)) as! [String: Any]
        let decoder = JSONDecoder()
        func decode<T: Decodable>(_ key: String, _ type: T.Type, result: Bool = false) throws -> T {
            let object = result ? (fixture[key] as! [String: Any])["result"]! : fixture[key]!
            return try decoder.decode(type, from: JSONSerialization.data(withJSONObject: object))
        }
        var checks = 0
        func check(_ condition: Bool) { precondition(condition); checks += 1 }
        func rejects(_ body: () throws -> Void) { do { try body(); preconditionFailure("unexpected success") } catch { checks += 1 } }
        let producer = UUID(uuidString: fixture["producer"] as! String)!
        let group = UUID(uuidString: fixture["group"] as! String)!, device = UUID(uuidString: fixture["device"] as! String)!, installation = UUID(uuidString: fixture["installation"] as! String)!
        let policy = try CloudLearningTextPolicy(standardCharacters: Data(contentsOf: URL(fileURLWithPath: "resources/rime/charset/standard-8105.txt")))
        let initial = try decode("records_initial", [LearningEntry].self)
        let merged = try decode("merged_records", [LearningEntry].self)
        let firstDelta = try decode("pull_initial", CloudLearningDelta.self, result: true)
        let nextDelta = try decode("pull_incremental", CloudLearningDelta.self, result: true)
        let firstReceipt = try decode("receipt_initial", CloudLearningComponentReceipt.self, result: true)
        check(try CloudLearningComponents.digest(producer: producer, records: initial) == firstReceipt.componentDigest)
        var mixed = initial[0]; mixed.counts[UUID().uuidString] = 9999
        let projection = CloudLearningComponents.project([mixed, .init(reading: "hao", text: "好體"), .init(reading: "hao", text: String(repeating: "好", count: 33))], producer: producer, policy: policy)
        check(projection.count == 1); check(projection[0].counts.count == 1); check(projection[0].counts[producer.uuidString] == 3)
        var migration = try CloudLearningComponentMigration(model: .init(group: group, device: device, installation: installation, generation: 1, consentVersion: 1))
        let publication = try migration.prepare(producer: producer, records: initial)!
        check(publication.historyMode == "historical_undated"); check(!migration.ready)
        migration = try CloudLearningComponentMigration.restore(migration.data())
        check(try migration.prepare(producer: producer, records: initial)?.publicationID == publication.publicationID)
        func receipt(_ key: String, publication: CloudLearningComponentPublication) throws -> CloudLearningComponentReceipt {
            var object = (fixture[key] as! [String: Any])["result"] as! [String: Any]
            object["accepted_publication_id"] = publication.publicationID.uuidString
            return try decoder.decode(CloudLearningComponentReceipt.self, from: JSONSerialization.data(withJSONObject: object))
        }
        try migration.receive(receipt("receipt_initial", publication: publication)); check(!migration.ready)
        check(try migration.prepare(producer: producer, records: initial) == nil)
        try migration.stage(firstDelta, policy: policy); check(migration.ready)
        check(migration.model.terms.count == 2); check(migration.model.terms.values.allSatisfy { $0.layout == .shared })
        let oldScores = migration.scores(current: [producer: initial])!
        let local = migration.scores(current: [producer: merged])!
        check(local[initial[0].id]! > oldScores[initial[0].id]!)
        let update = try migration.prepare(producer: producer, records: merged)!
        check(update.historyMode == "incremental"); check(update.records.count == 1)
        try migration.receive(receipt("receipt_incremental", publication: update))
        check(try migration.prepare(producer: producer, records: merged) == nil)
        try migration.stage(nextDelta, policy: policy)
        check(migration.ready); check(migration.model.modelVersion == 2)
        check(migration.scores(current: [producer: merged]) == local) // no double weight after worker ACK
        let restored = try CloudLearningComponentMigration.restore(migration.data()); check(restored.ready)
        var reset = merged[0]; reset.generation += 1; reset.counts = [:]
        check(restored.scores(current: [producer: [reset]])?[reset.id] == 0)
        var bad = (fixture["pull_incremental"] as! [String: Any])["result"] as! [String: Any]
        bad["from_version"] = 2; bad["model_sha256"] = String(repeating: "0", count: 64)
        let tampered = try decoder.decode(CloudLearningDelta.self, from: JSONSerialization.data(withJSONObject: bad))
        rejects { try migration.stage(tampered, policy: policy) }; check(migration.model.modelVersion == 2)
        rejects { try migration.receive(firstReceipt) }
        var empty = try CloudLearningComponentMigration(model: .init(group: group, device: device, installation: installation, generation: 1, consentVersion: 1))
        let registration = try empty.prepare(producer: UUID(), records: [])!
        check(registration.records.isEmpty); check(registration.historyMode == "historical_undated")
        // Cloud tombstones fence old local counts; same-generation undeleted
        // replicas cannot revive a removed lexeme in either iteration order.
        var modelObject = try JSONSerialization.jsonObject(with: migration.model.persistedData()) as! [String: Any]
        modelObject["terms"] = [String: Any]()
        modelObject["cloudTermGenerations"] = ["shared\u{001F}hao\u{001F}好": 1]
        let removedModel = try CloudLearningReplica.restore(JSONSerialization.data(withJSONObject: modelObject))
        var removedMigration = CloudLearningComponentMigration(model: removedModel)
        let projectionRemoved = CloudLearningRankProjection(migration: removedMigration)
        check(try projectionRemoved.scores(current: [producer: merged])[merged[0].id] == nil)
        var same = merged[0]; same.generation = 1
        check(try projectionRemoved.scores(current: [producer: [same]])[same.id] == 0)
        let peer = UUID()
        var a = same; a.deleted = true; a.counts = [producer.uuidString: 4]
        var b = same; b.counts = [peer.uuidString: 50]
        let liveProjection = CloudLearningRankProjection(migration: migration)
        let orderA = try liveProjection.scores(current: [producer: [a], peer: [b]])
        let orderB = try liveProjection.scores(current: [peer: [b], producer: [a]])
        check(orderA == orderB); check(orderA[a.id] == 0)
        b.generation = 2
        check(try projectionRemoved.scores(current: [peer: [b]])[b.id]! > 0)
        // Restored Native backups may be lower than the server MAX. Bootstrap
        // must recover all components, refresh consent with empty op6, and stop
        // republishing lower counters after its genuine durable receipt.
        var remote = [String: Any]()
        remote["exists"] = true; remote["producer_id"] = producer.uuidString
        remote["producer_revision"] = 2
        remote["records"] = fixture["merged_records"]!
        remote["component_digest"] = (fixture["receipt_incremental"] as! [String: Any])["result"] as? String
        let fixtureReceipt = (fixture["receipt_incremental"] as! [String: Any])["result"] as! [String: Any]
        remote["component_digest"] = fixtureReceipt["component_digest"]
        let recovered = try decoder.decode(CloudLearningComponentSnapshot.self, from: JSONSerialization.data(withJSONObject: remote))
        var backup = try CloudLearningComponentMigration(model: .init(group: group, device: device, installation: installation, generation: 1, consentVersion: 1))
        try backup.bootstrap(recovered)
        let registrationAgain = try backup.prepare(producer: producer, records: initial)!
        check(registrationAgain.records.isEmpty); check(registrationAgain.historyMode == "historical_undated")
        var recoveredReceipt = fixtureReceipt; recoveredReceipt["accepted_publication_id"] = registrationAgain.publicationID.uuidString
        recoveredReceipt["changed_records"] = 0
        try backup.receive(decoder.decode(CloudLearningComponentReceipt.self, from: JSONSerialization.data(withJSONObject: recoveredReceipt)))
        check(try backup.prepare(producer: producer, records: initial) == nil)
        check(backup.producers[producer.uuidString]?.baselineComplete == true)
        check(backup.producers[producer.uuidString]?.accepted[initial[0].id]?.counts[producer.uuidString] == 4)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("linghe-cloud-components-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let identity = try DeviceIdentityVault(store: Secrets(), directory: temporary).create()
        let signed = try CloudLearningRequest.sign(group: group, identity: identity, operation: 6, body: encoder.encode(publication), now: fixture["issued_at"] as! UInt64)
        check(signed.signature.count == 64)
        let proof: [String: Any] = ["assertions": checks, "fixture": "synthetic_only", "sharedModelHashMatchesPython": true, "componentDigestMatchesPython": true, "physicalDeviceTest": false]
        print(String(data: try JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
