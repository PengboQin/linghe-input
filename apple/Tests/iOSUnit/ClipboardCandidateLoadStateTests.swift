import Foundation
import XCTest

final class ClipboardCandidateLoadStateTests:XCTestCase {
    private func request(_ version:Int=1,_ document:UUID=UUID())->ClipboardCandidateState.Request {
        .init(version:version,document:document,presentation:1,deletion:0,scope:"group|enabled")
    }
    func testRepeatedTicksKeepOneLoadAndItsPressIdentity() {
        var state=ClipboardCandidateLoadState();let r=request()
        XCTAssertTrue(state.observe(version:1,scope:r.scope,generation:"a"))
        let first=state.begin(request:r,eligible:true)!
        for _ in 0..<20 {
            XCTAssertFalse(state.observe(version:1,scope:r.scope,generation:"a"))
            XCTAssertNil(state.begin(request:r,eligible:true))
        }
        XCTAssertEqual(first.request,r);XCTAssertTrue(state.finish(first));XCTAssertEqual(state.attempts,1)
    }
    func testCacheGenerationDoesNotInvalidateKnownCopyButRejectsOldLoad() {
        var state=ClipboardCandidateLoadState();let r=request()
        _=state.observe(version:1,scope:r.scope,generation:"a");let old=state.begin(request:r,eligible:true)!
        XCTAssertFalse(state.observe(version:1,scope:r.scope,generation:"b"))
        let fresh=state.begin(request:r,eligible:true)!
        XCTAssertFalse(state.finish(old));XCTAssertNil(state.begin(request:r,eligible:true))
        XCTAssertTrue(state.finish(fresh))
    }
    func testActualCopyAndScopeChangesInvalidateSnapshots() {
        var state=ClipboardCandidateLoadState();let r=request()
        _=state.observe(version:1,scope:r.scope,generation:"a")
        XCTAssertTrue(state.observe(version:2,scope:r.scope,generation:"a"))
        XCTAssertTrue(state.observe(version:2,scope:"other-group",generation:"a"))
        XCTAssertNil(state.begin(request:r,eligible:true))
    }
    func testFailuresAreBoundedAndFreshCacheCanRetry() {
        var state=ClipboardCandidateLoadState(maximumAttempts:2);let r=request()
        _=state.observe(version:1,scope:r.scope,generation:"a")
        for _ in 0..<2 {let t=state.begin(request:r,eligible:true)!;XCTAssertTrue(state.finish(t))}
        XCTAssertNil(state.begin(request:r,eligible:true))
        _=state.observe(version:1,scope:r.scope,generation:"b")
        XCTAssertNotNil(state.begin(request:r,eligible:true))
    }
    func testClearAndLeavingInvalidateCallbacksWithoutChangingClipboardPermission() {
        var state=ClipboardCandidateLoadState();let r=request()
        _=state.observe(version:1,scope:r.scope,generation:"a");let t=state.begin(request:r,eligible:true)!
        state.cancel();XCTAssertFalse(state.finish(t));XCTAssertNil(state.begin(request:r,eligible:false))
        state.leavePresentation();XCTAssertEqual(state.attempts,0)
        _=state.observe(version:1,scope:r.scope,generation:"a")
        XCTAssertNotNil(state.begin(request:r,eligible:true))
    }
}
