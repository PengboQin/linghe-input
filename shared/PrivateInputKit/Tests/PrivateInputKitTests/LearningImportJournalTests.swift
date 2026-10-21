import XCTest
@testable import PrivateInputKit

final class LearningImportJournalTests: XCTestCase {
    private let key = "ni hao\u{001F}你好"
    private func export(_ count: Int) -> Data { Data("你好\tni hao\t\(count)\n".utf8) }
    private func remote(_ count: Int = 4) throws -> Data {
        var peer = RimeLearningCheckpoint()
        try peer.observeExport(export(count), device: "remote")
        return try peer.outboundArchive()
    }
    private func frequency(_ journal: LearningImportJournal) -> UInt64? { journal.checkpoint.model.entries[key]?.frequency }

    func testNormalImportPreservesOldTotalsAndOnlyLaterLocalDeltaIsNewInput() throws {
        var journal = try LearningImportJournal()
        try journal.observeExport(export(2), device: "local")
        let intent = try journal.prepare(finalLocalExport: export(3), remoteArchive: remote(), device: "local")
        XCTAssertEqual(intent.target.model.entries[key]?.counts, ["local": 3, "remote": 4])
        XCTAssertTrue(String(decoding: try intent.nativeImportTSV(), as: UTF8.self).contains("你好\tni hao\t7"))
        try journal.commit(transactionID: intent.id, actualEngineExport: export(7))
        try journal.observeExport(export(7), device: "local")
        XCTAssertEqual(frequency(journal), 7)
        try journal.observeExport(export(8), device: "local")
        XCTAssertEqual(journal.checkpoint.model.entries[key]?.counts, ["local": 4, "remote": 4])
    }

    func testPersistedPendingRejectsObservationPublicationAndSecondPrepare() throws {
        var journal = try LearningImportJournal()
        let intent = try journal.prepare(finalLocalExport: export(3), remoteArchive: remote(), device: "local")
        var restarted = try LearningImportJournal.restore(journal.persistedData())
        XCTAssertEqual(restarted.pending?.id, intent.id)
        XCTAssertThrowsError(try restarted.observeExport(export(7), device: "local")) {
            XCTAssertEqual($0 as? LearningImportJournal.JournalError, .importPending)
        }
        XCTAssertThrowsError(try restarted.outboundArchive())
        XCTAssertThrowsError(try restarted.prepare(finalLocalExport: export(7), remoteArchive: remote(), device: "local"))
        XCTAssertEqual(restarted.pending?.target.model.entries[key]?.frequency, 7)
    }

    func testCrashBeforeNativeImportRequiresVerifiedReplayWithoutInventingLocalLearning() throws {
        var journal = try LearningImportJournal()
        let intent = try journal.prepare(finalLocalExport: export(3), remoteArchive: remote(), device: "local")
        var restarted = try LearningImportJournal.restore(journal.persistedData())
        XCTAssertThrowsError(try restarted.observeExport(export(3), device: "local"))
        // Isolated native replacement successfully converges to the target.
        try restarted.commit(transactionID: intent.id, actualEngineExport: export(7))
        XCTAssertEqual(frequency(restarted), 7)
        try restarted.observeExport(export(8), device: "local")
        XCTAssertEqual(restarted.checkpoint.model.entries[key]?.counts, ["local": 4, "remote": 4])
    }

    func testCrashDuringNativeImportKeepsPartialResultQuarantinedUntilVerifiedReplay() throws {
        var journal = try LearningImportJournal()
        let intent = try journal.prepare(finalLocalExport: export(3), remoteArchive: remote(), device: "local")
        var restarted = try LearningImportJournal.restore(journal.persistedData())
        XCTAssertThrowsError(try restarted.observeExport(export(5), device: "local"))
        // Only after an idempotent replay has completed may this be committed.
        try restarted.commit(transactionID: intent.id, actualEngineExport: export(7))
        try restarted.observeExport(export(7), device: "local")
        XCTAssertEqual(frequency(restarted), 7)
        try restarted.observeExport(export(8), device: "local")
        XCTAssertEqual(frequency(restarted), 8)
    }

    func testCrashAfterNativeImportAndBeforeCommitOrFinalSaveIsRecoverable() throws {
        var journal = try LearningImportJournal()
        let intent = try journal.prepare(finalLocalExport: export(3), remoteArchive: remote(), device: "local")
        let durablePending = try journal.persistedData()
        // Native import completed; a successful in-memory commit was not saved.
        try journal.commit(transactionID: intent.id, actualEngineExport: export(7))
        var restarted = try LearningImportJournal.restore(durablePending)
        XCTAssertThrowsError(try restarted.observeExport(export(7), device: "local"))
        // The synthetic native adapter guarantees replacement, not addition.
        let replayedEngine = export(7)
        try restarted.commit(transactionID: intent.id, actualEngineExport: replayedEngine)
        var afterSave = try LearningImportJournal.restore(restarted.persistedData())
        try afterSave.observeExport(export(8), device: "local")
        XCTAssertEqual(afterSave.checkpoint.model.entries[key]?.counts, ["local": 4, "remote": 4])
    }

    func testStaleIDAndMalformedActualExportKeepPendingIntact() throws {
        var journal = try LearningImportJournal()
        let intent = try journal.prepare(finalLocalExport: export(3), remoteArchive: remote(), device: "local")
        let before = try journal.persistedData()
        XCTAssertThrowsError(try journal.commit(transactionID: UUID(), actualEngineExport: export(7)))
        XCTAssertThrowsError(try journal.commit(transactionID: intent.id, actualEngineExport: Data("bad".utf8)))
        XCTAssertEqual(try journal.persistedData(), before)
        try journal.commit(transactionID: intent.id, actualEngineExport: export(7))
        XCTAssertThrowsError(try journal.commit(transactionID: intent.id, actualEngineExport: export(7)))
    }

    func testPrepareAndObserveFailuresAreAtomic() throws {
        var journal = try LearningImportJournal()
        try journal.observeExport(export(2), device: "local")
        let before = try journal.persistedData()
        XCTAssertThrowsError(try journal.prepare(finalLocalExport: export(3), remoteArchive: Data("bad".utf8), device: "local"))
        XCTAssertEqual(try journal.persistedData(), before)
        XCTAssertThrowsError(try journal.observeExport(export(3), device: ""))
        XCTAssertThrowsError(try journal.observeExport(export(3) + Data("bad\n".utf8), device: "local"))
        XCTAssertEqual(try journal.persistedData(), before)
    }

    func testBaselineUsesActualNativeResultRatherThanRequestedImportCount() throws {
        var journal = try LearningImportJournal()
        let intent = try journal.prepare(finalLocalExport: export(3), remoteArchive: remote(), device: "local")
        // Native engine export semantics can differ from the requested total.
        try journal.commit(transactionID: intent.id, actualEngineExport: export(11))
        try journal.observeExport(export(11), device: "local")
        XCTAssertEqual(frequency(journal), 7)
        try journal.observeExport(export(12), device: "local")
        XCTAssertEqual(frequency(journal), 8)
    }

    func testExplicitLegacyCheckpointWrapPreservesCountersAndPins() throws {
        var old = RimeLearningCheckpoint()
        try old.observeExport(export(9), device: "old")
        try old.setPinned(reading: "ni hao", text: "你好", pinned: true, device: "old")
        let legacy = try JSONDecoder().decode(RimeLearningCheckpoint.self, from: JSONEncoder().encode(old))
        var journal = try LearningImportJournal(checkpoint: legacy)
        try journal.observeExport(export(9), device: "old")
        XCTAssertEqual(frequency(journal), 9)
        XCTAssertEqual(journal.checkpoint.model.entries[key]?.pinned, true)
        // A journal is never silently decoded as an old idle checkpoint.
        XCTAssertThrowsError(try LearningImportJournal.restore(JSONEncoder().encode(old)))
    }

    func testResetAndPinSurviveInterruptedImportRecovery() throws {
        var old = RimeLearningCheckpoint()
        try old.observeExport(export(9), device: "local")
        var peer = old
        try peer.resetFrequency(reading: "ni hao", text: "你好")
        try peer.setPinned(reading: "ni hao", text: "你好", pinned: true, device: "remote")
        var journal = try LearningImportJournal(checkpoint: old)
        let intent = try journal.prepare(finalLocalExport: export(9), remoteArchive: peer.outboundArchive(), device: "local")
        var restarted = try LearningImportJournal.restore(journal.persistedData())
        try restarted.commit(transactionID: intent.id, actualEngineExport: export(1))
        XCTAssertEqual(frequency(restarted), 0)
        XCTAssertEqual(restarted.checkpoint.model.entries[key]?.pinned, true)
        XCTAssertTrue(restarted.checkpoint.pendingResets.isEmpty)
        try restarted.observeExport(export(2), device: "local")
        XCTAssertEqual(frequency(restarted), 1)
    }

    func testMalformedPersistedMetadataAndFutureVersionsFailClosed() throws {
        let journal = try LearningImportJournal()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: journal.persistedData()) as? [String: Any])
        object["version"] = 2
        XCTAssertThrowsError(try LearningImportJournal.restore(JSONSerialization.data(withJSONObject: object)))
        object["version"] = 1
        var checkpoint = try XCTUnwrap(object["checkpoint"] as? [String: Any])
        checkpoint["observedCounts"] = ["not-an-entry-id": 1]
        object["checkpoint"] = checkpoint
        XCTAssertThrowsError(try LearningImportJournal.restore(JSONSerialization.data(withJSONObject: object)))
    }

    func testCrashBeforeNativeResetKeepsGenerationPendingUntilVerifiedReplay() throws {
        var old = RimeLearningCheckpoint()
        try old.observeExport(export(9), device: "local")
        var peer = old
        try peer.resetFrequency(reading: "ni hao", text: "你好")
        var journal = try LearningImportJournal(checkpoint: old)
        let intent = try journal.prepare(finalLocalExport: export(9), remoteArchive: peer.outboundArchive(), device: "local")
        var restarted = try LearningImportJournal.restore(journal.persistedData())
        XCTAssertEqual(restarted.pending?.target.pendingResets.count, 1)
        XCTAssertEqual(restarted.pending?.target.model.entries[key]?.frequency, 0)
        XCTAssertThrowsError(try restarted.observeExport(export(10), device: "local"))
        XCTAssertEqual(restarted.pending?.target.pendingResets.count, 1)
        // Recovery reset/replacement succeeds; only its reread may acknowledge it.
        try restarted.commit(transactionID: intent.id, actualEngineExport: export(1))
        XCTAssertTrue(restarted.checkpoint.pendingResets.isEmpty)
        try restarted.observeExport(export(2), device: "local")
        XCTAssertEqual(frequency(restarted), 1)
    }
}
