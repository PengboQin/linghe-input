import XCTest
import CoreText

final class CandidateGlyphSupportTests:XCTestCase {
    func testRealGlyphsAndMissingGlyphsAreDistinguished() {
        for text in ["你好","定","apple","?","😀","👨‍👩‍👧‍👦","❤️","1.4"] {XCTAssertTrue(CandidateGlyphSupport.supports(text),text)}
        let missing=CTFontCreateWithName("LastResort" as CFString,15,nil)
        XCTAssertFalse(CandidateGlyphSupport.supports("𨈖",font:missing))
        XCTAssertFalse(CandidateGlyphSupport.supports("你好𨈖",font:missing))
        XCTAssertFalse(CandidateGlyphSupport.supports(""))
    }
    func testFilteredPagesFillHolesPreserveIDsAndReachLastRow() {
        let input=Array(0..<180);var page=CandidateVisibilityPage<Int>()
        let source:(Int,Int)->[Int]={offset,count in Array(input.dropFirst(offset).prefix(count))}
        let accept:(Int)->Bool={$0>=70 && $0%3 != 0}
        let expected=input.filter(accept)
        XCTAssertEqual(page.slice(offset:0,limit:12,accept:accept,source:source),Array(expected.prefix(12)))
        XCTAssertEqual(page.slice(offset:12,limit:48,accept:accept,source:source),Array(expected.dropFirst(12).prefix(48)))
        XCTAssertEqual(page.slice(offset:0,limit:12,accept:accept,source:source),Array(expected.prefix(12)))
        XCTAssertEqual(page.slice(offset:60,limit:48,accept:accept,source:source),Array(expected.dropFirst(60)))
        XCTAssertTrue(page.exhausted);XCTAssertEqual(page.rows,expected)
        var none=CandidateVisibilityPage<Int>()
        XCTAssertEqual(none.slice(offset:0,limit:12,accept:{_ in false},source:source),[])
        XCTAssertTrue(none.exhausted);XCTAssertEqual(none.sourceOffset,180)
    }
}
