import XCTest
@testable import PrivateInputKit
final class PinyinInputMatchTests:XCTestCase {
 func testAlphabeticPriorityPreservesSpellingBeforeCorrections() {
  XCTAssertEqual(PinyinInputMatch.candidatePriority("nihao",reading:"ni hao"),3)
  XCTAssertEqual(PinyinInputMatch.candidatePriority("lue",reading:"lve"),3)
  XCTAssertEqual(PinyinInputMatch.candidatePriority("csm",reading:"chi shen me"),2)
  XCTAssertEqual(PinyinInputMatch.candidatePriority("shih",reading:"shi hou"),2)
  XCTAssertEqual(PinyinInputMatch.candidatePriority("shih",reading:"shi",corrected:true),1)
  XCTAssertEqual(PinyinInputMatch.candidatePriority("linaxaing",reading:"lian xiang",corrected:true),1)
  XCTAssertEqual(PinyinInputMatch.candidatePriority("linaxaing",reading:"li na xi ai neng gou"),0)
  XCTAssertEqual(PinyinInputMatch.candidatePriority("968",reading:"you"),0)
 }
 func testInitialsMixedAndUnfinishedPinyinStayDistinctFromTypos() {
  for raw in ["csm","chsm","chishenm","chishenme"] {XCTAssertTrue(PinyinInputMatch.covers(raw,reading:"chi shen me"),raw)}
  XCTAssertTrue(PinyinInputMatch.covers("shih",reading:"shi hou"))
  XCTAssertTrue(PinyinInputMatch.covers("shihou",reading:"shi hou"))
  XCTAssertFalse(PinyinInputMatch.covers("linaxaing",reading:"lian xiang"))
  XCTAssertFalse(PinyinInputMatch.covers("csma",reading:"chi shen me"))
 }
 func testBoundedSurroundingTextExcludesSelectionAndMarkedComposition() throws {
  let value=SurroundingText(before:String(repeating:"前",count:40),after:String(repeating:"后",count:40))
  XCTAssertEqual(value.before.count,20);XCTAssertEqual(value.after.count,20)
  let ranges=try XCTUnwrap(SurroundingText.ranges(selection:NSRange(location:100,length:0),marked:NSRange(location:90,length:10),length:150))
  XCTAssertEqual(ranges.before,NSRange(location:10,length:80));XCTAssertEqual(ranges.after,NSRange(location:100,length:50))
  XCTAssertNil(SurroundingText.ranges(selection:NSRange(location:NSNotFound,length:0),marked:NSRange(location:NSNotFound,length:0),length:10))
  XCTAssertNil(SurroundingText.ranges(selection:NSRange(location:Int.max-2,length:10),marked:NSRange(location:0,length:0),length:100))
 }
 func testTwoTranspositionsReserveARealWordWithinTheFiniteBudget() throws {
  let words:Set<String>=["li","na","lin","lian","xiang","xing","xia","ai","ang","an","neng","gou"]
  let decoder=PinyinCorrection(syllables:words,frequency:{$0=="lianxiang" ? 100000:1})
  let rows=decoder.proposals("linaxaing",limit:48)
  XCTAssertLessThanOrEqual(rows.count,48);XCTAssertTrue(rows.contains{$0.spelling=="lianxiang" && $0.edits==2})
 }
}
