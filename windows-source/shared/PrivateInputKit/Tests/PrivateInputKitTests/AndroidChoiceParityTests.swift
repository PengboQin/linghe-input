import XCTest
@testable import PrivateInputKit

final class AndroidChoiceParityTests:XCTestCase {
 func testExportChoiceAndOwnCommitTraces() throws {
  guard let path=ProcessInfo.processInfo.environment["ANDROID_CHOICE_VECTORS"] else {throw XCTSkip("Explicit Android choice trace export")}
  let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
  var rows=[String](),memory=NineKeyChoiceMemory(),tracker=OwnCommitCorrectionTracker()
  func emit(_ op:String,_ args:[String:Any],_ value:Any)throws {
   let a=try JSONSerialization.data(withJSONObject:args,options:[.sortedKeys]),b=try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.fragmentsAllowed]);rows.append([op,a.base64EncodedString(),b.base64EncodedString()].joined(separator:"\t"))
  }
  func model(_ op:String,_ args:[String:Any])throws {try emit(op,args,JSONSerialization.jsonObject(with:encoder.encode(memory)))}
  for _ in 0..<20 {try memory.record(code:"64426",reading:"ni hao",text:"拟好",context:"我说")}
  try model("repeat",["code":"64426","reading":"ni hao","text":"拟好","context":"我说","times":20])
  try memory.recordCorrection(code:"64426",reading:"ni hao",text:"你好",context:"我说");try model("correction",["code":"64426","reading":"ni hao","text":"你好","context":"我说"])
  for context in ["我说","今天我说","完全不同",""] {try emit("boost",["code":"64426","reading":"ni hao","text":"你好","context":context],memory.boost(code:"64426",reading:"ni hao",text:"你好",context:context))}
  for code in ["644426","64426"] {try memory.record(code:code,reading:"ni hao",text:"你好",context:"第一句。今天，下午！开会之后我说",strength:2);try model("record",["code":code,"reading":"ni hao","text":"你好","context":"第一句。今天，下午！开会之后我说","strength":2])}
  try memory.record(code:"744468",reading:"shi hou",text:"时候",context:"下午",strength:1);try model("record",["code":"744468","reading":"shi hou","text":"时候","context":"下午","strength":1])
  memory.reset(text:"你好",reading:"ni hao");try model("reset",["text":"你好","reading":"ni hao"])
  let legacy=Data(#"{"version":1,"entries":[{"code":"64425","reading":"nihao","text":"你好","context":"我说","count":5}]}"#.utf8)
  memory=try JSONDecoder().decode(NineKeyChoiceMemory.self,from:legacy).migrated();try model("load",["archive":legacy.base64EncodedString()])
  try memory.record(code:"64425",reading:"ni hao",text:"你好",context:"今天这个时候我说",strength:2);try model("record",["code":"64425","reading":"ni hao","text":"你好","context":"今天这个时候我说","strength":2])
  let doc="7",anchor="synthetic-anchor"
  func replacement(_ value:OwnCommitCorrectionTracker.Replacement?)->Any {guard let value else{return NSNull()};return ["code":value.code,"context":value.context,"rejected":value.rejectedText,"reading":value.reading as Any? ?? NSNull()]}
  tracker.stage(document:doc,anchor:anchor,text:"时候",code:"744468",context:"下午",time:10,reading:"shi hou");try emit("stage",["doc":7,"anchor":anchor,"text":"时候","code":"744468","context":"下午","time":10000,"reading":"shi hou"],tracker.expectedText(document:doc,time:10) as Any? ?? NSNull())
  try emit("delete",["doc":7,"anchor":anchor,"time":11000],replacement(tracker.deleted(document:doc,anchor:anchor,time:11)))
  try emit("partial",["doc":7,"anchor":anchor,"time":12000],replacement(tracker.partiallyDeleted(document:doc,anchor:anchor,time:12)))
  try emit("delete",["doc":7,"anchor":anchor,"time":13000],replacement(tracker.deleted(document:doc,anchor:anchor,time:13)))
  try emit("expected",["doc":7,"time":14000],tracker.expectedText(document:doc,time:14) as Any? ?? NSNull())
  tracker.stage(document:doc,anchor:anchor,text:"你好",code:"64426",context:"",time:20,reading:"ni hao");try emit("stage",["doc":7,"anchor":anchor,"text":"你好","code":"64426","context":"","time":20000,"reading":"ni hao"],tracker.expectedText(document:doc,time:20) as Any? ?? NSNull())
  try emit("delete",["doc":8,"anchor":anchor,"time":21000],replacement(tracker.deleted(document:"8",anchor:anchor,time:21)))
  tracker.stage(document:doc,anchor:anchor,text:"你好",code:"64426",context:"",time:30,reading:"ni hao");try emit("stage",["doc":7,"anchor":anchor,"text":"你好","code":"64426","context":"","time":30000,"reading":"ni hao"],tracker.expectedText(document:doc,time:30) as Any? ?? NSNull())
  try emit("expected",["doc":7,"time":151000],tracker.expectedText(document:doc,time:151) as Any? ?? NSNull())
  try rows.joined(separator:"\n").write(toFile:path,atomically:true,encoding:.utf8);XCTAssertGreaterThan(rows.count,18)
 }
 func testAndroidChoiceArchiveDecodesInSwift()throws {
  guard let path=ProcessInfo.processInfo.environment["ANDROID_CHOICE_RESULT"] else{throw XCTSkip("Explicit Android archive import")}
  let memory=try JSONDecoder().decode(NineKeyChoiceMemory.self,from:Data(contentsOf:URL(fileURLWithPath:path)));try memory.validate();XCTAssertEqual(memory.version,3);XCTAssertEqual(memory.entries.filter{$0.code=="64425" && $0.text=="你好"}.reduce(0){$0+$1.count},7)
 }
}
