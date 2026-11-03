import XCTest

final class LearnedVocabularyUITests: XCTestCase {
    @MainActor func testSavedRowsSearchRefreshAndEmptyState() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()

        app.buttons["open-learning-settings"].tap()
        let entry = app.buttons["open-learned-vocabulary"]
        XCTAssertTrue(entry.waitForExistence(timeout:5))
        entry.tap()

        XCTAssertTrue(app.navigationBars["已学习词汇"].waitForExistence(timeout:5))
        let row = app.descendants(matching: .any).matching(identifier: "learned-vocabulary-row").firstMatch
        guard row.waitForExistence(timeout:8) else { throw XCTSkip("App Group needs a synthetic learning-v1.json fixture") }
        XCTAssertTrue(row.label.contains("拟好"), row.label)
        XCTAssertTrue(row.label.contains("1,000 次") || row.label.contains("1000 次"), row.label)
        attach(app, name: "learned-vocabulary-light")
        let rows = app.descendants(matching: .any).matching(identifier: "learned-vocabulary-row")
        for index in 0..<rows.count where rows.count > 0 {
            XCTAssertFalse(rows.element(boundBy: index).label.contains("已删除"), "deleted entry must stay hidden")
        }

        app.buttons["刷新"].tap()
        XCTAssertTrue(row.waitForExistence(timeout:8))
        XCTAssertTrue(row.label.contains("拟好"), row.label)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(entry.waitForExistence(timeout:5))
        entry.tap()
        XCTAssertTrue(row.waitForExistence(timeout:8))

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout:5))
        search.tap()
        search.typeText("ni hao")
        XCTAssertTrue(row.waitForExistence(timeout:5))
        XCTAssertTrue(row.label.contains("拟好"), row.label)

        search.typeText("zzz")
        XCTAssertTrue(app.staticTexts["没有匹配的词汇。"].waitForExistence(timeout:5))

        let clear = search.buttons["Clear text"]
        if clear.exists { clear.tap() } else {
            search.tap()
            search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 9))
        }
        XCTAssertTrue(row.waitForExistence(timeout:5))
    }

    @MainActor func testDarkAppearanceRowsReadable() throws {
        continueAfterFailure = false
        XCUIDevice.shared.appearance = .dark
        defer { XCUIDevice.shared.appearance = .light }
        let app = XCUIApplication()
        app.launch()
        app.buttons["open-learning-settings"].tap()
        app.buttons["open-learned-vocabulary"].tap()
        let row = app.descendants(matching: .any).matching(identifier: "learned-vocabulary-row").firstMatch
        guard row.waitForExistence(timeout:8) else { throw XCTSkip("App Group needs a synthetic learning-v1.json fixture") }
        XCTAssertTrue(row.label.contains("拟好"), row.label)
        attach(app, name: "learned-vocabulary-dark")
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
