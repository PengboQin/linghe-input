import XCTest
import AppKit
import PrivateInputKit
final class MacCandidateNavigationTests:XCTestCase {
 private static let storage=FileManager.default.temporaryDirectory.appendingPathComponent("PrivateInput-MacNavigation-"+UUID().uuidString)
 private struct Client:MacInputClient {let view:NSTextView;func insert(_ text:String){view.insertText(text,replacementRange:NSRange(location:NSNotFound,length:0))};func mark(_ text:String){view.setMarkedText(text,selectedRange:NSRange(location:text.utf16.count,length:0),replacementRange:NSRange(location:NSNotFound,length:0))}}
 // Use the same process-global isolated Rime path as the established suite.
 // A standalone semantic test needs no Rime and cannot touch user learning.
 func testMacBERTFiniteScoresPreferCorrectChineseAndBoundMemory() throws {
  let directory=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"semantic-mac",withExtension:nil))
  let model=MacSemanticRanker(directory:directory);XCTAssertTrue(model.configured)
  let done=expectation(description:"MacBERT local scoring")
  let before=Double(pi_process_memory_footprint())/1048576
  model.evaluate([.init(id:"good",text:"今天心情很好"),.init(id:"bad",text:"今天新情很好"),.init(id:"meal",text:"我们一起吃饭"),.init(id:"wrong",text:"我们一起吃反")],before:"") {scores,metrics in
   XCTAssertTrue(metrics.available);XCTAssertEqual(metrics.batches,1);XCTAssertEqual(scores.count,4)
   XCTAssertGreaterThan(scores["good"] ?? -100,scores["bad"] ?? 100)
   XCTAssertGreaterThan(scores["meal"] ?? -100,scores["wrong"] ?? 100)
   print("MACBERT_METRICS baselineMB=\(before) footprintMB=\(metrics.footprintMB) deltaMB=\(metrics.footprintMB-before) elapsedMS=\(metrics.elapsedMS)")
   done.fulfill()
  }
  wait(for:[done],timeout:60)
 }
 func testMacBERTConsumesBothHostSidesWithinFixedTokenWindow() throws {
  let model=MacSemanticRanker(directory:try XCTUnwrap(Bundle(for:Self.self).url(forResource:"semantic-mac",withExtension:nil)))
  let done=expectation(description:"bounded surrounding-context inference")
  model.evaluate([.init(id:"good",text:"心情"),.init(id:"bad",text:"新情"),.init(id:"long",text:String(repeating:"合成文字",count:8))],before:String(repeating:"前",count:20)+"今天我的",after:"很好。"+String(repeating:"后",count:20)) {scores,metrics in
   XCTAssertTrue(metrics.available);XCTAssertEqual(scores.count,3)
   XCTAssertGreaterThan(scores["good"] ?? -100,scores["bad"] ?? 100)
   XCTAssertTrue(scores.values.allSatisfy(\.isFinite));done.fulfill()
  }
  wait(for:[done],timeout:60)
 }
 func testModelCannotPromoteChangedSpellingIntoAnUntouchedSpellingSlot() {
  let exact=InputCandidate(text:"正常",comment:"zheng chang",index:0)
  let homophone=InputCandidate(text:"同音",comment:"zheng chang",index:1)
  let repair=InputCandidate(text:"改拼",comment:"gai pin",index:-50000,pinyinRepair:"gaipin")
  let result=MacInputSession.mergingSemanticRanking(base:[exact,homophone,repair],ranked:[repair,homophone,exact])
  XCTAssertEqual(result.map(\.text),["同音","正常","改拼"])
 }
 func testMacBERTCancelledRequestNeverPublishes() throws {
  let model=MacSemanticRanker(directory:try XCTUnwrap(Bundle(for:Self.self).url(forResource:"semantic-mac",withExtension:nil)))
  let stale=expectation(description:"cancelled scoring");stale.isInverted=true
  model.evaluate([.init(id:"stale",text:"今天心情很好")],before:"") {_,_ in stale.fulfill()};model.cancel()
  wait(for:[stale],timeout:0.3)
 }
 @MainActor func testFrequencyRightClickMapsActualCellWithoutSelectingOrMovingPanel() throws {
  let panel=MacCandidatePanel(),screen=try XCTUnwrap(NSScreen.main)
  defer{panel.hide()}
  let rows=(0..<20).map{InputCandidate(text:"合成词\($0)",comment:"he cheng ci",index:$0)}
  let table=try XCTUnwrap(Mirror(reflecting:panel).children.first{$0.label=="table"}?.value as? NSTableView)
  let caret=NSRect(x:screen.visibleFrame.midX,y:screen.visibleFrame.midY,width:1,height:22)
  var managed:Int?,chosen=0
  panel.choose={_ in chosen+=1}
  panel.managementMenu={row in managed=row.index;let menu=NSMenu();menu.addItem(withTitle:"置顶",action:nil,keyEquivalent:"");return menu}
  func menu(row:Int,column:Int)throws->NSMenu? {
   let point=table.convert(NSPoint(x:table.rect(ofColumn:column).midX,y:table.rect(ofRow:row).midY),to:nil)
   let event=try XCTUnwrap(NSEvent.mouseEvent(with:.rightMouseDown,location:point,modifierFlags:[],timestamp:0,windowNumber:panel.panelIdentifier,context:nil,eventNumber:1,clickCount:1,pressure:1))
   return table.menu(for:event)
  }
  panel.show(items:rows,selected:6,offset:6,expanded:false,caret:caret)
  var frame=panel.frame
  XCTAssertNotNil(try menu(row:0,column:2));XCTAssertEqual(managed,8);XCTAssertEqual(chosen,0);XCTAssertEqual(panel.frame,frame)
  panel.show(items:rows,selected:6,offset:6,expanded:true,caret:caret)
  frame=panel.frame
  XCTAssertNotNil(try menu(row:2,column:3));XCTAssertEqual(managed,15);XCTAssertEqual(chosen,0);XCTAssertEqual(panel.frame,frame)
  managed=nil;XCTAssertNil(try menu(row:3,column:5));XCTAssertNil(managed);XCTAssertFalse(panel.takesKeyFocus)
 }
 @MainActor func testRowAndExpandedGridReuseWindowAndOriginAcrossLayouts() throws {
  let screen=try XCTUnwrap(NSScreen.main),panel=MacCandidatePanel()
  let samples=["是","时","事","十","使","市","什么","时候","世界","实际","事情","时间","是的","试试","实际上","什么意思","这是一条用于验证长句候选显示的示例","明天见","今天","认识","是否","生活","输入","开始","收到","稍等","现在","可以","你好","需要","谢谢","这里","完成","知道","我们","看看"]
  let rows=(0..<90).map{InputCandidate(text:samples[$0%samples.count],comment:"",index:$0)}
  for layout in [DesktopCandidateLayout(),.init(collapsedCount:9,expandedColumns:5,expandedRows:4),.init(collapsedCount:3,expandedColumns:9,expandedRows:9)] {
   panel.hide()
   let caret=NSRect(x:screen.visibleFrame.minX+60,y:screen.visibleFrame.maxY-80,width:100,height:35)
   panel.show(items:rows,selected:0,offset:0,expanded:false,caret:caret,layout:layout)
   let identifier=panel.panelIdentifier,closed=panel.frame
   if layout == DesktopCandidateLayout() {
    panel.appearanceForAcceptance(.aqua)
    try panel.saveAcceptanceSnapshot(FileManager.default.temporaryDirectory.appendingPathComponent("PrivateInput-Row35-Synthetic.png"))
    panel.appearanceForAcceptance(.darkAqua)
    try panel.saveAcceptanceSnapshot(FileManager.default.temporaryDirectory.appendingPathComponent("PrivateInput-Row35-Dark-Synthetic.png"))
    panel.appearanceForAcceptance(.aqua)
   }
   XCTAssertEqual(panel.columnCount,layout.collapsedCount)
   panel.show(items:rows,selected:0,offset:0,expanded:true,caret:caret,layout:layout)
   XCTAssertEqual(panel.panelIdentifier,identifier);XCTAssertEqual(panel.columnCount,layout.expandedColumns)
   if !panel.columnsFitViewportForAcceptance {
    let values=Dictionary(uniqueKeysWithValues:Mirror(reflecting:panel).children.compactMap{child in child.label.map{($0,child.value)}})
    let table=values["table"] as! NSTableView,scroll=values["scroll"] as! NSScrollView
    print("COLUMN_METRICS columns=\(panel.columnCount) widths=\(table.tableColumns.map(\.width)) last=\(table.rect(ofColumn:panel.columnCount-1)) clip=\(scroll.contentView.bounds) scroll=\(scroll.frame) table=\(table.frame) window=\(panel.frame)")
   }
   XCTAssertTrue(panel.columnsFitViewportForAcceptance,"The final column must fit inside the real scroller clip area")
   let widths=panel.columnWidthsForAcceptance
   XCTAssertEqual(try XCTUnwrap(widths.first),try XCTUnwrap(widths.last),accuracy:0.1,"The last column must not be squeezed by the scroller")
   if layout == DesktopCandidateLayout() {try panel.saveAcceptanceSnapshot(FileManager.default.temporaryDirectory.appendingPathComponent("PrivateInput-Grid35-Synthetic.png"))}
   XCTAssertEqual(panel.frame.minX,closed.minX,accuracy:0.1);XCTAssertEqual(panel.frame.maxY,closed.maxY,accuracy:0.1)
   XCTAssertGreaterThan(panel.frame.height,closed.height)
   XCTAssertTrue(screen.visibleFrame.contains(panel.frame));XCTAssertFalse(panel.takesKeyFocus)
   panel.show(items:rows,selected:0,offset:0,expanded:false,caret:caret,layout:layout)
   XCTAssertEqual(panel.frame,closed);XCTAssertEqual(panel.panelIdentifier,identifier)
  }
  panel.hide()
 }
 @MainActor func testGlassAndOpaqueFallbackKeepSamePanelAndGeometry() throws {
  let screen=try XCTUnwrap(NSScreen.main),panel=MacCandidatePanel()
  let rows=(0..<36).map{InputCandidate(text:"候选\($0)",comment:"",index:$0)}
  let caret=NSRect(x:screen.visibleFrame.midX,y:screen.visibleFrame.midY,width:1,height:22)
  panel.show(items:rows,selected:0,offset:0,expanded:false,caret:caret)
  let frame=panel.frame,id=panel.panelIdentifier
  panel.accessibilityForAcceptance(reduceTransparency:false,increaseContrast:false)
  if #available(macOS 26.0, *) {XCTAssertTrue(panel.usesGlassForAcceptance)}
  for flags in [(true,false),(false,true),(true,true)] {
   panel.accessibilityForAcceptance(reduceTransparency:flags.0,increaseContrast:flags.1)
   XCTAssertFalse(panel.usesGlassForAcceptance);XCTAssertEqual(panel.frame,frame);XCTAssertEqual(panel.panelIdentifier,id)
   XCTAssertTrue(panel.columnsFitViewportForAcceptance);XCTAssertFalse(panel.takesKeyFocus)
  }
  panel.accessibilityForAcceptance(reduceTransparency:false,increaseContrast:false)
  if #available(macOS 26.0, *) {XCTAssertTrue(panel.usesGlassForAcceptance)}
  panel.hide()
 }
 @MainActor func testChangingColumnsKeepsSameHighlightedCandidateVisible() throws {
  let panel=MacCandidatePanel(),screen=try XCTUnwrap(NSScreen.main),rows=(0..<90).map{InputCandidate(text:"设置词\($0)",comment:"",index:$0)}
  let caret=NSRect(x:screen.visibleFrame.minX+50,y:screen.visibleFrame.maxY-90,width:10,height:20)
  panel.show(items:rows,selected:40,offset:36,expanded:true,caret:caret,layout:.init(expandedColumns:9,expandedRows:3))
  let id=panel.panelIdentifier
  panel.show(items:rows,selected:40,offset:39,expanded:true,caret:caret,layout:.init(expandedColumns:3,expandedRows:3))
  XCTAssertEqual(panel.panelIdentifier,id);XCTAssertTrue(panel.selectionIsVisible);panel.hide()
 }
 @MainActor func testShortcutNumbersFollowSelectedRowWithoutChangingColumns() throws {
  let panel=MacCandidatePanel(),screen=try XCTUnwrap(NSScreen.main)
  defer {panel.hide()}
  let rows=(0..<27).map{InputCandidate(text:"编号词\($0)",comment:"",index:$0)}
  let caret=NSRect(x:screen.visibleFrame.midX,y:screen.visibleFrame.midY,width:1,height:22)
  let table=try XCTUnwrap(Mirror(reflecting:panel).children.first{$0.label == "table"}?.value as? NSTableView)
  func shortcuts(row:Int) throws -> [String] {
   try table.tableColumns.compactMap {column in
    let cell=try XCTUnwrap(panel.tableView(table,viewFor:column,row:row))
    let number=cell.subviews.compactMap{$0 as? NSTextField}.first{$0.identifier?.rawValue == "candidate-shortcut"}
    return number.flatMap{$0.isHidden ? nil:$0.stringValue}
   }
  }
  for columns in [3,6,9] {
   let layout=DesktopCandidateLayout(collapsedCount:5,expandedColumns:columns,expandedRows:4)
   panel.show(items:rows,selected:0,offset:0,expanded:true,caret:caret,layout:layout)
   XCTAssertEqual(try shortcuts(row:0),(1...columns).map(String.init));XCTAssertEqual(try shortcuts(row:1),[])
   let widths=panel.columnWidthsForAcceptance,frame=panel.frame
   panel.show(items:rows,selected:columns+1,offset:columns,expanded:true,caret:caret,layout:layout)
   XCTAssertEqual(try shortcuts(row:0),[]);XCTAssertEqual(try shortcuts(row:1),(1...columns).map(String.init))
   XCTAssertEqual(try shortcuts(row:2),[])
   XCTAssertEqual(panel.columnWidthsForAcceptance,widths);XCTAssertEqual(panel.frame,frame)
   panel.show(items:rows,selected:columns+1,offset:columns,expanded:false,caret:caret,layout:layout)
   XCTAssertEqual(try shortcuts(row:0),(1...5).map(String.init))
  }
  // The last, incomplete row has no numbered empty cells.
  panel.show(items:Array(rows.prefix(8)),selected:7,offset:6,expanded:true,caret:caret)
  XCTAssertEqual(try shortcuts(row:0),[]);XCTAssertEqual(try shortcuts(row:1),["1","2"])
 }
 @MainActor func testLowerScreenEdgeKeepsSameBottomWhenGrowingUpward() throws {
  let panel=MacCandidatePanel(),screen=try XCTUnwrap(NSScreen.main),rows=(0..<72).map{InputCandidate(text:"边界词\($0)",comment:"",index:$0)}
  let caret=NSRect(x:screen.visibleFrame.midX,y:screen.visibleFrame.minY+8,width:10,height:25)
  panel.show(items:rows,selected:0,offset:0,expanded:false,caret:caret)
  let old=panel.frame,id=panel.panelIdentifier
  panel.show(items:rows,selected:6,offset:6,expanded:true,caret:caret)
  XCTAssertEqual(panel.frame.minY,old.minY,accuracy:0.1);XCTAssertEqual(panel.frame.minX,old.minX,accuracy:0.1)
  XCTAssertEqual(panel.panelIdentifier,id);XCTAssertTrue(screen.visibleFrame.contains(panel.frame));panel.hide()
 }
 func testCaretPlacementUsesGlobalCoordinatesAndRejectsOriginPlaceholder() {
  let screens=[NSRect(x:-1400,y:0,width:1400,height:900),NSRect(x:0,y:0,width:1440,height:900)]
  let caret=NSRect(x:-1000,y:600,width:1,height:20),size=NSSize(width:336,height:54)
  let first=MacCandidatePlacement.frame(caret:caret,size:size,referenceHeight:264,screens:screens)
  XCTAssertEqual(first?.minX,-1000);XCTAssertLessThan(first?.maxY ?? 999,caret.minY)
  let second=MacCandidatePlacement.frame(caret:NSRect(x:-800,y:650,width:1,height:20),size:size,referenceHeight:264,screens:screens)
  XCTAssertEqual(second!.minX-first!.minX,200,accuracy:0.1);XCTAssertEqual(second!.minY-first!.minY,50,accuracy:0.1)
  XCTAssertNil(MacCandidatePlacement.frame(caret:NSRect(x:0,y:0,width:1,height:20),size:size,referenceHeight:264,screens:screens))
  XCTAssertNil(MacCandidatePlacement.frame(caret:.zero,size:size,referenceHeight:264,screens:screens))
 }
 @MainActor func testPanelRejectsMissingCaretAndTracksHostMovement() throws {
  let panel=MacCandidatePanel(),screen=try XCTUnwrap(NSScreen.main)
  let rows=(0..<60).map{InputCandidate(text:"词\($0)",comment:"",index:$0)}
  let caret=NSRect(x:screen.visibleFrame.midX-150,y:screen.visibleFrame.midY,width:1,height:22)
  panel.show(items:rows,selected:0,offset:0,expanded:false,caret:caret)
  XCTAssertTrue(panel.isVisible);let first=panel.frame,id=panel.panelIdentifier
  XCTAssertLessThan(panel.frame.width,450);XCTAssertLessThan(panel.frame.height,46)
  panel.reposition(caret:NSRect(x:caret.minX+90,y:caret.minY+50,width:1,height:22))
  XCTAssertEqual(panel.panelIdentifier,id);XCTAssertEqual(panel.frame.minX-first.minX,90,accuracy:0.1)
  XCTAssertEqual(panel.frame.minY-first.minY,50,accuracy:0.1)
  panel.show(items:rows,selected:0,offset:0,expanded:true,caret:caret)
  XCTAssertTrue(screen.visibleFrame.contains(panel.frame));XCTAssertFalse(panel.takesKeyFocus)
  panel.show(items:rows,selected:0,offset:0,expanded:false,caret:.zero)
  XCTAssertFalse(panel.isVisible,"An unavailable caret must use the controller's system fallback, never a fabricated position")
  panel.hide()
 }
}
