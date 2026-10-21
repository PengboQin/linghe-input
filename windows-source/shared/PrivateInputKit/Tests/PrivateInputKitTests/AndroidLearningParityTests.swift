import XCTest
@testable import PrivateInputKit

final class AndroidLearningParityTests:XCTestCase {
 func testExportLearningAndCheckpointTraces() throws {
  guard let output=ProcessInfo.processInfo.environment["ANDROID_LEARNING_VECTORS"] else {throw XCTSkip("Explicit learning trace export")}
  let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
  var rows=[String](),model=LearningModel(),checkpoint=RimeLearningCheckpoint()
  func add(_ type:String,_ op:String,_ args:[String:Any],_ expected:Data)throws {
   let input=try JSONSerialization.data(withJSONObject:args,options:[.sortedKeys])
   rows.append([type,op,input.base64EncodedString(),expected.base64EncodedString()].joined(separator:"\t"))
  }
  try model.setDeviceCount(reading:"ni hao",text:"你好",device:"A",count:3)
  try add("M","count",["reading":"ni hao","text":"你好","device":"A","count":3],model.export())
  var peer=LearningModel();try peer.setDeviceCount(reading:"ni hao",text:"你好",device:"B",count:7)
  let peerData=try peer.export();try model.merge(peerData)
  try add("M","merge",["archive":peerData.base64EncodedString()],model.export())
  try model.merge(peerData);try add("M","merge",["archive":peerData.base64EncodedString()],model.export())
  try model.setPinned(reading:"ni hao",text:"你好",pinned:true,device:"A")
  try add("M","pin",["reading":"ni hao","text":"你好","device":"A","pinned":true],model.export())
  try model.resetFrequency(reading:"ni hao",text:"你好");try add("M","reset",["reading":"ni hao","text":"你好"],model.export())
  try model.merge(peerData);try add("M","merge",["archive":peerData.base64EncodedString()],model.export())
  try model.record(reading:"ni hao",text:"你好",device:"A");try add("M","record",["reading":"ni hao","text":"你好","device":"A"],model.export())
  let newerPin=LearningEntry(reading:"ni hao",text:"你好",counts:["B":7],pinned:false,pinVersion:.init(sequence:4,device:"B"))
  let pinData=try encoder.encode(LearningArchive(entries:[newerPin]));try model.merge(pinData)
  try add("M","merge",["archive":pinData.base64EncodedString()],model.export())
  model.remove(id:"ni hao\u{1f}你好");try add("M","remove",["id":"ni hao\u{1f}你好"],model.export())
  try model.merge(peerData);try add("M","merge",["archive":peerData.base64EncodedString()],model.export())
  try model.restore(id:"ni hao\u{1f}你好");try add("M","restore",["id":"ni hao\u{1f}你好"],model.export())
  model.learningEnabled=false;try model.record(reading:"shi hou",text:"时候",device:"A")
  try add("M","disabledRecord",["reading":"shi hou","text":"时候","device":"A"],model.export())
  model.learningEnabled=true;try model.record(reading:"shi hou",text:"时候",device:"A")
  try add("M","enabledRecord",["reading":"shi hou","text":"时候","device":"A"],model.export())
  let root=(0..<5).reduce(URL(fileURLWithPath:#filePath)) { value,_ in value.deletingLastPathComponent() }
  let personal=try PersonalLexiconStore.decode(Data(contentsOf:root.appendingPathComponent("shared/contracts/personal-lexicon-fixture-v1.json"))).synchronization!
  try model.mergePersonalLexicon(personal);try add("M","personal",["archive":encoder.encode(personal).base64EncodedString()],model.export())
  let high=LearningEntry(reading:"bian jie",text:"边界",generation:UInt64.max-1,counts:["A":1],pinned:true,pinVersion:.init(sequence:UInt64.max-1,device:"A"))
  let highData=try encoder.encode(LearningArchive(entries:[high]));try model.merge(highData)
  try add("M","merge",["archive":highData.base64EncodedString()],model.export())
  try model.resetFrequency(reading:"bian jie",text:"边界");try add("M","reset",["reading":"bian jie","text":"边界"],model.export())
  try model.setPinned(reading:"bian jie",text:"边界",pinned:false,device:"B");try add("M","pin",["reading":"bian jie","text":"边界","device":"B","pinned":false],model.export())
  let local="你好\tni hao \t3\n"
  try checkpoint.observeExport(Data(local.utf8),device:"A");try add("C","observe",["text":local,"device":"A"],encoder.encode(checkpoint))
  try checkpoint.mergeRemoteArchive(peerData);try add("C","merge",["archive":peerData.base64EncodedString()],encoder.encode(checkpoint))
  let imported="你好\tni hao\t10\n"
  try checkpoint.establishBaselineAfterImport(Data(imported.utf8));try add("C","baseline",["text":imported],encoder.encode(checkpoint))
  try checkpoint.observeExport(Data(imported.utf8),device:"A");try add("C","observe",["text":imported,"device":"A"],encoder.encode(checkpoint))
  let typed="你好\tni hao\t12\n"
  try checkpoint.observeExport(Data(typed.utf8),device:"A");try add("C","observe",["text":typed,"device":"A"],encoder.encode(checkpoint))
  try checkpoint.setPinned(reading:"ni hao",text:"你好",pinned:true,device:"A");try add("C","pin",["reading":"ni hao","text":"你好","device":"A","pinned":true],encoder.encode(checkpoint))
  try checkpoint.resetFrequency(reading:"ni hao",text:"你好");try add("C","reset",["reading":"ni hao","text":"你好"],encoder.encode(checkpoint))
  try checkpoint.observeExport(Data(typed.utf8),device:"A");try add("C","observe",["text":typed,"device":"A"],encoder.encode(checkpoint))
  let reset="你好\tni hao\t1\n"
  try checkpoint.establishBaselineAfterImport(Data(reset.utf8));try add("C","baseline",["text":reset],encoder.encode(checkpoint))
  let next="你好\tni hao\t2\n"
  try checkpoint.observeExport(Data(next.utf8),device:"A");try add("C","observe",["text":next,"device":"A"],encoder.encode(checkpoint))
  try (rows.joined(separator:"\n")+"\n").write(toFile:output,atomically:true,encoding:.utf8)
  XCTAssertEqual(rows.count,27)
 }
 func testAndroidLearningArchiveAndCheckpointRoundtrip() throws {
  guard let folder=ProcessInfo.processInfo.environment["ANDROID_LEARNING_ROUNDTRIP_DIR"] else {throw XCTSkip("Run Android learning trace first")}
  let root=URL(fileURLWithPath:folder);var model=LearningModel();try model.merge(Data(contentsOf:root.appendingPathComponent("learning-final.json")))
  XCTAssertEqual(model.entries["bian jie\u{1f}边界"]?.generation,UInt64.max)
  XCTAssertEqual(model.entries["bian jie\u{1f}边界"]?.pinVersion.sequence,UInt64.max)
  XCTAssertEqual(try model.personalLexicon?.materialized().entries.count,3)
  let checkpoint=try JSONDecoder().decode(RimeLearningCheckpoint.self,from:Data(contentsOf:root.appendingPathComponent("checkpoint-final.json")))
  XCTAssertEqual(checkpoint.model.entries["ni hao\u{1f}你好"]?.frequency,1)
  XCTAssertEqual(checkpoint.model.entries["ni hao\u{1f}你好"]?.generation,1)
  XCTAssertTrue(checkpoint.pendingResets.isEmpty)
 }
}
