import XCTest
@testable import PrivateInputKit
final class InputCoverageTests:XCTestCase {
    func testEnglishNeighborOmissionInsertionAndSwapShareOneRepairPath() {
        for raw in ["aoole","applr","aplpe","aple","appple"] {
            XCTAssertTrue(EnglishWordSuggestions.suggestions(prefix:raw,completions:[]).contains("apple"),raw)
            XCTAssertTrue(MixedEnglishLexicon.suggestions(input:raw,nineKey:false).contains("apple"),raw)
        }
        XCTAssertTrue(EnglishWordSuggestions.suggestions(prefix:"aoole",completions:["aoolelong"],guesses:[]).contains("apple"))
        XCTAssertTrue(EnglishWordSuggestions.suggestions(prefix:"AOOLE",completions:[]).contains("APPLE"))
        XCTAssertTrue(EnglishWordSuggestions.suggestions(prefix:"https://",completions:["apple"]).isEmpty)
        XCTAssertNil(EnglishWordSuggestions.correctionCost("abc","world"))
    }
    func testPinyinAliasesAreSyllableScopedAndPersonalWordsShareTheReading() throws {
        for raw in ["lve","lue","lüe"] {
            XCTAssertTrue(PinyinInputMatch.isFullSpelling(raw,reading:"lve"))
            XCTAssertTrue(PinyinInputMatch.covers(raw,reading:"lve",maxAbbreviations:0))
        }
        for raw in ["nve","nue","nüe"] {XCTAssertTrue(PinyinInputMatch.isFullSpelling(raw,reading:"nve"))}
        XCTAssertFalse(PinyinInputMatch.isFullSpelling("lu",reading:"lv"))
        XCTAssertFalse(PinyinInputMatch.isFullSpelling("nu",reading:"nv"))
        XCTAssertTrue(PinyinInputMatch.isFullSpelling("luen",reading:"lu en"))
        var personal=PersonalLexicon();try personal.upsert(.init(kind:.word,text:"略",trigger:"lue"),syllables:["lve"])
        XCTAssertEqual(personal.matches(input:"lve",nineKey:false).map(\.text),["略"])
        XCTAssertEqual(personal.matches(input:"lue",nineKey:false).map(\.text),["略"])
    }
    func testMixedInitialsFullSpellingsAndPrefixConsumption() {
        for n in 2...12 {
            let text=String(repeating:"h",count:n)+"haode",reading=Array(repeating:"ha",count:n).joined(separator:" ")+" hao de"
            XCTAssertEqual(PinyinInputMatch.consumedPrefix(text,reading:reading,nineKey:false),text.count)
            let code=NineKeySpelling.encode(text)!
            XCTAssertEqual(PinyinInputMatch.consumedPrefix(code,reading:reading,nineKey:true),code.count)
            let prefix=Array(repeating:"ha",count:n).joined(separator:" ")
            XCTAssertLessThan(PinyinInputMatch.consumedPrefix(code,reading:prefix,nineKey:true) ?? code.count,code.count)
        }
        XCTAssertEqual(PinyinInputMatch.consumedPrefix("44444426",reading:"ha ha ha ha ha hao",nineKey:true),8)
        XCTAssertLessThan(PinyinInputMatch.consumedPrefix("44444426",reading:"ha ha ha ha ha ha ha",nineKey:true) ?? 0,8)
        XCTAssertNil(PinyinInputMatch.consumedPrefix("968",reading:"wo bu",nineKey:true))
    }
    func testEnglishCompletionCaseFilteringAndOfflineFallback() {
        for (prefix,word) in [("hel","hello"),("Hel","Hello"),("HEL","HELLO")] {
            XCTAssertTrue(EnglishWordSuggestions.suggestions(prefix:prefix,completions:[]).contains(word))
        }
        XCTAssertEqual(EnglishWordSuggestions.suggestions(prefix:"wrold",completions:[],guesses:["world","网址","world.com"]),["world"])
        XCTAssertTrue(EnglishWordSuggestions.suggestions(prefix:"a@b",completions:["apple"]).isEmpty)
        XCTAssertFalse(EnglishWordSuggestions.suggestions(prefix:"hel",completions:["hello","help","hello","hello\nsecret"]).contains(where:{$0.contains("\n")}))
    }
}
