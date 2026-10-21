import AppKit
import XCTest
import PrivateInputKit

/// Run this suite in its own XCTest process: the native runtime deliberately
/// owns one isolated database per process, rather than switching user paths.
final class MacMixedInputPolicyTests:XCTestCase {
    private static let storage=FileManager.default.temporaryDirectory.appendingPathComponent("PrivateInput-MixedPolicy-"+UUID().uuidString)
    override class func tearDown() {
        pi_finalize();try? FileManager.default.removeItem(at:storage);super.tearDown()
    }
    private func engine(provider:@escaping(String)->[String])throws->NativeEngine {
        let resources=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"rime",withExtension:nil))
        let engine=NativeEngine(sharedResources:resources,storageBase:Self.storage,useSemantic:false,useLexicon:false,mixedEnglishProvider:provider)
        XCTAssertTrue(engine.ready);_ = engine.privacy(true);_ = engine.nineKey(false);_ = engine.setMixedEnglishEnabled(true)
        return engine
    }
    private func type(_ raw:String,engine:NativeEngine,before:String="",after:String="") {
        engine.clear();engine.resetPredictionContext();engine.setHostContext(SurroundingText(before:before,after:after))
        for key in raw.utf8 {_ = engine.key(Int32(key))}
    }
    func testChineseAbbreviationAndContextBeatProviderExactAndPrefixWithoutLosingEnglish()throws {
        for words in [["limit","limited"],["lim","limit"]] {
            var calls=0
            let engine=try engine(provider:{_ in calls+=1;return words});defer{engine.clear();engine.finish()}
            for context in [("",""),("请放到","去"),("","里面才对")] {
                type("lim",engine:engine,before:context.0,after:context.1)
                let count=calls,rows=engine.candidateBatch(offset:0,limit:32)
                XCTAssertNil(try XCTUnwrap(rows.first).latinInput)
                let chinese=try XCTUnwrap(rows.firstIndex{$0.text=="里面"})
                let english=try XCTUnwrap(rows.firstIndex{$0.text=="limit" && $0.latinInput != nil})
                XCTAssertLessThan(chinese,english)
                XCTAssertEqual(engine.displayedPreedit(reading:""),engine.preedit)
                XCTAssertEqual(engine.preedit,"li m");XCTAssertEqual(engine.rawInput,"lim")
                _ = engine.candidateBatch(offset:0,limit:8);_ = engine.displayedPreedit(reading:"")
                XCTAssertEqual(calls,count+1,"Provider must be cached for the current revision")
                let paged=engine.candidateBatch(offset:0,limit:5)+engine.candidateBatch(offset:5,limit:5)
                XCTAssertEqual(paged.map(\.text),Array(rows.prefix(10)).map(\.text))
                XCTAssertEqual(Set(rows.map{"\($0.index):\($0.text)"}).count,rows.count)
                XCTAssertEqual(engine.chooseCandidate(rows[english]),"limit","English stays explicitly selectable")
                XCTAssertEqual(engine.chooseCandidate(rows[english]),"")
                print("MIXED_POLICY lim provider=\(words) contextHan=\(!(context.0+context.1).isEmpty) head=\(rows.prefix(12).map(\.text))")
            }
        }
    }
    func testCuratedEnglishCompleteWordsAndApplePrefixRemainUsableAndEnglishModePassesThrough()throws {
        let engine=try engine(provider:{raw in raw.hasPrefix("ap") ? ["apple","apply"]:[raw]})
        defer{engine.clear();engine.finish()}
        for raw in ["apple","hello","app"] {
            type(raw,engine:engine,before:"我想输入")
            let rows=engine.candidateBatch(offset:0,limit:64)
            let word=try XCTUnwrap(rows.first{$0.text.lowercased()==raw && $0.latinInput != nil},raw)
            XCTAssertEqual(rows.first?.text,word.text,raw)
            XCTAssertEqual(engine.displayedPreedit(reading:""),raw,raw)
            XCTAssertFalse(engine.displayedPreedit(reading:"").contains(" "),raw)
            XCTAssertEqual(engine.chooseCandidate(word),word.text);XCTAssertTrue(engine.rawInput.isEmpty)
        }
        type("appl",engine:engine)
        let apple=try XCTUnwrap(engine.candidateBatch(offset:0,limit:64).first{$0.text=="apple" && $0.latinInput != nil})
        XCTAssertEqual(engine.chooseCandidate(apple),"apple")
        engine.clear();_ = engine.switchToEnglish(true)
        for key in "limit".utf8 {let result=engine.key(Int32(key));XCTAssertFalse(result.handled);XCTAssertTrue(result.commit.isEmpty)}
        XCTAssertTrue(engine.rawInput.isEmpty);XCTAssertTrue(engine.candidateBatch(offset:0,limit:32).isEmpty)
        _ = engine.switchToEnglish(false)
    }
    func testChineseFullSpellingAndInitialsDoNotBecomeLatinFromSystemGuesses()throws {
        let engine=try engine(provider:{raw in [raw,"limit","show","cancel"]})
        defer{engine.clear();engine.finish()}
        for raw in ["lim","lima","limian","nihao","shj","can"] {
            type(raw,engine:engine,before:"这句继续写",after:"才完整")
            let rows=engine.candidateBatch(offset:0,limit:64)
            XCTAssertNil(try XCTUnwrap(rows.first).latinInput,raw)
            XCTAssertEqual(engine.displayedPreedit(reading:""),engine.preedit,raw)
            XCTAssertTrue(rows.contains{$0.latinInput != nil},"Keep explicit English alternatives reachable: \(raw)")
            print("MIXED_POLICY chinese raw=\(raw) head=\(rows.prefix(10).map(\.text)) preedit=\(engine.displayedPreedit(reading:""))")
        }
    }
    func testSelectedChinesePrefixSurvivesMixedChoiceDisplayAndModeSwitch()throws {
        let engine=try engine(provider:{raw in raw=="lim" ? ["lim","limit"]:(raw=="apple" ? ["apple"]:[])})
        defer{engine.clear();engine.finish()}
        func selectPrefix(_ text:String)throws {
            let row=try XCTUnwrap(engine.candidateBatch(offset:0,limit:128).first{$0.text==text && $0.latinInput==nil})
            XCTAssertEqual(engine.chooseCandidate(row),"")
        }
        for finish in ["raw","english"] {
            type("nihaoshijielim",engine:engine)
            try selectPrefix("你好");try selectPrefix("世界")
            XCTAssertTrue(engine.displayedPreedit(reading:"").hasPrefix("你好世界"))
            XCTAssertEqual(engine.displayedPreedit(reading:""),engine.preedit)
            let rows=engine.candidateBatch(offset:0,limit:64)
            XCTAssertNil(try XCTUnwrap(rows.first).latinInput)
            if finish=="raw" {
                XCTAssertEqual(engine.switchToEnglish(true),"你好世界lim")
                _ = engine.switchToEnglish(false)
            } else {
                let word=try XCTUnwrap(rows.first{$0.text=="limit" && $0.latinInput=="lim"})
                XCTAssertEqual(engine.chooseCandidate(word),"你好世界limit");XCTAssertTrue(engine.rawInput.isEmpty)
            }
        }
        type("nihaoapple",engine:engine);try selectPrefix("你好")
        XCTAssertEqual(engine.displayedPreedit(reading:""),"你好apple")
        let apple=try XCTUnwrap(engine.candidateBatch(offset:0,limit:64).first{$0.text=="apple" && $0.latinInput != nil})
        XCTAssertEqual(engine.chooseCandidate(apple),"你好apple")
    }
}
