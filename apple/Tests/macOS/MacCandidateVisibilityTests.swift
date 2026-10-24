import XCTest
import PrivateInputKit

final class MacCandidateVisibilityTests:XCTestCase {
    private static let storage=FileManager.default.temporaryDirectory.appendingPathComponent("PrivateInput-GlyphVisibility-"+UUID().uuidString)
    override class func tearDown() {pi_finalize();try? FileManager.default.removeItem(at:storage);super.tearDown()}
    private func engine(accept:@escaping(String)->Bool={CandidateGlyphSupport.supports($0)})throws->NativeEngine {
        let e=NativeEngine(sharedResources:try XCTUnwrap(Bundle(for:Self.self).url(forResource:"rime",withExtension:nil)),storageBase:Self.storage,useSemantic:false,useLexicon:false,candidateIsDisplayable:accept)
        XCTAssertTrue(e.ready);_ = e.privacy(true)
        for c in "din".utf8 {_ = e.key(Int32(c))}
        return e
    }
    func testMainlandAdmissionExcludesRareGlyphAndKnownCompletionCommitsOnce()throws {
        let e=try engine();defer{e.clear();e.finish()}
        let rows=e.candidateBatch(offset:0,limit:64)
        XCTAssertFalse(rows.isEmpty);XCTAssertTrue(rows.allSatisfy{CandidateGlyphSupport.supports($0.text)})
        XCTAssertFalse(rows.contains{$0.text=="𨈖"},"Mainland admission applies independently of whether this OS has the glyph")
        let forged=InputCandidate(text:"𨈖",comment:"din",index:0,sourceInput:e.rawInput,generation:e.revision)
        XCTAssertEqual(e.chooseCandidate(forged),"");XCTAssertEqual(e.rawInput,"din")
        let word=try XCTUnwrap(rows.first{$0.text=="定"});XCTAssertEqual(e.chooseCandidate(word),"定");XCTAssertEqual(e.chooseCandidate(word),"")
    }
    func testFilteredPagesFillNativeHolesAndCannotCommitHiddenRow()throws {
        let source=try engine(accept:{_ in true});defer{source.clear();source.finish()}
        // Read beyond both requested pages before filtering. Display holes
        // legitimately pull later native rows into the second visible page.
        let original=source.candidateBatch(offset:0,limit:128),hidden=try XCTUnwrap(original.first{$0.text=="定"})
        XCTAssertFalse(original.contains{$0.text=="𨈖"},"A permissive font callback must not bypass the shared character policy")
        let banned=Set(["定","顶","灯"])
        let e=try engine(accept:{!banned.contains($0) && CandidateGlyphSupport.supports($0)});defer{e.clear();e.finish()}
        let expected=Array(original.filter{!banned.contains($0.text) && CandidateGlyphSupport.supports($0.text)}.prefix(66))
        XCTAssertEqual(expected.count,66,"Baseline must cover both requested pages after display holes")
        let actual=e.candidateBatch(offset:0,limit:2)+e.candidateBatch(offset:2,limit:64)
        XCTAssertEqual(actual.map(\.text),expected.map(\.text));XCTAssertEqual(actual.map(\.index),expected.map(\.index))
        XCTAssertEqual(e.chooseCandidate(hidden),"");XCTAssertEqual(e.rawInput,"din")
        let first=try XCTUnwrap(actual.first);XCTAssertEqual(e.chooseCandidate(first),first.text)
    }
    func testHistoricalRarePinDoesNotBypassMainlandAdmissionOrBlockCompletion()throws {
        // Seed an old stored pin directly in this suite's temporary profile.
        // The current public menu must never need to expose the forbidden row.
        let e=try engine(accept:{_ in true});defer{e.clear();e.finish()}
        e.clear();_ = e.privacy(false);for c in "din".utf8 {_ = e.key(Int32(c))}
        let old=InputCandidate(text:"𨈖",comment:"din",index:0,sourceInput:e.rawInput,generation:e.revision)
        try e.manage(old,pinned:true);defer{try? e.manage(old,pinned:false)}
        let rare=InputCandidate(text:"𨈖",comment:"din",index:0,sourceInput:e.rawInput,generation:e.revision)
        let rows=e.candidateBatch(offset:0,limit:64)
        XCTAssertFalse(rows.contains{$0.text=="𨈖"});XCTAssertTrue(rows.contains{$0.text=="定"})
        XCTAssertTrue(e.isPinned(rare),"Filtering does not rewrite the stored historical record")
        XCTAssertEqual(e.chooseCandidate(rare),"");XCTAssertEqual(e.rawInput,"din")
        let word=try XCTUnwrap(rows.first{$0.text=="定"})
        XCTAssertEqual(e.chooseCandidate(word),"定");XCTAssertEqual(e.chooseCandidate(word),"")
    }
    func testIncrementalSparseAdmissionYieldsResumesAndCommitsAbsoluteRow()throws {
        let source=try engine(accept:{_ in true});defer{source.clear();source.finish()}
        source.clear();for c in "shi".utf8 {_ = source.key(Int32(c))}
        let baseline=source.candidateBatch(offset:0,limit:128)
        XCTAssertGreaterThan(baseline.count,80,"Use a real large native menu")
        let banned=Set(baseline.prefix(80).map(\.text))
        let expected=baseline.filter{!banned.contains($0.text)}
        let e=try engine(accept:{!banned.contains($0)});defer{e.clear();e.finish()}
        e.clear();for c in "shi".utf8 {_ = e.key(Int32(c))}
        let first=e.candidateBatch(offset:0,limit:12,incremental:true)
        XCTAssertTrue(first.isEmpty,"One glyph slice must yield, not scan the whole menu")
        XCTAssertTrue(e.candidateBatchWasDeferred);XCTAssertTrue(e.candidateBatchCanContinue)
        var rows:[InputCandidate]=[]
        for _ in 0..<20 {
            rows=e.candidateBatch(offset:0,limit:12,incremental:true)
            if !e.candidateBatchWasDeferred {break}
        }
        XCTAssertFalse(e.candidateBatchWasDeferred)
        XCTAssertEqual(rows.map(\.text),Array(expected.prefix(12)).map(\.text))
        XCTAssertEqual(rows.map(\.index),Array(expected.prefix(12)).map(\.index))
        let before=rows.map(\.index)
        _ = e.candidateBatch(offset:12,limit:8,incremental:true)
        XCTAssertEqual(e.candidateBatch(offset:0,limit:12,incremental:true).map(\.index),before)
        let chosen=try XCTUnwrap(rows.first)
        XCTAssertEqual(e.chooseCandidate(chosen),chosen.text)
        XCTAssertEqual(e.chooseCandidate(chosen),"")
    }
    func testIncrementalReadingMatchesLegacyForFullPinyinAndNineKeys()throws {
        for (code,nine) in [("nihao",false),("5468",true)] {
            let source=try engine(accept:{_ in true});defer{source.clear();source.finish()}
            source.clear();_ = source.nineKey(nine);for c in code.utf8 {_ = source.key(Int32(c))}
            let expected=source.candidateBatch(offset:0,limit:24)
            let e=try engine(accept:{_ in true});defer{e.clear();e.finish()}
            e.clear();_ = e.nineKey(nine);for c in code.utf8 {_ = e.key(Int32(c))}
            var actual:[InputCandidate]=[]
            for _ in 0..<40 {
                actual += e.candidateBatch(offset:actual.count,limit:min(8,max(1,24-actual.count)),incremental:true)
                if actual.count>=24 || !e.candidateBatchCanContinue {break}
            }
            XCTAssertEqual(actual.map(\.text),expected.map(\.text),code)
            XCTAssertEqual(actual.map(\.index),expected.map(\.index),code)
            XCTAssertEqual(e.rawInput,code,"Budgeted lookup never commits or edits input")
        }
    }
    func testNativeBudgetYieldDoesNotCacheAnEmptyPinnedHead()throws {
        let source=try engine(accept:{_ in true});defer{source.clear();source.finish()}
        source.clear();for c in "shi".utf8 {_ = source.key(Int32(c))}
        let target=try XCTUnwrap(source.candidateBatch(offset:0,limit:12).last)
        let e=try engine(accept:{_ in true});defer{e.clear();e.finish()}
        e.clear();_ = e.privacy(false);for c in "shi".utf8 {_ = e.key(Int32(c))}
        XCTAssertEqual(pi_set_word_pinned("shi",target.text,1),1)
        defer {_ = pi_set_word_pinned("shi",target.text,0)}
        let first=e.candidateBatch(offset:0,limit:12,incremental:true,maximumScannedRows:1)
        XCTAssertTrue(first.isEmpty);XCTAssertTrue(e.candidateBatchWasDeferred)
        var rows:[InputCandidate]=[]
        for _ in 0..<200 {
            rows=e.candidateBatch(offset:0,limit:12,incremental:true,maximumScannedRows:1)
            if !e.candidateBatchWasDeferred {break}
        }
        XCTAssertFalse(e.candidateBatchWasDeferred)
        XCTAssertEqual(rows.first?.text,target.text)
        let chosen=try XCTUnwrap(rows.first)
        XCTAssertEqual(e.chooseCandidate(chosen),chosen.text)
    }
}
