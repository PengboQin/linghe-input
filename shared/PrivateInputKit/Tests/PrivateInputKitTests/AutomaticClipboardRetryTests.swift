import XCTest
import PrivateInputKit

final class AutomaticClipboardRetryTests:XCTestCase {
    func testExplicitReadRetryPreservesArmedAndPendingState() {
        var state=AutomaticClipboardState();state.configure(scope:"scope",version:1)
        _=state.finish(state.begin(version:1)!,currentVersion:1,remote:[],received:0,ownDevice:UUID(),now:100)
        XCTAssertTrue(state.armed);XCTAssertTrue(state.claimLocalRead(version:2));XCTAssertFalse(state.claimLocalRead(version:2))
        XCTAssertTrue(state.stageLocal(digest:"queued"));state.requestReadRetry()
        XCTAssertTrue(state.armed);XCTAssertEqual(state.scope,"scope");XCTAssertEqual(state.pendingDigest,"queued")
        XCTAssertTrue(state.claimLocalRead(version:2));XCTAssertFalse(state.claimLocalRead(version:2));XCTAssertEqual(state.pendingDigest,"queued")
    }
    func testExplicitReadRetryPreservesRemoteEchoVersion() {
        var state=AutomaticClipboardState();state.configure(scope:"scope",version:1)
        state.wroteRemote(version:2,digest:"remote");state.requestReadRetry()
        XCTAssertFalse(state.claimLocalRead(version:2),"A retry is not permission to re-upload our own remote write")
        XCTAssertTrue(state.claimLocalRead(version:3))
    }
}
