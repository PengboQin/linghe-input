import XCTest
@testable import PrivateInputKit

/// Cross-device forget mirrors Android: a deletion strictly above local and known cloud generations.
final class LearningForgetTests: XCTestCase {
    private func entry(_ model: LearningModel, _ reading: String, _ text: String) -> LearningEntry? {
        model.entries[LearningEntry(reading: reading, text: text).id]
    }
    func testForgetAboveCloudGenerationClearsCounts() throws {
        var model = LearningModel()
        try model.setDeviceCount(reading: "ling he", text: "灵鹤", device: "A", count: 7)
        try model.forget(reading: "ling he", text: "灵鹤", knownCloudGeneration: 2)
        let gone = try XCTUnwrap(entry(model, "ling he", "灵鹤"))
        XCTAssertTrue(gone.deleted); XCTAssertEqual(gone.generation, 3); XCTAssertEqual(gone.frequency, 0)
    }
    func testForgetTermNeverLearnedLocallyAndRepeatMovesForward() throws {
        var model = LearningModel()
        try model.forget(reading: "ling cha", text: "另差")
        XCTAssertEqual(entry(model, "ling cha", "另差")?.generation, 1)
        XCTAssertEqual(entry(model, "ling cha", "另差")?.deleted, true)
        try model.forget(reading: "ling cha", text: "另差")
        XCTAssertEqual(entry(model, "ling cha", "另差")?.generation, 2)
    }
    func testRelearnAfterForgetUsesNewerGenerationAndExports() throws {
        var model = LearningModel()
        try model.setDeviceCount(reading: "ling he", text: "灵鹤", device: "A", count: 3)
        try model.forget(reading: "ling he", text: "灵鹤")
        try model.restore(id: LearningEntry(reading: "ling he", text: "灵鹤").id)
        let back = try XCTUnwrap(entry(model, "ling he", "灵鹤"))
        XCTAssertFalse(back.deleted); XCTAssertEqual(back.generation, 2)
        XCTAssertNoThrow(try model.export())
    }
    func testForgetUsesCloudTombstoneAndSuppressesStaleWeight() throws {
        // Decode the persisted projection to exercise the same public format
        // that the platform coordinator reads, including a server-only fence.
        let data = Data(#"{"weights":{"ling he\u001f灵鹤":9000},"generations":{"ling he\u001f灵鹤":7},"deleted":[],"represented":{}}"#.utf8)
        let projection = try JSONDecoder().decode(CloudLearningRankProjection.self, from: data)
        XCTAssertEqual(projection.generation(reading: "LING HE", text: "灵鹤"), 7)
        XCTAssertEqual(projection.generation(reading: "wei zhi", text: "未知"), 0)
        var model = LearningModel()
        try model.forget(reading: "ling he", text: "灵鹤", knownCloudGeneration: projection.generation(reading: "ling he", text: "灵鹤"))
        let gone = try XCTUnwrap(entry(model, "ling he", "灵鹤"))
        XCTAssertEqual(gone.generation, 8)
        XCTAssertEqual(try projection.scores(current: [UUID(): [gone]])[gone.id], 0)
    }

    func testRestartOldExportAndExplicitRelearn() throws {
        var state = RimeLearningCheckpoint()
        try state.forget(reading: "ling he", text: "灵鹤", knownCloudGeneration: 7)
        state = try RimeLearningCheckpoint.restore(state.persistedData())
        let old = Data("灵鹤\tling he\t40\n".utf8)
        try state.observeExport(old, device: "A")
        XCTAssertTrue(try XCTUnwrap(entry(state.model, "ling he", "灵鹤")).deleted)
        XCTAssertTrue(try state.relearnForgotten(reading: "ling he", text: "灵鹤", device: "A"))
        XCTAssertFalse(try state.relearnForgotten(reading: "ling he", text: "灵鹤", device: "A"))
        let row = try XCTUnwrap(entry(state.model, "ling he", "灵鹤"))
        XCTAssertEqual(row.generation, 9); XCTAssertEqual(row.frequency, 1)
        try state.observeExport(old, device: "A")
        XCTAssertEqual(entry(state.model, "ling he", "灵鹤")?.frequency, 1)
        try state.establishBaselineAfterImport(Data("灵鹤\tling he\t1\n".utf8))
        try state.observeExport(Data("灵鹤\tling he\t2\n".utf8), device: "A")
        XCTAssertEqual(entry(state.model, "ling he", "灵鹤")?.frequency, 2)
    }
    func testDefaultFrequencyOutranksCloudAndKeepsPin() throws {
        var model = LearningModel()
        try model.setPinned(reading: "ling he", text: "灵鹤", pinned: true, device: "A")
        try model.resetFrequency(reading: "ling he", text: "灵鹤", knownCloudGeneration: 7)
        let row = try XCTUnwrap(entry(model, "ling he", "灵鹤"))
        XCTAssertEqual(row.generation, 8); XCTAssertEqual(row.frequency, 0)
        XCTAssertTrue(row.pinned); XCTAssertFalse(row.deleted)
    }

    func testRelearnPassesNewerCloudDeletionFence() throws {
        var state = RimeLearningCheckpoint()
        try state.forget(reading: "ling he", text: "灵鹤", knownCloudGeneration: 7)
        XCTAssertTrue(try state.relearnForgotten(reading: "ling he", text: "灵鹤", device: "A", knownCloudGeneration: 12))
        let row = try XCTUnwrap(entry(state.model, "ling he", "灵鹤"))
        XCTAssertEqual(row.generation, 13); XCTAssertEqual(row.frequency, 1)
    }

    func testForgetPinnedTermAdvancesPinControl() throws {
        var model = LearningModel()
        try model.setPinned(reading: "ling he", text: "灵鹤", pinned: true, device: "A")
        let before = try XCTUnwrap(entry(model, "ling he", "灵鹤"))
        try model.forget(reading: "ling he", text: "灵鹤", device: "B")
        let after = try XCTUnwrap(entry(model, "ling he", "灵鹤"))
        XCTAssertFalse(after.pinned); XCTAssertTrue(after.pinVersion > before.pinVersion)
        XCTAssertEqual(after.pinVersion.device, "B")
        XCTAssertFalse(try after.merging(before).pinned)
    }

    func testCloudOnlyDeletionRequiresExplicitChoiceAndDoesNotResetActiveGeneration() throws {
        var state = RimeLearningCheckpoint()
        try state.observeExport(Data("灵鹤\tling he\t9\n".utf8), device: "A")
        XCTAssertEqual(entry(state.model, "ling he", "灵鹤")?.generation, 0)
        XCTAssertTrue(try state.relearnForgotten(reading: "ling he", text: "灵鹤", device: "A", knownCloudGeneration: 12, cloudDeleted: true))
        XCTAssertEqual(entry(state.model, "ling he", "灵鹤")?.generation, 13)
        XCTAssertEqual(entry(state.model, "ling he", "灵鹤")?.frequency, 1)
        XCTAssertFalse(try state.relearnForgotten(reading: "ling he", text: "灵鹤", device: "A", knownCloudGeneration: 12, cloudDeleted: true))
        XCTAssertEqual(entry(state.model, "ling he", "灵鹤")?.frequency, 1)
    }
    func testCloudOnlyDeletionWithNoLocalRowCanBeExplicitlyRelearned() throws {
        var state = RimeLearningCheckpoint()
        XCTAssertTrue(try state.relearnForgotten(reading: "ling he", text: "灵鹤", device: "A", knownCloudGeneration: 7, cloudDeleted: true))
        XCTAssertEqual(entry(state.model, "ling he", "灵鹤")?.generation, 8)
        XCTAssertEqual(entry(state.model, "ling he", "灵鹤")?.frequency, 1)
    }

}
