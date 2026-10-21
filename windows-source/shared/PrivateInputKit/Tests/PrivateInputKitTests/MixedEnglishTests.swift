import XCTest
@testable import PrivateInputKit

final class MixedEnglishTests:XCTestCase {
    func testCanonicalNamesExactWordsAndBoundedCompletions() {
        XCTAssertEqual(MixedEnglishLexicon.suggestions(input:"api",nineKey:false).first,"API")
        XCTAssertEqual(MixedEnglishLexicon.suggestions(input:"review",nineKey:false).first,"review")
        XCTAssertTrue(MixedEnglishLexicon.suggestions(input:"rev",nineKey:false).contains("review"))
        let result=MixedEnglishLexicon.suggestions(input:"app",nineKey:false,systemWords:["APP","application","apple","applicant","apply"])
        XCTAssertEqual(result.first,"App");XCTAssertLessThanOrEqual(result.count,4);XCTAssertEqual(Set(result.map{$0.lowercased()}).count,result.count)
    }
    func testNineKeyIsExactAndExplicitPinyinNeverTurnsIntoEnglish() {
        for word in ["API","PDF","hello","review","Swift"] {
            let code=NineKeySpelling.encode(word)!
            XCTAssertTrue(MixedEnglishLexicon.suggestions(input:code,nineKey:true).contains(word))
        }
        XCTAssertTrue(MixedEnglishLexicon.suggestions(input:"968",nineKey:true).isEmpty,"Common Chinese you must not compete with a short English word")
        XCTAssertTrue(MixedEnglishLexicon.suggestions(input:"he'556",nineKey:true).isEmpty)
        XCTAssertTrue(MixedEnglishLexicon.suggestions(input:"43'556",nineKey:true).isEmpty)
        XCTAssertTrue(MixedEnglishLexicon.suggestions(input:"4355",nineKey:true).isEmpty,"No guessed T9 prefix completions")
    }
    func testForeignResultsAreValidatedAndNeverBecomeArbitraryText() {
        XCTAssertEqual(MixedEnglishLexicon.suggestions(input:"rev",nineKey:false,systemWords:["你好","wrong","rev\nsecret","rev.example","review"]),["review"])
        for input in ["", "a", "ni'hao", "ＡPI", "api1", String(repeating:"a",count:33)] {
            XCTAssertTrue(MixedEnglishLexicon.suggestions(input:input,nineKey:false).isEmpty)
        }
        XCTAssertTrue(MixedEnglishLexicon.words.allSatisfy(MixedEnglishLexicon.validWord))
    }
}
