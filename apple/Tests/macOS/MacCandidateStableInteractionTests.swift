import XCTest
import AppKit
import PrivateInputKit

/// Real AppKit table/window geometry and pointer dispatch, without a live
/// input source or access to the user's text client or learned vocabulary.
final class MacCandidateStableInteractionTests:XCTestCase {
    @MainActor func testOrdinarySentenceIsReadableInFixedTwoLineGrid()throws {
        let panel=MacCandidatePanel(),caret=try caret(),table=try table(panel)
        defer{panel.hide()}
        let rows=(0..<36).map{InputCandidate(text:$0==0 ? "我想玩去了":"合成词",comment:"",index:$0)}
        panel.show(items:rows,selected:0,offset:0,expanded:true,caret:caret)
        let frame=panel.frame,height=table.rowHeight,widths=panel.columnWidthsForAcceptance
        let cell=try XCTUnwrap(panel.tableView(table,viewFor:table.tableColumns.first,row:0) as? NSTableCellView)
        let label=try XCTUnwrap(cell.subviews.compactMap{$0 as? NSTextField}.first{$0.stringValue=="我想玩去了"})
        XCTAssertEqual(label.maximumNumberOfLines,2);XCTAssertEqual(label.lineBreakMode,.byWordWrapping)
        let bounds=(label.stringValue as NSString).boundingRect(with:NSSize(width:label.preferredMaxLayoutWidth,height:1000),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:try XCTUnwrap(label.font)])
        XCTAssertLessThanOrEqual(ceil(bounds.height),40,"The six-character feedback sentence must actually fit, not only appear in a tooltip")
        panel.show(items:rows,selected:7,offset:6,expanded:true,caret:caret)
        XCTAssertEqual(panel.frame,frame);XCTAssertEqual(table.rowHeight,height);XCTAssertEqual(panel.columnWidthsForAcceptance,widths)
        XCTAssertFalse(try XCTUnwrap(table.enclosingScrollView).hasVerticalScroller)
    }
    @MainActor private func table(_ panel:MacCandidatePanel)throws->NSTableView {
        try XCTUnwrap(Mirror(reflecting:panel).children.first{$0.label=="table"}?.value as? NSTableView)
    }
    @MainActor private func caret()throws->NSRect {
        let screen=try XCTUnwrap(NSScreen.main)
        return NSRect(x:screen.visibleFrame.minX+60,y:screen.visibleFrame.maxY-90,width:1,height:22)
    }
    @MainActor private func event(_ type:NSEvent.EventType,point:NSPoint,panel:MacCandidatePanel,flags:NSEvent.ModifierFlags=[] )throws->NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with:type,location:point,modifierFlags:flags,timestamp:1,
            windowNumber:panel.panelIdentifier,context:nil,eventNumber:1,clickCount:1,pressure:1))
    }
    @MainActor private func point(row:Int,column:Int,table:NSTableView)->NSPoint {
        table.convert(NSPoint(x:table.rect(ofColumn:column).midX,y:table.rect(ofRow:row).midY),to:nil)
    }
    @MainActor func testCollapsedWordsMeasureNaturallyWhileGridAndLazyTailStayStable()throws {
        let panel=MacCandidatePanel(),caret=try caret()
        defer {panel.hide()}
        let short=(0..<90).map{InputCandidate(text:"字\($0)",comment:"",index:$0)}
        let long=(0..<90).map{InputCandidate(text:String(repeating:"这是一整句很长的候选文字",count:8)+String($0),comment:"",index:$0)}
        let table=try table(panel),scroll=try XCTUnwrap(table.enclosingScrollView)
        for layout in [DesktopCandidateLayout(),.init(collapsedCount:3,expandedColumns:9,expandedRows:3),.init(collapsedCount:9,expandedColumns:3,expandedRows:9)] {
            panel.show(items:short,selected:0,offset:0,expanded:false,caret:caret,layout:layout)
            let shortFrame=panel.frame,shortWidths=panel.columnWidthsForAcceptance
            XCTAssertLessThan(try XCTUnwrap(shortWidths.first),80,"A short first word has no oversized fixed slot")
            XCTAssertEqual(try XCTUnwrap(shortWidths.first),try XCTUnwrap(shortWidths.last),accuracy:1)
            var phraseFirst=short
            phraseFirst[0]=long[0]
            panel.show(items:phraseFirst,selected:0,offset:0,expanded:false,caret:caret,layout:layout)
            XCTAssertGreaterThan(panel.frame.width,shortFrame.width,"A long phrase expands the collapsed row")
            XCTAssertGreaterThan(try XCTUnwrap(panel.columnWidthsForAcceptance.first),try XCTUnwrap(panel.columnWidthsForAcceptance.last))
            XCTAssertLessThanOrEqual(panel.frame.width,650)
            XCTAssertEqual(panel.frame.maxY,shortFrame.maxY,accuracy:0.1)
            panel.show(items:long,selected:0,offset:0,expanded:false,caret:caret,layout:layout)
            XCTAssertLessThanOrEqual(panel.frame.width,650);XCTAssertTrue(panel.columnsFitViewportForAcceptance)
            panel.show(items:Array(short.prefix(layout.collapsedCount)),selected:0,offset:0,expanded:false,caret:caret,layout:layout)
            XCTAssertEqual(panel.frame,shortFrame);XCTAssertEqual(panel.columnWidthsForAcceptance,shortWidths)
            panel.show(items:short,selected:0,offset:0,expanded:false,caret:caret,layout:layout)
            XCTAssertEqual(panel.frame,shortFrame,"Appending an unseen tail never widens the visible row")
            XCTAssertEqual(panel.columnWidthsForAcceptance,shortWidths)
            panel.show(items:Array(short.prefix(1)),selected:0,offset:0,expanded:true,caret:caret,layout:layout)
            let frame=panel.frame,widths=panel.columnWidthsForAcceptance,clipWidth=scroll.contentView.bounds.width
            for rows in [short,long,Array(long.reversed()),Array(short.prefix(2))] {
                panel.show(items:rows,selected:0,offset:0,expanded:true,caret:caret,layout:layout)
                XCTAssertEqual(panel.frame,frame,"The expanded grid does not resize for candidate text or lazy loading")
                XCTAssertEqual(panel.columnWidthsForAcceptance,widths)
                XCTAssertEqual(scroll.contentView.bounds.width,clipWidth)
                XCTAssertFalse(scroll.hasVerticalScroller);XCTAssertFalse(scroll.hasHorizontalScroller)
                XCTAssertTrue(panel.columnsFitViewportForAcceptance);XCTAssertFalse(panel.takesKeyFocus)
            }
        }
    }
    @MainActor func testFirstSingleLeftClickCommitsActualCellWithoutKeyFocus()throws {
        let panel=MacCandidatePanel(),caret=try caret(),table=try table(panel)
        defer {panel.hide()}
        let rows=(0..<90).map{InputCandidate(text:"合成候选\($0)",comment:"",index:$0)}
        var chosen:[Int]=[];panel.choose={chosen.append($0.index)}
        for expanded in [false,true] {
            panel.show(items:rows,selected:6,offset:6,expanded:expanded,caret:caret)
            let row=expanded ? 2:0,column=2,location=point(row:row,column:column,table:table)
            let down=try event(.leftMouseDown,point:location,panel:panel)
            XCTAssertTrue(table.acceptsFirstMouse(for:down));XCTAssertFalse(table.acceptsFirstResponder)
            let local=table.convert(location,from:nil)
            XCTAssertTrue(table.hitTest(table.convert(local,to:table.superview)) === table)
            table.mouseDown(with:down)
            XCTAssertEqual(chosen.count,expanded ? 1:0,"Only release commits")
            table.mouseUp(with:try event(.leftMouseUp,point:location,panel:panel))
            XCTAssertEqual(chosen.last,expanded ? 14:8)
            XCTAssertFalse(panel.takesKeyFocus)
        }
        XCTAssertEqual(chosen,[8,14])
    }
    @MainActor func testDragScrollRefreshAndContextMenuNeverCommitWrongCandidate()throws {
        let panel=MacCandidatePanel(),caret=try caret(),table=try table(panel)
        defer {panel.hide()}
        let rows=(0..<90).map{InputCandidate(text:"安全候选\($0)",comment:"",index:$0)}
        var chosen=0,managed=0;panel.choose={_ in chosen+=1}
        panel.managementMenu={_ in managed+=1;return NSMenu()}
        func show(_ items:[InputCandidate]) {panel.show(items:items,selected:0,offset:0,expanded:true,caret:caret)}
        func press(_ location:NSPoint)throws {table.mouseDown(with:try event(.leftMouseDown,point:location,panel:panel))}
        func release(_ location:NSPoint)throws {table.mouseUp(with:try event(.leftMouseUp,point:location,panel:panel))}
        show(rows)
        var location=point(row:0,column:1,table:table)
        try press(location)
        table.mouseDragged(with:try event(.leftMouseDragged,point:NSPoint(x:location.x+8,y:location.y),panel:panel))
        try release(location)
        XCTAssertEqual(chosen,0,"Returning after a drag must not commit")
        try press(location)
        panel.scrollForAcceptance(toRow:10)
        try release(location)
        XCTAssertEqual(chosen,0,"A scrolling gesture cancels an in-flight click")
        show(rows);location=point(row:0,column:1,table:table)
        try press(location)
        var changed=rows;changed[1]=InputCandidate(text:"另一候选",comment:"",index:rows[1].index)
        show(changed);try release(location)
        XCTAssertEqual(chosen,0,"A refreshed cell must not choose the replacement word")
        try press(location)
        XCTAssertNotNil(table.menu(for:try event(.rightMouseDown,point:location,panel:panel)))
        try release(location)
        XCTAssertEqual(chosen,0);XCTAssertEqual(managed,1)
        try press(location)
        try table.mouseUp(with:event(.leftMouseUp,point:location,panel:panel,flags:.control))
        XCTAssertEqual(chosen,0)
        try press(location);panel.hide();try release(location)
        XCTAssertEqual(chosen,0,"A hidden or ended composition cannot receive a delayed mouse-up")
    }
    @MainActor func testHiddenScrollerStillAllowsNativeDocumentScrolling()throws {
        let panel=MacCandidatePanel(),caret=try caret(),table=try table(panel)
        defer {panel.hide()}
        let rows=(0..<180).map{InputCandidate(text:"滚动候选\($0)",comment:"",index:$0)}
        panel.show(items:rows,selected:0,offset:0,expanded:true,caret:caret)
        let scroll=try XCTUnwrap(table.enclosingScrollView),frame=panel.frame,widths=panel.columnWidthsForAcceptance
        let before=scroll.documentVisibleRect.origin
        panel.scrollForAcceptance(toRow:20)
        XCTAssertNotEqual(scroll.documentVisibleRect.origin,before)
        XCTAssertTrue(panel.selectionIsVisible);XCTAssertEqual(panel.frame,frame)
        XCTAssertEqual(panel.columnWidthsForAcceptance,widths);XCTAssertFalse(scroll.hasVerticalScroller)
    }
}
