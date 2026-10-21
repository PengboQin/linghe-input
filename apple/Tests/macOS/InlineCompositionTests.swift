import Foundation
import XCTest

private final class MarkedHost:InlineCompositionHost {
    var compositionDocument:UUID?=UUID()
    var prefix="原文🙂",suffix="末尾",selection:String?=nil,marked:String?=nil
    var ignoresMarks=false
    var contextUnavailable=false
    var excludesMarkedContext=false
    var lastRange=NSRange()
    var writes=0
    var compositionBefore:String? { contextUnavailable ? nil:prefix+(excludesMarkedContext ? "":(marked ?? "")) }
    var compositionAfter:String? { contextUnavailable ? nil:suffix }
    var compositionSelection:String? { selection }
    func markComposition(_ text:String,selection:NSRange) {
        writes+=1;lastRange=selection
        if !ignoresMarks { marked=text;self.selection=nil }
    }
    func unmarkComposition() { prefix+=marked ?? "";marked=nil }
}
final class InlineCompositionTests:XCTestCase {
    func testMarkedTextDoesNotRequireReadableHostContext() {
        let host=MarkedHost(),state=InlineComposition();host.contextUnavailable=true
        XCTAssertTrue(state.update("ni",host:host));XCTAssertTrue(state.update("ni hao",host:host))
        let document=host.compositionDocument;host.compositionDocument=nil
        XCTAssertFalse(state.moved(in:host));XCTAssertFalse(state.update("ni hao",host:host));XCTAssertTrue(state.active)
        XCTAssertFalse(state.finish(nil,host:host));XCTAssertTrue(state.active)
        host.compositionDocument=document
        XCTAssertTrue(state.finish("你好",host:host));XCTAssertEqual(host.prefix,"原文🙂你好")
        XCTAssertTrue(state.update("quan",host:host));XCTAssertTrue(state.finish(nil,host:host));XCTAssertEqual(host.prefix,"原文🙂你好")
    }
    func testReplaceCancelAndUTF16PreserveSurroundingText() {
        let host=MarkedHost(),state=InlineComposition()
        XCTAssertTrue(state.update("ni hao",host:host));XCTAssertEqual(host.prefix,"原文🙂")
        XCTAssertTrue(state.update("你好🙂",host:host));XCTAssertEqual(host.lastRange.location,4)
        XCTAssertTrue(state.finish("你好",host:host));XCTAssertEqual(host.prefix,"原文🙂你好");XCTAssertEqual(host.suffix,"末尾")
        host.selection="选中文字";XCTAssertTrue(state.update("quan",host:host));XCTAssertTrue(state.finish(nil,host:host))
        XCTAssertEqual(host.prefix,"原文🙂你好选中文字");XCTAssertFalse(state.active)
    }
    func testFieldAndCaretChangesNeverDeleteOtherText() {
        let host=MarkedHost(),state=InlineComposition();XCTAssertTrue(state.update("ni",host:host))
        host.compositionDocument=UUID();host.prefix="另一个框";host.marked=nil
        XCTAssertTrue(state.moved(in:host));let writes=host.writes
        XCTAssertFalse(state.finish(nil,host:host));XCTAssertEqual(host.writes,writes);XCTAssertEqual(host.prefix,"另一个框")
        host.prefix="";host.suffix="";XCTAssertTrue(state.update("ni",host:host))
        host.prefix="外部编辑";host.marked=nil;host.suffix="后文"
        XCTAssertTrue(state.moved(in:host));XCTAssertFalse(state.finish("你好",host:host));XCTAssertEqual(host.prefix,"外部编辑")
    }
    func testCommittedOnlyAndInitiallyUnavailableContextsKeepNativeRange() {
        let host=MarkedHost(),state=InlineComposition();host.contextUnavailable=true
        XCTAssertTrue(state.update("ni",host:host));let writes=host.writes
        XCTAssertTrue(state.update("ni",host:host));XCTAssertEqual(host.writes,writes)
        host.contextUnavailable=false;host.excludesMarkedContext=true
        XCTAssertFalse(state.moved(in:host));XCTAssertTrue(state.update("ni hao",host:host))
        XCTAssertTrue(state.finish(nil,host:host));XCTAssertEqual(host.prefix,"原文🙂")
        XCTAssertTrue(state.update("ni",host:host));XCTAssertTrue(state.finish("你好",host:host));XCTAssertEqual(host.prefix,"原文🙂你好")
    }
}
