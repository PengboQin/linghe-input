import XCTest
@testable import PrivateInputKit

final class NineKeyLexiconTests:XCTestCase {
    func testPrefixCompletionUsesSortedLengthRangesAndNeverEditsOriginalKeys() throws {
        let rows:[(String,UInt32)]=[("5468",1925),("5468426",110731),("546868",2472),("54684",25),("546842634",11135),("5469426",999999),("6664",12602)]
        func encoded(_ code:String)->UInt64 {
            var value:UInt64=0;for digit in code.utf8 {value=(value<<3)|UInt64(digit-50)}
            return UInt64(code.count)<<54|value
        }
        var bytes=Data("PI9LEX01".utf8)
        func append<T:FixedWidthInteger>(_ value:T) {var little=value.littleEndian;withUnsafeBytes(of:&little){bytes.append(contentsOf:$0)}}
        append(UInt32(rows.count));append(UInt32(12))
        for (code,frequency) in rows.sorted(by:{encoded($0.0)<encoded($1.0)}) {append(encoded(code));append(frequency)}
        let file=FileManager.default.temporaryDirectory.appendingPathComponent("NinePrefix-"+UUID().uuidString)
        try bytes.write(to:file);defer{try? FileManager.default.removeItem(at:file)}
        let lexicon=try NineKeyLexicon(url:file)
        XCTAssertEqual(lexicon.completions("5468").map(\.input),["5468426","546868","54684"])
        XCTAssertEqual(lexicon.completions("54684").map(\.input),["5468426","546842634"])
        XCTAssertEqual(lexicon.completions("5468",limit:1).map(\.input),["5468426"])
        XCTAssertEqual(lexicon.completions("666").map(\.input),["6664"])
        XCTAssertEqual(lexicon.frequency("5468"),1925)
        XCTAssertTrue(lexicon.completions("5468",limit:0).isEmpty)
        XCTAssertTrue(lexicon.completions("5468",maxAdditionalKeys:0).isEmpty)
        XCTAssertTrue(lexicon.completions("54").isEmpty)
        XCTAssertTrue(lexicon.completions("54a8").isEmpty)
    }
}
