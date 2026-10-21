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
    func testActualMissingGlyphIsAbsentAndKnownCompletionCommitsOnce()throws {
        let e=try engine();defer{e.clear();e.finish()}
        let rows=e.candidateBatch(offset:0,limit:64)
        XCTAssertFalse(rows.isEmpty);XCTAssertTrue(rows.allSatisfy{CandidateGlyphSupport.supports($0.text)})
        XCTAssertEqual(rows.contains{$0.text=="𨈖"},CandidateGlyphSupport.supports("𨈖"))
        let word=try XCTUnwrap(rows.first{$0.text=="定"});XCTAssertEqual(e.chooseCandidate(word),"定");XCTAssertEqual(e.chooseCandidate(word),"")
    }
    func testFilteredPagesFillNativeHolesAndCannotCommitHiddenRow()throws {
        let source=try engine(accept:{_ in true});defer{source.clear();source.finish()}
        let original=source.candidateBatch(offset:0,limit:64),hidden=try XCTUnwrap(original.first{$0.text=="𨈖"})
        let banned=Set(["定","顶","灯","𨈖"])
        let e=try engine(accept:{!banned.contains($0) && CandidateGlyphSupport.supports($0)});defer{e.clear();e.finish()}
        let expected=original.filter{!banned.contains($0.text) && CandidateGlyphSupport.supports($0.text)}
        let actual=e.candidateBatch(offset:0,limit:2)+e.candidateBatch(offset:2,limit:64)
        XCTAssertEqual(actual.map(\.text),expected.map(\.text));XCTAssertEqual(actual.map(\.index),expected.map(\.index))
        XCTAssertEqual(e.chooseCandidate(hidden),"");XCTAssertEqual(e.rawInput,"din")
        let first=try XCTUnwrap(actual.first);XCTAssertEqual(e.chooseCandidate(first),first.text)
    }
    func testHiddenPinnedWordDoesNotBlockRenderableCompletionOrErasePin()throws {
        let source=try engine(accept:{_ in true});defer{source.clear();source.finish()}
        source.clear();_ = source.privacy(false);for c in "din".utf8 {_ = source.key(Int32(c))}
        let rare=try XCTUnwrap(source.candidateBatch(offset:0,limit:64).first{$0.text=="𨈖"})
        try source.manage(rare,pinned:true);defer{try? source.manage(rare,pinned:false)}
        let e=try engine(accept:{$0 != "𨈖" && CandidateGlyphSupport.supports($0)});defer{e.clear();e.finish()}
        e.clear();_ = e.privacy(false);for c in "din".utf8 {_ = e.key(Int32(c))}
        let rows=e.candidateBatch(offset:0,limit:64)
        XCTAssertFalse(rows.contains{$0.text=="𨈖"});XCTAssertTrue(rows.contains{$0.text=="定"})
        XCTAssertTrue(e.isPinned(rare),"Filtering does not destroy a user's stored pin")
        XCTAssertEqual(e.chooseCandidate(rare),"")
    }
}
