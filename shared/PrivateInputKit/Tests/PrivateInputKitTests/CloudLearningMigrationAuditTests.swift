import XCTest
@testable import PrivateInputKit

final class CloudLearningMigrationAuditTests: XCTestCase {
    func testAuditTracksProducerWatermarkAndPendingPublication() throws {
        let producer = UUID(), group = UUID(), device = UUID(), installation = UUID()
        let replica = try CloudLearningReplica(group: group, device: device, installation: installation, generation: 1, consentVersion: 1)
        var migration = CloudLearningComponentMigration(model: replica)
        var seed = LearningEntry(reading: "ni hao", text: "你好"); seed.counts[producer.uuidString] = 1
        let seedDigest = try CloudLearningComponents.digest(producer: producer, records: [seed])
        try migration.bootstrap(.init(exists: true, producerID: producer, producerRevision: 1, componentDigest: seedDigest, records: [seed]))
        let emptyPublication = try XCTUnwrap(try migration.prepare(producer: producer, records: [seed]))
        try migration.receive(.init(acceptedPublicationID: emptyPublication.publicationID, producerID: producer,
            producerRevision: 1, generation: 1, consentVersion: 1, changedRecords: 0, componentDigest: seedDigest))
        var entry = LearningEntry(reading: "ling he", text: "灵鹤")
        entry.counts[producer.uuidString] = 1
        let pending = try XCTUnwrap(try migration.prepare(producer: producer, records: [seed, entry]))
        let first = migration.audit()
        XCTAssertEqual(first.producers.count, 1); XCTAssertEqual(first.producers[0].producerID, producer)
        XCTAssertEqual(first.producers[0].acceptedRecords, 1); XCTAssertEqual(first.pendingPublications, 1)
        XCTAssertTrue(first.legacyReadFallbackRequired)
        XCTAssertEqual(pending.records.count, 1)

        let expected = try CloudLearningComponents.digest(producer: producer, records: [seed, entry])
        try migration.receive(.init(acceptedPublicationID: pending.publicationID, producerID: producer,
            producerRevision: 2, generation: 1, consentVersion: 1, changedRecords: 1, componentDigest: expected))
        let second = migration.audit()
        XCTAssertEqual(second.producers[0].acceptedRecords, 2); XCTAssertEqual(second.producers[0].receiptRevision, 2)
        XCTAssertEqual(second.pendingPublications, 0); XCTAssertTrue(second.producers[0].baselineComplete)
        XCTAssertTrue(second.legacyReadFallbackRequired, "model not staged yet, so legacy read must remain")
        XCTAssertFalse(second.ready)
    }

    func testPendingPublicationSurvivesRestoreForRetry() throws {
        let producer = UUID(), replica = try CloudLearningReplica(group: UUID(), device: UUID(), installation: UUID(), generation: 1, consentVersion: 1)
        var migration = CloudLearningComponentMigration(model: replica)
        try migration.bootstrap(.init(exists: false, producerID: producer, producerRevision: 0,
            componentDigest: try CloudLearningComponents.digest(producer: producer, records: []), records: []))
        var entry = LearningEntry(reading: "ling he", text: "灵鹤"); entry.counts[producer.uuidString] = 1
        let publication = try XCTUnwrap(try migration.prepare(producer: producer, records: [entry]))
        let restored = try CloudLearningComponentMigration.restore(try migration.data())
        let audit = restored.audit()
        XCTAssertEqual(audit.pendingPublications, 1)
        XCTAssertEqual(audit.producers[0].pendingPublication, true)
        XCTAssertTrue(audit.legacyReadFallbackRequired)
        var retry = restored
        try retry.receive(.init(acceptedPublicationID: publication.publicationID, producerID: producer,
            producerRevision: 1, generation: 1, consentVersion: 1, changedRecords: 1,
            componentDigest: try CloudLearningComponents.digest(producer: producer, records: [entry])))
        XCTAssertEqual(retry.audit().pendingPublications, 0)
    }
}
