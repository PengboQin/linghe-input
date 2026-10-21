import AppKit
import XCTest

final class MacSymbolInsertionTests:XCTestCase {
    @MainActor func testPairMovesNativeCaretWithoutMarkedTextAndPreservesSurroundings() {
        for (text,back) in [("（）",1),("\"\"",1),("【】",1),("《》",1),("🙂）",1)] {
            let view=NSTextView();view.string="前🙂后";view.setSelectedRange(NSRange(location:3,length:0))
            insert(text,back:back,in:view)
            XCTAssertEqual(view.string,"前🙂"+text+"后")
            XCTAssertEqual(view.selectedRange(),NSRange(location:3+text.utf16.count-back,length:0))
            XCTAssertFalse(view.hasMarkedText())
            view.insertText("内",replacementRange:NSRange(location:NSNotFound,length:0))
            XCTAssertEqual(view.string,"前🙂"+String(text.dropLast())+"内"+String(text.suffix(1))+"后")
        }
    }
    @MainActor func testOutsideCaretAndSelectedTextUseNormalNativeInsertion() {
        let view=NSTextView();view.string="前选中后";view.setSelectedRange(NSRange(location:1,length:2))
        insert("()",back:0,in:view)
        XCTAssertEqual(view.string,"前()后");XCTAssertEqual(view.selectedRange().location,3)
        XCTAssertFalse(view.hasMarkedText())
    }
    func testMissingOrChangedHostEvidenceNeverMovesCaretOrDuplicatesText() {
        for selected in [NSRange(location:NSNotFound,length:0),NSRange(location:1,length:0),NSRange(location:4,length:2),NSRange(location:4,length:0)] {
            var inserted=[String](),moves=[NSRange]()
            MacSymbolInsertion.insert("()",caretBack:1,insert:{inserted.append($0)},selection:{selected},read:{_ in "别的"},placeCaret:{moves.append($0)})
            XCTAssertEqual(inserted,["()"]);XCTAssertTrue(moves.isEmpty)
        }
    }
    @MainActor private func insert(_ text:String,back:Int,in view:NSTextView) {
        MacSymbolInsertion.insert(text,caretBack:back,insert:{view.insertText($0,replacementRange:NSRange(location:NSNotFound,length:0))},selection:{view.selectedRange()},read:{range in
            guard range.location>=0,NSMaxRange(range)<=(view.string as NSString).length else{return nil}
            return (view.string as NSString).substring(with:range)
        },placeCaret:{view.setMarkedText("",selectedRange:NSRange(location:0,length:0),replacementRange:$0)})
    }
}
