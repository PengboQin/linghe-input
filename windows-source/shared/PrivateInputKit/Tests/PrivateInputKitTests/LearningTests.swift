import XCTest
@testable import PrivateInputKit
final class LearningTests: XCTestCase {
    func testIndividuallyValidArchivesCannotGrowMergedUnionBeyondLimit() throws {
        let first = LearningArchive(entries: (0..<2501).map { LearningEntry(reading: "ni hao", text: "Synthetic-" + String($0)) })
        let second = LearningArchive(entries: (2501..<5001).map { LearningEntry(reading: "ni hao", text: "Synthetic-" + String($0)) })
        var model = LearningModel(); try model.merge(JSONEncoder().encode(first))
        XCTAssertThrowsError(try model.merge(JSONEncoder().encode(second)))
        XCTAssertEqual(model.entries.count, 2501)
    }
    func testValidArchivesCannotMakePersistedUnionExceedByteLimit() throws {
        let prefix = String(repeating: "x", count: 600)
        let first = LearningArchive(entries: (0..<1500).map { LearningEntry(reading: "ni hao", text: prefix + String($0)) })
        let second = LearningArchive(entries: (1500..<3000).map { LearningEntry(reading: "ni hao", text: prefix + String($0)) })
        var model = LearningModel(); try model.merge(JSONEncoder().encode(first))
        let original = try model.export()
        XCTAssertThrowsError(try model.merge(JSONEncoder().encode(second)))
        XCTAssertEqual(try model.export(), original)
    }
    func testRepeatedImportDoesNotDoubleFrequency() throws {
        var a = LearningModel(), b = LearningModel()
        try a.record(reading: "ni hao", text: "你好", device: "mac")
        let archive = try a.export(); try b.merge(archive); try b.merge(archive)
        XCTAssertEqual(b.entries.values.first?.frequency, 1)
    }
    func testConcurrentDevicesConverge() throws {
        var a = LearningModel(), b = LearningModel()
        try a.record(reading: "ni hao", text: "你好", device: "mac")
        try b.record(reading: "ni hao", text: "你好", device: "ios")
        let first = try a.export(); try a.merge(b.export()); try b.merge(first)
        XCTAssertEqual(a.entries, b.entries)
        XCTAssertEqual(a.entries.values.first?.frequency, 2)
    }
    func testDeleteDoesNotResurrectFromOldSnapshot() throws {
        var a = LearningModel(), b = LearningModel()
        try a.record(reading: "ci ku", text: "词库", device: "mac")
        let old = try a.export(), id = try XCTUnwrap(a.entries.keys.first)
        try b.merge(old); a.remove(id: id)
        try a.merge(old); try b.merge(a.export())
        XCTAssertTrue(try XCTUnwrap(a.entries[id]).deleted)
        XCTAssertEqual(a.entries, b.entries)
    }
    func testExplicitRestoreHasNewGeneration() throws {
        var a = LearningModel()
        try a.record(reading: "ci ku", text: "词库", device: "mac")
        let id = try XCTUnwrap(a.entries.keys.first); a.remove(id: id)
        let removed = try a.export(); try a.restore(id: id); try a.merge(removed)
        XCTAssertFalse(try XCTUnwrap(a.entries[id]).deleted)
        XCTAssertEqual(a.entries[id]?.generation, 1)
    }
    func testPrivateModeDoesNotLearn() throws {
        var a = LearningModel(); a.learningEnabled = false
        try a.record(reading: "yin si", text: "隐私", device: "mac")
        XCTAssertTrue(a.entries.isEmpty)
    }
    func testInvalidSnapshotIsAtomic() throws {
        var a = LearningModel()
        try a.record(reading: "ni", text: "你", device: "mac")
        let before = a.entries
        let data = try JSONEncoder().encode(LearningArchive(entries: [LearningEntry(reading: "hao", text: "好"), LearningEntry(reading: "bad123", text: "测试")]))
        XCTAssertThrowsError(try a.merge(data)); XCTAssertEqual(a.entries, before)
    }
    func testDuplicateEntriesRejected() throws {
        let entry = LearningEntry(reading: "ni", text: "你")
        var a = LearningModel()
        XCTAssertThrowsError(try a.merge(JSONEncoder().encode(LearningArchive(entries: [entry, entry]))))
        XCTAssertTrue(a.entries.isEmpty)
    }
    func testFutureSchemaRejected() throws {
        var archive = LearningArchive(entries: []); archive.version = 2
        var a = LearningModel()
        XCTAssertThrowsError(try a.merge(JSONEncoder().encode(archive)))
    }
    func testMergeOrderIsIndependentOfWallClock() throws {
        let one = LearningEntry(reading: "ni", text: "你", pinned: true, pinVersion: .init(sequence: 3, device: "mac"))
        let two = LearningEntry(reading: "ni", text: "你", pinned: false, pinVersion: .init(sequence: 3, device: "win"))
        XCTAssertEqual(try one.merging(two), try two.merging(one))
    }
}
