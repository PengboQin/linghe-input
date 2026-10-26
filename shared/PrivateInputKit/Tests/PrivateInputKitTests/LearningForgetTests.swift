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
}
