import XCTest
@testable import PrivateInputKit

/// Export only public, synthetic algorithm vectors for the Android VM runner.
final class AndroidLanguageParityTests:XCTestCase {
 func testPublicLanguageAlgorithmVectors() throws {
  guard let output=ProcessInfo.processInfo.environment["ANDROID_LANGUAGE_VECTORS"] else {throw XCTSkip("Explicit parity export only")}
  let root=(0..<5).reduce(URL(fileURLWithPath:#filePath)) { value,_ in value.deletingLastPathComponent() }
  let semantic=root.appendingPathComponent("resources/semantic")
  let syllables=Set(try String(contentsOf:semantic.appendingPathComponent("pinyin-syllables.txt")).split(whereSeparator:{$0.isWhitespace}).map(String.init))
  let nine=try NineKeyLexicon(url:semantic.appendingPathComponent("nine-lexicon.bin"))
  let continuations=try ContinuationLexicon(url:semantic.appendingPathComponent("continuation.bin"))
  let corrector=PinyinCorrection(syllables:syllables,frequency:{NineKeySpelling.encode($0).map(nine.frequency) ?? 0})
  func b(_ value:String)->String {Data(value.utf8).base64EncodedString()}
  var rows=[String]()
  for raw in ["shshenme","linaxaing","nihaoo","haoo","shih","jintian","woxiangchifan","woainiy","zhongguor","tianqihenha","xianzaikeyim","", "a", "ABC", "ni'hao",String(repeating:"a",count:97)] {
   for limit in [1,32,48,64] {
    let proposals=corrector.proposals(raw,limit:limit)
    rows.append(["P",b(raw),String(limit),proposals.map{"\($0.spelling):\($0.edits):\($0.cost)"}.joined(separator:",")].joined(separator:"\t"))
   }
  }
  for (raw,reading) in [("csm","chi shen me"),("shih","shi hou"),("ni'hao","ni hao"),("shshenme","shi shen me"),("zhg","zhong guo"),("shh","shi hou"),("nihao","ni hao"),("", "ni"),("ni", " "),("you", "you"),("wo", "wo bu")] {
   for budget in [0,1,2,32] {rows.append(["M",b(raw),b(reading),String(budget),String(PinyinInputMatch.covers(raw,reading:reading,maxAbbreviations:budget))].joined(separator:"\t"))}
  }
  for raw in ["968","64426","744743663","542694264","2","999999999999999999","","123",String(repeating:"2",count:19)] {rows.append(["F",b(raw),String(nine.frequency(raw))].joined(separator:"\t"))}
  for context in ["你好","因为天气很好，","如果可以，","虽然不容易，","我想。","今天?","你好\n","", "hello，","你好😀，","如果"+String(repeating:"今天",count:40)+"你好，","ni你好，"] {
   for limit in [1,8,24,30] {rows.append(["C",b(context),String(limit),continuations.suggestions(context:context,limit:limit).map{b($0.text)+":"+String($0.score)}.joined(separator:",")].joined(separator:"\t"))}
  }
  for raw in ["64","968","64426","888","234567892345","","1","nihao"] {
   for limit in [1,32,128] {rows.append(["N",b(raw),String(limit),NineKeySpelling.alternatives(raw,limit:limit).map{$0.input+":"+String($0.cost)}.joined(separator:",")].joined(separator:"\t"))}
  }
  let codes=["2","9","23","32","228","288","64426","64426","644226","6442266","744743663","74473663","","1","22","99"]
  for a in codes {for bcode in codes {rows.append(["E",b(a),b(bcode),NineKeySpelling.editCost(a,bcode).map(String.init(describing:)) ?? "nil",NineKeySpelling.jointEditCost(a,bcode).map(String.init(describing:)) ?? "nil"].joined(separator:"\t"))}}
  try (rows.joined(separator:"\n")+"\n").write(toFile:output,atomically:true,encoding:.utf8)
  XCTAssertEqual(syllables.count,424);XCTAssertGreaterThan(rows.count,400)
 }
}
