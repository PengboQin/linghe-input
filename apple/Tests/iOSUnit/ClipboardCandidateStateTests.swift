import Foundation
import XCTest

final class ClipboardCandidateStateTests:XCTestCase {
    private let document=UUID(uuidString:"00000000-0000-0000-0000-000000000021")!
    private func request(version:Int=2,presentation:UInt64=1,deletion:UInt64=0,scope:String="consented")->ClipboardCandidateState.Request {
        .init(version:version,document:document,presentation:presentation,deletion:deletion,scope:scope)
    }
    func testPrimaryTypingAlwaysWinsOverClipboard() {
        var state=ClipboardCandidateState();state.observe(version:2)
        XCTAssertTrue(state.available(version:2,allowed:true,hasPrimary:false,deleting:false))
        XCTAssertFalse(state.available(version:2,allowed:true,hasPrimary:true,deleting:false))
    }
    func testDeleteDismissalSurvivesNewInputAndRepeatedReveal() {
        var state=ClipboardCandidateState();state.observe(version:2);state.dismiss()
        for _ in 0..<20 {
            state.observe(version:2)
            XCTAssertFalse(state.available(version:2,allowed:true,hasPrimary:false,deleting:false))
        }
    }
    func testNewCopyIsEligibleButCannotBreakDeletionLatch() {
        var state=ClipboardCandidateState();state.observe(version:2);state.dismiss();state.observe(version:3)
        XCTAssertFalse(state.available(version:3,allowed:true,hasPrimary:false,deleting:true))
        XCTAssertTrue(state.available(version:3,allowed:true,hasPrimary:false,deleting:false))
    }
    func testDelayedCallbackIsRejectedAfterDeleteOrFreshInput() {
        var state=ClipboardCandidateState();state.observe(version:2);let token=request()
        XCTAssertTrue(state.accepts(token,current:token,allowed:true,hasPrimary:false,deleting:false))
        state.dismiss()
        XCTAssertFalse(state.accepts(token,current:token,allowed:true,hasPrimary:false,deleting:false))
        XCTAssertFalse(state.accepts(token,current:request(deletion:2),allowed:true,hasPrimary:false,deleting:false))
    }
    func testPermissionRevocationAndMissingDocumentRejectResults() {
        var state=ClipboardCandidateState();state.observe(version:2);let token=request()
        XCTAssertFalse(state.accepts(token,current:token,allowed:false,hasPrimary:false,deleting:false))
        XCTAssertFalse(state.accepts(token,current:nil,allowed:true,hasPrimary:false,deleting:false))
    }
    func testScopePresentationAndCopyFencesRejectOldResults() {
        var state=ClipboardCandidateState();state.observe(version:2);let token=request()
        for stale in [request(version:3),request(presentation:2),request(scope:"revoked")] {
            XCTAssertFalse(state.accepts(token,current:stale,allowed:true,hasPrimary:false,deleting:false))
        }
        let other=ClipboardCandidateState.Request(version:2,document:UUID(),presentation:1,deletion:0,scope:"consented")
        XCTAssertFalse(state.accepts(token,current:other,allowed:true,hasPrimary:false,deleting:false))
    }
    func testPreviewDoesNotMutateOriginalFormatting() {
        let original="  first\n\n    second\tthird\n"
        XCTAssertEqual(ClipboardCandidateState.preview(original),"first second third")
        XCTAssertEqual(original,"  first\n\n    second\tthird\n")
        XCTAssertTrue(ClipboardCandidateState.validText(original))
        XCTAssertEqual(ClipboardCandidateState.preview(String(repeating:"甲",count:200)).count,120)
    }
    func testBoundedTextRejectsEmptyNULAndOversizedUTF8() {
        XCTAssertFalse(ClipboardCandidateState.validText(""))
        XCTAssertFalse(ClipboardCandidateState.validText(" \n\t\n  "))
        XCTAssertFalse(ClipboardCandidateState.validText("a\0b"))
        XCTAssertTrue(ClipboardCandidateState.validText(String(repeating:"x",count:65536)))
        XCTAssertFalse(ClipboardCandidateState.validText(String(repeating:"甲",count:21846)))
    }
    func testHeldPressKeepsTextAndActionTogetherEvenForIdenticalPreviews() {
        let first=ClipboardCandidatePresentation.Snapshot(request:request(),text:String(repeating:"a",count:130)+"A")
        let next=ClipboardCandidatePresentation.Snapshot(request:request(version:3),text:String(repeating:"a",count:130)+"B")
        XCTAssertEqual(first.preview,next.preview)
        var view=ClipboardCandidatePresentation();view.publish(first,tracking:false)
        XCTAssertFalse(view.publish(next,tracking:true));XCTAssertEqual(view.snapshot,first)
        var state=ClipboardCandidateState();state.observe(version:3)
        XCTAssertFalse(state.accepts(view.snapshot!.request,current:next.request,allowed:true,hasPrimary:false,deleting:false))
    }
    func testNewCopyPublishesOnlyAfterTrackingFinishes() {
        let first=ClipboardCandidatePresentation.Snapshot(request:request(),text:"first")
        let next=ClipboardCandidatePresentation.Snapshot(request:request(version:3),text:"second")
        var view=ClipboardCandidatePresentation();view.publish(first,tracking:false);view.publish(next,tracking:true)
        XCTAssertEqual(view.snapshot?.request,first.request)
        XCTAssertTrue(view.publish(next,tracking:false));XCTAssertEqual(view.snapshot,next)
    }
    func testDeleteRejectsTheAlreadyDisplayedActionAndLateCacheCannotReviveIt() {
        let first=ClipboardCandidatePresentation.Snapshot(request:request(),text:"first")
        var view=ClipboardCandidatePresentation();view.publish(first,tracking:false)
        var state=ClipboardCandidateState();state.observe(version:2);state.dismiss()
        XCTAssertFalse(state.accepts(view.snapshot!.request,current:request(deletion:1),allowed:true,hasPrimary:false,deleting:true))
        view.publish(first,tracking:true)
        XCTAssertFalse(state.accepts(view.snapshot!.request,current:request(deletion:2),allowed:true,hasPrimary:false,deleting:false))
    }
    func testUnknownNativePasteRetainsDisplayedRequestWhileTracking() {
        var view=ClipboardCandidatePresentation();view.publish(nil,request:request(),tracking:false)
        XCTAssertNil(view.snapshot);XCTAssertEqual(view.request,request())
        XCTAssertFalse(view.publish(nil,request:request(version:3),tracking:true))
        XCTAssertEqual(view.request,request())
        var state=ClipboardCandidateState();state.observe(version:3)
        XCTAssertFalse(state.accepts(view.request!,current:request(version:3),allowed:true,hasPrimary:false,deleting:false))
    }
}
