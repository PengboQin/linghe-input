import XCTest
@testable import PrivateInputKit

final class LearnedVocabularyProjectionTests: XCTestCase {
    private func archive(_ body: (inout LearningModel) throws -> Void) throws -> Data {
        var model = try LearningModel(capacityProfile: LearningCapacityProfiles.expanded10000)
        try body(&model)
        return try model.export()
    }

    func testNormalWordsAndCounts() throws {
        let shared = try archive { model in
            try model.setDeviceCount(reading: "ling he", text: "灵鹤", device: "a", count: 7)
            try model.setDeviceCount(reading: "ni hao", text: "你好", device: "a", count: 3)
        }
        let rows = try LearnedVocabularyProjection.rows(shared: shared)
        XCTAssertEqual(rows.map(\.text), ["灵鹤", "你好"])
        XCTAssertEqual(rows.first?.frequency, 7)
    }

    func testDeletedAndZeroUnpinnedAreHiddenButPinnedZeroIsKept() throws {
        let shared = try archive { model in
            try model.setDeviceCount(reading: "shan chu", text: "删除", device: "a", count: 2)
            try model.forget(reading: "shan chu", text: "删除")
            try model.setDeviceCount(reading: "ling ci", text: "零次", device: "a", count: 0)
            try model.setPinned(reading: "zhi ding", text: "置顶", pinned: true, device: "a")
        }
        let rows = try LearnedVocabularyProjection.rows(shared: shared)
        XCTAssertEqual(rows.map(\.text), ["置顶"])
    }

    func testSameCounterIsNotAddedTwiceButDifferentDevicesAre() throws {
        let first = try archive { model in
            try model.setDeviceCount(reading: "ling he", text: "灵鹤", device: "a", count: 2)
        }
        let same = try archive { model in
            try model.setDeviceCount(reading: "ling he", text: "灵鹤", device: "a", count: 2)
        }
        XCTAssertEqual(try LearnedVocabularyProjection.rows(shared: first, checkpoint: same).first?.frequency, 2)
        let other = try archive { model in
            try model.setDeviceCount(reading: "ling he", text: "灵鹤", device: "b", count: 3)
        }
        XCTAssertEqual(try LearnedVocabularyProjection.rows(shared: first, checkpoint: other).first?.frequency, 5)
    }

    func testNewerDeletionWinsOverOlderActiveSnapshot() throws {
        let active = try archive { model in
            try model.setDeviceCount(reading: "ling he", text: "灵鹤", device: "a", count: 9)
        }
        let deleted = try archive { model in
            try model.forget(reading: "ling he", text: "灵鹤")
        }
        XCTAssertTrue(try LearnedVocabularyProjection.rows(shared: active, checkpoint: deleted).isEmpty)
        XCTAssertTrue(try LearnedVocabularyProjection.rows(shared: deleted, checkpoint: active).isEmpty)
    }

    func testSearchMatchesChineseAndPinyin() throws {
        let shared = try archive { model in
            try model.setDeviceCount(reading: "ling he", text: "灵鹤", device: "a", count: 2)
            try model.setDeviceCount(reading: "ni hao", text: "你好", device: "a", count: 1)
        }
        XCTAssertEqual(try LearnedVocabularyProjection.rows(shared: shared, query: "灵鹤").count, 1)
        XCTAssertEqual(try LearnedVocabularyProjection.rows(shared: shared, query: "NI HAO").first?.text, "你好")
        XCTAssertTrue(try LearnedVocabularyProjection.rows(shared: shared, query: "zzz").isEmpty)
    }

    func testEqualFrequenciesHaveStableOrder() throws {
        let shared = try archive { model in
            try model.setDeviceCount(reading: "yi", text: "乙", device: "a", count: 1)
            try model.setDeviceCount(reading: "jia", text: "甲", device: "a", count: 1)
        }
        XCTAssertEqual(try LearnedVocabularyProjection.rows(shared: shared).map(\.text), ["甲", "乙"])
        XCTAssertEqual(try LearnedVocabularyProjection.rows(shared: shared).map(\.text), ["甲", "乙"])
    }

    func testExplicitRelearnAfterForgetShowsAgain() throws {
        var model = try LearningModel(capacityProfile: LearningCapacityProfiles.expanded10000)
        try model.setDeviceCount(reading: "ling he", text: "灵鹤", device: "a", count: 4)
        try model.forget(reading: "ling he", text: "灵鹤")
        XCTAssertTrue(try LearnedVocabularyProjection.rows(shared: model.export()).isEmpty)
        let restored = try model.relearnDeleted(reading: "ling he", text: "灵鹤", device: "a",
                                                knownCloudGeneration: 0, cloudDeleted: true)
        XCTAssertTrue(restored)
        let rows = try LearnedVocabularyProjection.rows(shared: model.export())
        XCTAssertEqual(rows.first?.text, "灵鹤")
        XCTAssertEqual(rows.first?.frequency, 1)
    }

    func testBadArchiveThrows() {
        XCTAssertThrowsError(try LearnedVocabularyProjection.rows(shared: Data("not json".utf8)))
    }
}
