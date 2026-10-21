import XCTest
@testable import PrivateInputKit
final class PinyinCorrectionTests:XCTestCase {
    func testLongSpellingRetainsSingleOmissionWithinBoundedBeam() throws {
        var root=URL(fileURLWithPath:#filePath)
        for _ in 0..<5 {root.deleteLastPathComponent()}
        let text=try String(contentsOf:root.appendingPathComponent("resources/semantic/pinyin-syllables.txt"))
        let decoder=PinyinCorrection(syllables:Set(text.split(separator:"\n").map(String.init)))
        let input="shshenme"+String(repeating:"shishenme",count:9)
        let start=Date.timeIntervalSinceReferenceDate,rows=decoder.proposals(input)
        print("SYNTHETIC_PINYIN_LONG_PLAN_MS=\((Date.timeIntervalSinceReferenceDate-start)*1000)")
        XCTAssertLessThanOrEqual(rows.count,64)
        XCTAssertTrue(rows.contains{$0.spelling==String(repeating:"shishenme",count:10)})
    }
    func testMissingExtraAndSwappedLettersAcrossWords() {
        let decoder=PinyinCorrection(syllables:["shi","shen","me","ni","hao","wo","men","jin","tian","you","xie","yin","su"])
        for (bad,good) in [("shshenme","shishenme"),("shishenmee","shishenme"),("sihshenme","shishenme")] {
            XCTAssertTrue(decoder.proposals(bad).contains{$0.spelling==good},bad)
        }
        XCTAssertTrue(decoder.proposals("woenjitian").contains{$0.spelling=="womenjintian"})
        XCTAssertTrue(decoder.proposals("shshenme?").isEmpty)
        XCTAssertTrue(decoder.proposals(String(repeating:"a",count:97)).isEmpty)
    }
}
