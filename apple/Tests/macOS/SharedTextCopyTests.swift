import Foundation
import XCTest
import PrivateInputKit

@MainActor final class SharedTextCopyTests:XCTestCase {
    final class Board:AutomaticClipboardBoard {
        var version=10,text="unchanged",writes=0,reads=0,fail=false,denyRead=false
        func readText()->String?{reads+=1;return denyRead ? nil:text}
        func writeText(_ text:String)->Bool {guard !fail else{return false};self.text=text;version+=1;writes+=1;return true}
    }
    private func clip(_ text:String,expires:UInt64=200)throws->ReceivedClipboard {
        try JSONDecoder().decode(ReceivedClipboard.self,from:JSONSerialization.data(withJSONObject:["id":UUID().uuidString,"sender":UUID().uuidString,"text":text,"expiresAt":expires]))
    }
    func testManualCopyPreservesLayoutAndRecordsOriginalEventOnlyAfterWrite()throws {
        let board=Board(),value=try clip("\n  原文\r\n\t**raw** 👩🏽‍💻\n\n"),scope="test-scope";var origin:(String,Int,String,UUID,UUID)?,archive:(Int,UUID,UUID)?
        XCTAssertTrue(SharedTextCopy.copy(value,now:100,scope:scope,board:board,recordOrigin:{origin=($0,$1,$2,$3,$4)},recordArchive:{archive=($0,$1,$2)}))
        XCTAssertEqual(Data(board.text.utf8),Data(value.text.utf8));XCTAssertEqual(board.writes,1)
        XCTAssertEqual(origin?.0,scope);XCTAssertEqual(origin?.1,board.version);XCTAssertEqual(origin?.2,AutomaticClipboardBridge.digest(value.text));XCTAssertEqual(origin?.3,value.id);XCTAssertEqual(origin?.4,value.sender)
        XCTAssertEqual(archive?.0,board.version);XCTAssertEqual(archive?.1,value.id);XCTAssertEqual(archive?.2,value.sender)
    }
    func testFailedExpiredAndInvalidCopiesCannotRecordSuccess()throws {
        let board=Board(),value=try clip("safe");var records=0
        board.fail=true
        XCTAssertFalse(SharedTextCopy.copy(value,now:100,scope:"scope",board:board,recordOrigin:{_,_,_,_,_ in records+=1},recordArchive:{_,_,_ in records+=1}))
        board.fail=false
        for value in [try clip("expired",expires:100),try clip(""),try clip("bad\0text")] {
            XCTAssertFalse(SharedTextCopy.copy(value,now:100,scope:"scope",board:board,recordOrigin:{_,_,_,_,_ in records+=1},recordArchive:{_,_,_ in records+=1}))
        }
        XCTAssertEqual(records,0);XCTAssertEqual(board.writes,0);XCTAssertEqual(board.text,"unchanged")
    }
    func testCopyWithoutAutomaticConsentStillWorksWithoutOriginScope()throws {
        let board=Board(),value=try clip("  manual\n");var origins=0,archives=0
        XCTAssertTrue(SharedTextCopy.copy(value,now:100,scope:nil,board:board,recordOrigin:{_,_,_,_,_ in origins+=1},recordArchive:{_,_,_ in archives+=1}))
        XCTAssertEqual(origins,0);XCTAssertEqual(archives,1);XCTAssertEqual(Data(board.text.utf8),Data(value.text.utf8))
    }
    func testAutomaticScopeRequiresCurrentGroupConsentAndPersonalEpoch() {
        let name="SharedTextCopyTests-"+UUID().uuidString,prefs=UserDefaults(suiteName:name)!
        defer{prefs.removePersistentDomain(forName:name)}
        let group=UUID(),consent=UUID().uuidString,personal=UUID().uuidString,scope=group.uuidString+":3:"+personal+":"+consent
        prefs.set(true,forKey:"clipboard-sharing-enabled");prefs.set(true,forKey:"automatic-clipboard-enabled");prefs.set(group.uuidString,forKey:"clipboard-group-id");prefs.set(consent,forKey:"automatic-clipboard-consent-generation");prefs.set(scope,forKey:"automatic-clipboard-scope")
        XCTAssertEqual(SharedTextCopy.automaticScope(preferences:prefs,personalEpoch:personal),scope)
        XCTAssertNil(SharedTextCopy.automaticScope(preferences:prefs,personalEpoch:UUID().uuidString))
        prefs.set(UUID().uuidString,forKey:"clipboard-group-id");XCTAssertNil(SharedTextCopy.automaticScope(preferences:prefs,personalEpoch:personal))
        prefs.set(group.uuidString,forKey:"clipboard-group-id");prefs.set(UUID().uuidString,forKey:"automatic-clipboard-consent-generation");XCTAssertNil(SharedTextCopy.automaticScope(preferences:prefs,personalEpoch:personal))
        prefs.set(consent,forKey:"automatic-clipboard-consent-generation");prefs.set(group.uuidString+":invalid:"+personal+":"+consent,forKey:"automatic-clipboard-scope");XCTAssertNil(SharedTextCopy.automaticScope(preferences:prefs,personalEpoch:personal))
        prefs.set(scope,forKey:"automatic-clipboard-scope");prefs.set(false,forKey:"automatic-clipboard-enabled");XCTAssertNil(SharedTextCopy.automaticScope(preferences:prefs,personalEpoch:personal))
    }
}
