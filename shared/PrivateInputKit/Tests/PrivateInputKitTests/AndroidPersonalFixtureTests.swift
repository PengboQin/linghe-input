import XCTest
@testable import PrivateInputKit

final class AndroidPersonalFixtureTests:XCTestCase {
    func testBothClientsUseTheSameExplicitEntryAndTombstoneFixture() throws {
        let root=(0..<5).reduce(URL(fileURLWithPath:#filePath)) { value,_ in value.deletingLastPathComponent() }
        let path=ProcessInfo.processInfo.environment["ANDROID_PERSONAL_FIXTURE"].map{URL(fileURLWithPath:$0)} ?? root.appendingPathComponent("shared/contracts/personal-lexicon-fixture-v1.json")
        let value=try PersonalLexiconStore.decode(Data(contentsOf:path))
        XCTAssertEqual(value.entries.map(\.text),["拟好","米好","合成地址\n请先联系"])
        XCTAssertEqual(value.matches(input:"64426",nineKey:true).count,2)
        XCTAssertEqual(value.matches(input:"ni'426",nineKey:true).map(\.text),["拟好"])
        XCTAssertTrue(value.matches(input:"d'z'",nineKey:true).isEmpty)
        XCTAssertEqual(value.synchronization?.records.count,4)
        XCTAssertEqual(value.synchronization?.records.values.filter{$0.deleted}.count,1)
        XCTAssertEqual(try value.synchronization?.materialized().entries,value.entries)
    }
    func testMixedEnglishAndCommonSymbolRulesMatchAndroidHostCases() {
        XCTAssertEqual(MixedEnglishLexicon.suggestions(input:"api",nineKey:false),["API"])
        XCTAssertEqual(MixedEnglishLexicon.suggestions(input:"git",nineKey:false),["GitHub","GitLab"])
        XCTAssertEqual(MixedEnglishLexicon.suggestions(input:"hel",nineKey:false),["hello","help"])
        XCTAssertTrue(MixedEnglishLexicon.suggestions(input:"he",nineKey:false).isEmpty)
        XCTAssertEqual(MixedEnglishLexicon.suggestions(input:"274",nineKey:true),["API"])
        XCTAssertEqual(MixedEnglishLexicon.suggestions(input:"43556",nineKey:true),["hello"])
        XCTAssertTrue(MixedEnglishLexicon.suggestions(input:"968",nineKey:true).isEmpty)
        XCTAssertTrue(MixedEnglishLexicon.suggestions(input:"ni'426",nineKey:true).isEmpty)
        var symbols=SymbolUsage();let allowed=Set(["，","。","⊂","Ω"])
        for _ in 0..<5 {symbols.record("⊂",allowed:allowed)}
        for _ in 0..<2 {symbols.record("。",allowed:allowed)}
        XCTAssertEqual(symbols.ordered(seed:["，","。"],catalog:["，","。","⊂","Ω"]),["⊂","。","，"])
    }
}
