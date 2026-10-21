import XCTest
@testable import PrivateInputKit

final class NativeInputSupportTests: XCTestCase {
    func testRecentCommitRejectsDifferentFieldCursorSelectionExpiryAndMissingContext() {
        var token=RecentCommit()
        token.stage(document:"one",before:"prefix-hash",after:"suffix-hash",text:"你好",input:"64426",context:"",nineKey:true,time:10)
        func check(_ document:String?="one",_ before:String?="prefix-hash",_ after:String?="suffix-hash",_ suffix:String?="你好",_ selection:Bool=false,_ time:Double=11) -> RecentCommit.Draft? {
            token.available(document:document,before:before,after:after,suffix:suffix,hasSelection:selection,time:time)
        }
        XCTAssertEqual(check()?.input,"64426")
        XCTAssertNil(check("two"));XCTAssertNil(check(nil));XCTAssertNil(check("one","other"))
        XCTAssertNil(check("one","prefix-hash",nil));XCTAssertNil(check("one","prefix-hash","suffix-hash","你"))
        XCTAssertNil(check("one","prefix-hash","suffix-hash","你好",true))
        XCTAssertNil(check("one","prefix-hash","suffix-hash","你好",false,131))
        token.invalidate();XCTAssertNil(check())
        token.stage(document:"one",before:nil,after:"",text:"你好",input:"64426",context:"",nineKey:true,time:10)
        XCTAssertNil(token.text)
        token.stage(document:"one",before:"prefix-hash",after:nil,text:"你好",input:"64426",context:"",nineKey:true,time:10)
        XCTAssertNotNil(check("one","prefix-hash",nil))
        XCTAssertNil(check())
    }
    func testSupplementaryNamesShortcutsExactCodesAndExplicitFilters() {
        let words=SupplementaryLexicon(pairs:[("吕明","吕明"),("dz","synthetic reply"),("you","系统短语"),("bad!","no"),("dz","synthetic reply")])
        XCTAssertEqual(words.entries.count,3)
        XCTAssertEqual(words.matches(input:"lvming",nineKey:false).first?.text,"吕明")
        XCTAssertEqual(words.matches(input:"586464",nineKey:true).first?.text,"吕明")
        XCTAssertEqual(words.matches(input:"lv'6464",nineKey:true).first?.text,"吕明")
        XCTAssertTrue(words.matches(input:"lu'6464",nineKey:true).isEmpty)
        XCTAssertEqual(words.matches(input:"39",nineKey:true).first?.text,"synthetic reply")
        XCTAssertTrue(words.matches(input:"d",nineKey:false).isEmpty)
        XCTAssertTrue(words.matches(input:"390",nineKey:true).isEmpty)
    }
}
