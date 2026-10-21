import XCTest
@testable import PrivateInputKit
final class DesktopCandidateLayoutTests:XCTestCase {
    func testDefaultsAndIndependentClosedExpandedDimensions() {
        let value=DesktopCandidateLayout();XCTAssertEqual(value.collapsedCount,6);XCTAssertEqual(value.pageSize,36)
        let mixed=DesktopCandidateLayout(collapsedCount:9,expandedColumns:5,expandedRows:4)
        XCTAssertEqual(mixed.columns(expanded:false),9);XCTAssertEqual(mixed.columns(expanded:true),5);XCTAssertEqual(mixed.pageSize,20)
    }
    func testCorruptAndMissingFieldsCannotCreateHugeOrEmptyGrids() throws {
        let clamped=try JSONDecoder().decode(DesktopCandidateLayout.self,from:Data("{\"collapsedCount\":-9,\"expandedColumns\":999999,\"expandedRows\":0}".utf8))
        XCTAssertEqual(clamped,.init(collapsedCount:3,expandedColumns:9,expandedRows:3))
        XCTAssertEqual(try JSONDecoder().decode(DesktopCandidateLayout.self,from:Data("{}".utf8)),.init())
        XCTAssertThrowsError(try JSONDecoder().decode(DesktopCandidateLayout.self,from:Data("{\"collapsedCount\":\"wrong\"}".utf8)))
        XCTAssertEqual(DesktopCandidateLayout(collapsedCount:Int.min,expandedColumns:Int.max,expandedRows:Int.max).pageSize,81)
    }
    func testLocalSettingsRoundTripPreservesIndependentDimensions() throws {
        let input=DesktopCandidateLayout(collapsedCount:7,expandedColumns:4,expandedRows:8)
        XCTAssertEqual(try JSONDecoder().decode(DesktopCandidateLayout.self,from:JSONEncoder().encode(input)),input)
    }
}
