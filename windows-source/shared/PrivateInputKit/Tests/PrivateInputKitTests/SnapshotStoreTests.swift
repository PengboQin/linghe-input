import XCTest
@testable import PrivateInputKit

final class SnapshotStoreTests: XCTestCase {
    func testUnchangedPublicationPreservesFileIdentity() throws {
        let path=try directory();defer {try? FileManager.default.removeItem(at:path)}
        let store=SharedLearningSnapshot(directory:path)
        var model=LearningModel();try model.record(reading:"ni hao",text:"你好",device:"synthetic")
        try store.publish(model.export(),by:.containingApp)
        let file=path.appendingPathComponent("learning-v1.json")
        let before=try FileManager.default.attributesOfItem(atPath:file.path)
        try store.publish(model.export(),by:.containingApp)
        let after=try FileManager.default.attributesOfItem(atPath:file.path)
        XCTAssertEqual(before[.systemFileNumber] as? NSNumber,after[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(before[.modificationDate] as? Date,after[.modificationDate] as? Date)
    }
    func testLateContainingAppPublicationCannotOverwriteKeyboardLearning() throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let store = SharedLearningSnapshot(directory: path)
        var app = LearningModel(), keyboard = LearningModel()
        try app.record(reading: "ni hao", text: "你好", device: "app")
        try keyboard.record(reading: "ni hao", text: "拟好", device: "keyboard")
        try store.publish(keyboard.export(), by: .keyboard(fullAccess: true))
        try store.publish(app.export(), by: .containingApp)
        var merged = LearningModel(); try merged.merge(XCTUnwrap(store.read()))
        XCTAssertEqual(merged.entries.count, 2)
        try store.publish(app.export(), by: .containingApp)
        XCTAssertEqual(try store.read(), try merged.export())
    }
    func testOversizedDiskSnapshotIsBoundedAndRejectedWithoutWriting() throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let file = path.appendingPathComponent("learning-v1.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 16 * 1024 * 1024); try handle.close()
        XCTAssertThrowsError(try SharedLearningSnapshot(directory: path).read()) { error in
            guard case InputDataError.oversized = error else { return XCTFail("Expected bounded-size rejection") }
        }
        XCTAssertEqual(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, 16 * 1024 * 1024)
    }
    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("PrivateInput-Snapshot-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true); return path
    }
    func testDeniedKeyboardWriteLeavesOriginalSnapshotUntouched() throws {
        let path = try directory();defer { try? FileManager.default.removeItem(at: path) }
        let store = SharedLearningSnapshot(directory: path)
        var first = LearningModel();try first.record(reading: "ni hao", text: "你好", device: "mac")
        try store.publish(first.export(), by: .containingApp)
        let original = try XCTUnwrap(store.read())
        var second = LearningModel();try second.record(reading: "ci ku", text: "词库", device: "ios")
        XCTAssertThrowsError(try store.publish(second.export(), by: .keyboard(fullAccess: false)))
        XCTAssertEqual(try store.read(), original)
    }
    func testDeniedWriteDoesNotCreateDirectoryOrFile() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("PrivateInput-Denied-" + UUID().uuidString)
        let store = SharedLearningSnapshot(directory: path)
        XCTAssertThrowsError(try store.publish(LearningModel().export(), by: .keyboard(fullAccess: false)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }
    func testMalformedRemoteArchiveCannotReplaceLastValidSnapshot() throws {
        let path = try directory();defer { try? FileManager.default.removeItem(at: path) }
        let store = SharedLearningSnapshot(directory: path)
        try store.publish(LearningModel().export(), by: .containingApp)
        let original = try store.read()
        XCTAssertThrowsError(try store.publish(Data("broken".utf8), by: .containingApp))
        XCTAssertEqual(try store.read(), original)
    }
    func testFullAccessKeyboardCanPublishValidatedArchive() throws {
        let path = try directory();defer { try? FileManager.default.removeItem(at: path) }
        let store = SharedLearningSnapshot(directory: path)
        var model = LearningModel();try model.record(reading: "ni hao", text: "你好", device: "ios")
        try store.publish(model.export(), by: .keyboard(fullAccess: true))
        var restored = LearningModel();try restored.merge(XCTUnwrap(store.read()))
        XCTAssertEqual(restored.entries, model.entries)
    }
}
