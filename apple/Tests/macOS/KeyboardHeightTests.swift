import XCTest

final class KeyboardHeightTests: XCTestCase {
    func testCorruptValuesClampAndSnapWithoutGrowingPastPresets() {
        XCTAssertEqual(KeyboardHeight.normalized(.nan), 48)
        XCTAssertEqual(KeyboardHeight.normalized(.infinity), 48)
        XCTAssertEqual(KeyboardHeight.normalized(-100), 0)
        XCTAssertEqual(KeyboardHeight.normalized(999), 96)
        XCTAssertEqual(KeyboardHeight.normalized(51), 52)
    }
    func testPresetsIncreaseKeySpaceAndCompactUsesHalfTheAddition() {
        let portrait = KeyboardHeight.presets.map { KeyboardHeight.height(extra:$0.extra,compact:false,tablet:false,viewportHeight:852) }
        let compact = KeyboardHeight.presets.map { KeyboardHeight.height(extra:$0.extra,compact:true,tablet:false,viewportHeight:393) }
        XCTAssertEqual(portrait, [232,280,328])
        XCTAssertEqual(compact, [164,188,212])
        XCTAssertLessThan(compact.last!,393*0.58)
        XCTAssertLessThanOrEqual(KeyboardHeight.height(extra:96,compact:false,tablet:true,viewportHeight:500), 500*0.58)
    }
}
