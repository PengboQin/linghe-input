import XCTest
@testable import PrivateInputKit

final class RimeCheckpointTests: XCTestCase {
    func testExplicitResetKeepsWordPinAndRejectsOldFrequency() throws {
        var state = RimeLearningCheckpoint()
        try state.observeExport(Data("拟好\tni hao\t12\n".utf8), device: "ios")
        try state.setPinned(reading: "ni hao", text: "拟好", pinned: true, device: "ios")
        let old = try state.outboundArchive()
        try state.resetFrequency(reading: "ni hao", text: "拟好")
        try state.mergeRemoteArchive(old)
        try state.observeExport(Data("拟好\tni hao\t13\n".utf8), device: "ios")
        XCTAssertEqual(state.model.entries.values.first?.frequency, 0)
        XCTAssertEqual(state.model.entries.values.first?.pinned, true)
        XCTAssertEqual(state.pendingResets.count, 1)
        XCTAssertFalse(String(decoding: try state.engineImport(), as: UTF8.self).contains("拟好"))
        try state.establishBaselineAfterImport(Data("拟好\tni hao\t1\n".utf8))
        try state.observeExport(Data("拟好\tni hao\t2\n".utf8), device: "ios")
        XCTAssertEqual(state.model.entries.values.first?.frequency, 1)
        XCTAssertTrue(state.pendingResets.isEmpty)
        var peer = RimeLearningCheckpoint(); try peer.mergeRemoteArchive(old); try peer.mergeRemoteArchive(state.outboundArchive())
        XCTAssertEqual(peer.model.entries, state.model.entries)
    }
    func testPinChangeRemainsIndependentOfFrequencyResetGeneration() throws {
        var one = RimeLearningCheckpoint(), two = RimeLearningCheckpoint()
        try one.setPinned(reading: "shi", text: "是", pinned: true, device: "a")
        try two.mergeRemoteArchive(one.outboundArchive())
        try one.resetFrequency(reading: "shi", text: "是")
        try two.setPinned(reading: "shi", text: "是", pinned: false, device: "b")
        let newer = try one.outboundArchive(), offline = try two.outboundArchive()
        try one.mergeRemoteArchive(offline); try two.mergeRemoteArchive(newer)
        XCTAssertEqual(one.model.entries, two.model.entries)
        XCTAssertEqual(one.model.entries.values.first?.generation, 1)
        XCTAssertEqual(one.model.entries.values.first?.pinned, false)
    }
    func testOldCheckpointDecodesAndPinVersionAdvancesAcrossPeerMerge() throws {
        let state = try JSONDecoder().decode(RimeLearningCheckpoint.self, from: Data("{\"model\":{\"entries\":{},\"learningEnabled\":true},\"observedCounts\":{}}".utf8))
        XCTAssertTrue(state.pendingResets.isEmpty)
        var one = state, two = state
        try one.setPinned(reading: "shi", text: "是", pinned: true, device: "ios")
        try two.mergeRemoteArchive(one.outboundArchive())
        try two.setPinned(reading: "shi", text: "是", pinned: false, device: "mac")
        try one.mergeRemoteArchive(two.outboundArchive())
        XCTAssertEqual(one.model.entries, two.model.entries)
        XCTAssertEqual(one.model.entries.values.first?.pinned, false)
    }
    func testImportedFrequencyIsNotCountedAsLocalTyping() throws {
        var mac = RimeLearningCheckpoint(), ios = RimeLearningCheckpoint()
        try mac.observeExport(Data("你好\tni hao\t2\n".utf8), device: "mac")
        try ios.observeExport(Data("你好\tni hao\t3\n".utf8), device: "ios")
        try mac.mergeRemoteArchive(ios.outboundArchive())
        try mac.establishBaselineAfterImport(Data("你好\tni hao\t5\n".utf8))
        try mac.observeExport(Data("你好\tni hao\t5\n".utf8), device: "mac")
        XCTAssertEqual(mac.model.entries.values.first?.frequency, 5)
        try mac.observeExport(Data("你好\tni hao\t6\n".utf8), device: "mac")
        XCTAssertEqual(mac.model.entries.values.first?.counts["mac"], 3)
        XCTAssertEqual(mac.model.entries.values.first?.counts["ios"], 3)
    }
    func testRepeatedEngineCheckpointDoesNotDoubleCount() throws {
        var value = RimeLearningCheckpoint(); let data = Data("你好\tni hao\t2\n".utf8)
        try value.observeExport(data, device: "mac"); try value.observeExport(data, device: "mac")
        XCTAssertEqual(value.model.entries.values.first?.frequency, 2)
    }
    func testEngineMetadataIsNeverInOutboundArchive() throws {
        var value = RimeLearningCheckpoint()
        try value.observeExport(Data("#@/user_id=synthetic-engine-owner\n你好\tni hao\t1\n".utf8), device: "mac")
        XCTAssertFalse(String(decoding: try value.outboundArchive(), as: UTF8.self).contains("synthetic-engine-owner"))
    }
    func testMalformedRowsRejectWholeObservation() throws {
        var value = RimeLearningCheckpoint()
        XCTAssertThrowsError(try value.observeExport(Data("你好\tni hao\t1\n坏行\tcode\tNaN\n".utf8), device: "mac"))
        XCTAssertTrue(value.model.entries.isEmpty)
    }
    func testZeroCommitNativeRowsDoNotConsumeLearnedWordCapacity() throws {
        var lines = (0..<5100).map { "缓存\($0)\tni\t0" }
        lines.append("你好\tni hao\t2")
        let bytes = Data((lines.joined(separator: "\n") + "\n").utf8)
        XCTAssertEqual(try RimeLearningFormat.parseExport(bytes).count, 5101)
        var journal = try LearningImportJournal()
        try journal.observeExport(bytes, device: "local")
        XCTAssertEqual(journal.checkpoint.model.entries.count, 1)
        XCTAssertEqual(journal.checkpoint.observedCounts, ["ni hao\u{001F}你好": 2])
        let restored = try LearningImportJournal.restore(journal.persistedData())
        XCTAssertEqual(restored.checkpoint.model.entries, journal.checkpoint.model.entries)
        try journal.observeExport(bytes, device: "local")
        XCTAssertEqual(journal.checkpoint.model.entries.values.first?.frequency, 2)
    }
    func testZeroBaselineCompactionPreservesCounterRestartAndImportProof() throws {
        var value = RimeLearningCheckpoint()
        try value.observeExport(Data("你好\tni hao\t4\n".utf8), device: "local")
        try value.observeExport(Data("你好\tni hao\t0\n".utf8), device: "local")
        XCTAssertEqual(value.model.entries.values.first?.frequency, 4)
        XCTAssertTrue(value.observedCounts.isEmpty)
        try value.observeExport(Data("你好\tni hao\t1\n".utf8), device: "local")
        XCTAssertEqual(value.model.entries.values.first?.frequency, 5)
        try value.observeExport(Data("你好\tni hao\t1\n".utf8), device: "local")
        XCTAssertEqual(value.model.entries.values.first?.frequency, 5)
        try value.establishBaselineAfterImport(Data("你好\tni hao\t0\n".utf8))
        XCTAssertTrue(value.observedCounts.isEmpty)
        XCTAssertEqual(value.appliedGenerations?["ni hao\u{001F}你好"], 0)
    }
    func testZeroRowsRemainStrictAndPositiveCapacityRemainsBounded() throws {
        var value = RimeLearningCheckpoint()
        try value.observeExport(Data("你好\tni hao\t2\n".utf8), device: "local")
        let previous = value.model.entries, baseline = value.observedCounts
        for bad in ["坏行\tni\tNaN\n", "坏行\tni2\t0\n", "重复\tni\t0\n重复\tni\t0\n"] {
            XCTAssertThrowsError(try value.observeExport(Data(bad.utf8), device: "local"))
            XCTAssertEqual(value.model.entries, previous)
            XCTAssertEqual(value.observedCounts, baseline)
        }
        let positives = (0..<5001).map { "确认\($0)\tni\t1" }.joined(separator: "\n")
        XCTAssertThrowsError(try value.observeExport(Data(positives.utf8), device: "local"))
        XCTAssertEqual(value.model.entries, previous)
    }
    func testTSVInjectionCannotReachEngine() throws {
        var model = LearningModel()
        XCTAssertThrowsError(try model.record(reading: "ni", text: "你\n恶意\tma\t999", device: "mac"))
        XCTAssertTrue(model.entries.isEmpty)
    }
    func testCountResetDoesNotSubtractExistingPersonalFrequency() throws {
        var value = RimeLearningCheckpoint()
        try value.observeExport(Data("你好\tni hao\t4\n".utf8), device: "mac")
        try value.observeExport(Data("你好\tni hao\t1\n".utf8), device: "mac")
        XCTAssertEqual(value.model.entries.values.first?.frequency, 4)
    }
}
