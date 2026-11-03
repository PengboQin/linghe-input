import XCTest
@testable import PrivateInputKit

final class LearnedVocabularyReaderTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("learned-reader-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testCapturedCredentialDetectsResetAfterRead() throws {
        let root = try directory()
        var model = try LearningModel(capacityProfile: LearningCapacityProfiles.expanded10000)
        try model.setDeviceCount(reading: "ling he", text: "灵鹤", device: "a", count: 3)
        try SharedLearningSnapshot(directory: root).publish(model.export(), by: .containingApp)

        let read = try LearnedVocabularyReader.read(directory: root)
        XCTAssertEqual(read.rows.first?.text, "灵鹤")
        XCTAssertTrue(read.published)
        try read.requireCurrent()

        try Data(UUID().uuidString.utf8).write(to: root.appendingPathComponent("privacy-reset-generation-v1.txt"))
        XCTAssertThrowsError(try read.requireCurrent()) { error in
            guard case InputDataError.invalidRecord = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testMissingSnapshotIsEmptyButNotPublished() throws {
        let root = try directory()
        let read = try LearnedVocabularyReader.read(directory: root)
        XCTAssertTrue(read.rows.isEmpty)
        XCTAssertFalse(read.published)
        XCTAssertNoThrow(try read.requireCurrent())
    }

    func testCorruptSnapshotThrows() throws {
        let root = try directory()
        try Data("not json".utf8).write(to: root.appendingPathComponent("learning-v1.json"))
        XCTAssertThrowsError(try LearnedVocabularyReader.read(directory: root))
    }
}
