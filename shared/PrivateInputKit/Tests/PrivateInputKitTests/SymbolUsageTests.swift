import XCTest
@testable import PrivateInputKit

final class SymbolUsageTests: XCTestCase {
    func testFrequencyPromotesUsedCatalogSymbolsAndKeepsStableTies() throws {
        var usage=SymbolUsage();let catalog=["，","。","!","★","."]
        XCTAssertEqual(usage.ordered(seed:["，","。"],catalog:catalog),["，","。"])
        usage.record("★",allowed:Set(catalog));usage.record(".",allowed:Set(catalog))
        XCTAssertEqual(usage.ordered(seed:["，","。"],catalog:catalog),["★",".","，","。"])
        usage.record(".",allowed:Set(catalog))
        XCTAssertEqual(usage.ordered(seed:["，","。"],catalog:catalog),[".","★","，","。"])
        let saved=try JSONEncoder().encode(usage),loaded=try JSONDecoder().decode(SymbolUsage.self,from:saved)
        try loaded.validate();XCTAssertEqual(loaded.counts,usage.counts)
    }
    func testRejectsHostTextAndInvalidHistoryAndDoesNotInventUnusedItems() throws {
        var usage=SymbolUsage();usage.record("private host text",allowed:["."])
        XCTAssertTrue(usage.counts.isEmpty)
        usage.record(".",allowed:["."]);usage.record("★",allowed:["★"])
        XCTAssertEqual(usage.ordered(seed:["，","，"],catalog:[".","!"],limit:2),[".","，"])
        XCTAssertTrue(usage.ordered(seed:["."],catalog:[],limit:0).isEmpty)
        let invalid=Data(#"{"version":2,"counts":{".":1}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SymbolUsage.self,from:invalid).validate())
    }
}
