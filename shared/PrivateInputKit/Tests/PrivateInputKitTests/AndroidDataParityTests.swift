import XCTest
@testable import PrivateInputKit

final class AndroidDataParityTests:XCTestCase {
 func testUInt64PersonalRevisionVectors() throws {
  guard let output=ProcessInfo.processInfo.environment["ANDROID_DATA_VECTORS"] else {throw XCTSkip("Explicit data protocol export")}
  let id="AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",device="BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
  let entry="{\"id\":\"\(id)\",\"kind\":\"phrase\",\"text\":\"跨端合成条目\",\"trigger\":\"cs\"}"
  let values=["0","1","1.0","1e3","1.0000000000000001","9007199254740991","9007199254740993","9223372036854775807","9223372036854775808","9223372036854775809","18446744073709551614","18446744073709551615","18446744073709551615.0","18446744073709551616","-1","1.5","1e1000000","1e-1000000","\"1\"","true","null"]
  var vectors=[String]()
  for (index,number) in values.enumerated() {
   let encoded="{\"version\":1,\"entries\":[\(entry)],\"synchronization\":{\"version\":1,\"records\":{\"\(id)\":{\"entry\":\(entry),\"deleted\":false,\"revision\":{\"sequence\":\(number),\"device\":\"\(device)\"},\"created\":{\"sequence\":1,\"device\":\"\(device)\"}}}}}"
   let decoded=try? PersonalLexiconStore.decode(Data(encoded.utf8))
   let canonical=decoded?.synchronization?.records[id].map{String($0.revision.sequence)} ?? "invalid"
   // Android intentionally preserves exact decimal semantics for these
   // noncanonical spellings; Apple always emits ordinary integer tokens.
   let exact=index==4 ? "invalid":index==12 ? "18446744073709551615":canonical
   vectors.append("\(index)\t\(canonical)\t\(exact)\t\(Data(encoded.utf8).base64EncodedString())")
  }
  try (vectors.joined(separator:"\n")+"\n").write(toFile:output,atomically:true,encoding:.utf8)
  XCTAssertTrue(vectors[9].contains("\t9223372036854775809\t"))
  XCTAssertTrue(vectors[11].contains("\t18446744073709551615\t"))
 }
 func testActualAndroidUInt64UpdatesDecodeWithoutPrecisionLoss() throws {
  guard let folder=ProcessInfo.processInfo.environment["ANDROID_DATA_ROUNDTRIP_DIR"] else {throw XCTSkip("Run the Android VM data checks first")}
  let root=URL(fileURLWithPath:folder),id="AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
  let high=try PersonalLexiconStore.decode(Data(contentsOf:root.appendingPathComponent("high-edited.json")))
  XCTAssertEqual(high.entries.first?.text,"精确跨端修订")
  XCTAssertEqual(high.synchronization?.records[id]?.revision.sequence,9223372036854775810)
  let maximum=try PersonalLexiconStore.decode(Data(contentsOf:root.appendingPathComponent("max-edited.json")))
  XCTAssertEqual(maximum.synchronization?.records[id]?.revision.sequence,UInt64.max)
  let exported=try PersonalLexiconStore.decode(Data(contentsOf:root.appendingPathComponent("visible-export.json")))
  XCTAssertNil(exported.synchronization);XCTAssertEqual(exported.entries.map(\.text),["本地保留","新增合成"])
 }
}
