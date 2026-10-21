import Foundation
import XCTest
import PrivateInputKit

@MainActor final class MacSharedTextAccessTests: XCTestCase {
    private func clip(id:UUID,text:String) throws -> ReceivedClipboard {
        let object:[String:Any]=["id":id.uuidString,"sender":UUID().uuidString,"text":text,"expiresAt":200]
        return try JSONDecoder().decode(ReceivedClipboard.self,from:JSONSerialization.data(withJSONObject:object))
    }
    func testSelectionAlwaysReadsCurrentSnapshotAndRejectsExpiredOrRemovedContent() throws {
        let model=DeviceSyncModel(session:nil),id=UUID()
        model.info.configured=true;model.info.clipboard=true
        model.info.clips=[try clip(id:id,text:"合成旧内容")]
        XCTAssertEqual(model.sharedText(id:id,now:199),"合成旧内容")
        XCTAssertNil(model.sharedText(id:id,now:200))
        model.info.clips=[]
        XCTAssertNil(model.sharedText(id:id,now:100))
    }
    func testPauseDisconnectAndPendingConsentHideAlreadySelectedText() throws {
        let model=DeviceSyncModel(session:nil),id=UUID()
        model.info.configured=true;model.info.clipboard=true
        model.info.clips=[try clip(id:id,text:"合成隐私边界")]
        model.savingConsent=true;XCTAssertNil(model.sharedText(id:id,now:100))
        model.savingConsent=false;model.info.clipboard=false;XCTAssertNil(model.sharedText(id:id,now:100))
        model.info.clipboard=true;model.info.configured=false;XCTAssertNil(model.sharedText(id:id,now:100))
    }
}
