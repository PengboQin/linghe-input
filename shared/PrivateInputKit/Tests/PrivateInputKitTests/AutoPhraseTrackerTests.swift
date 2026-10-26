import XCTest
@testable import PrivateInputKit

final class AutoPhraseTrackerTests: XCTestCase {
    func testWholeAndSegmentedSelections() {
        var t = AutoPhraseTracker()
        t.selected(prefix: "", text: "灵鹤", reading: "ling he"); XCTAssertEqual(t.committed("灵鹤"), "ling he")
        XCTAssertNil(t.committed("灵鹤"))
        t.selected(prefix: "", text: "灵", reading: "ling"); XCTAssertNil(t.committed(""))
        t.selected(prefix: "灵", text: "鹤", reading: "he"); XCTAssertEqual(t.committed("灵鹤"), "ling he")
    }
    func testNeverGuesses() {
        var t = AutoPhraseTracker()
        t.selected(prefix: "", text: "灵", reading: "ling"); t.selected(prefix: "凌", text: "鹤", reading: "he"); XCTAssertNil(t.committed("灵鹤"))
        t.selected(prefix: "", text: "灵", reading: "ling"); XCTAssertNil(t.committed("灵河"))
        t.selected(prefix: "", text: "灵鹤", reading: " "); XCTAssertNil(t.committed("灵鹤"))
        t.selected(prefix: "", text: "灵", reading: "ling"); t.reset(); t.selected(prefix: "灵", text: "鹤", reading: "he"); XCTAssertNil(t.committed("灵鹤"))
    }
}
