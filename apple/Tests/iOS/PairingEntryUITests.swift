import XCTest
final class PairingEntryUITests:XCTestCase {
    @MainActor func testNativeCodeEntryAndSilentConfiguredPolling() throws {
        continueAfterFailure=false
        let app=XCUIApplication()
        app.launchEnvironment["PRIVATE_INPUT_SIM_SYNC_SCOPE"]="shared35-pair41-"+UUID().uuidString
        app.launch()
        let entry=app.buttons["open-sync"]
        XCTAssertTrue(entry.waitForExistence(timeout:8));entry.tap()
        let server=app.textFields["sync-server"]
        XCTAssertTrue(server.waitForExistence(timeout:5))
        XCTAssertTrue(app.buttons["sync-scan"].exists)
        XCTAssertTrue(app.textFields["sync-access-code"].exists)
        XCTAssertFalse(app.textFields["sync-invitation"].exists)
        guard let value=server.value as? String,value.hasPrefix("https://"),!value.contains("example") else {throw XCTSkip("Private relay build required for isolated live UI polling")}
        app.buttons["sync-create"].tap()
        XCTAssertTrue(app.staticTexts["sync-device-count"].waitForExistence(timeout:12))
        let toggle=app.switches["sync-learning"]
        XCTAssertTrue(toggle.waitForExistence(timeout:5));let inner=toggle.switches.firstMatch
        if inner.exists {inner.tap()} else {toggle.tap()}
        let enabled=XCTNSPredicateExpectation(predicate:NSPredicate(format:"value == '1'"),object:toggle)
        XCTAssertEqual(XCTWaiter.wait(for:[enabled],timeout:5),.completed)
        let ready=XCTNSPredicateExpectation(predicate:NSPredicate(format:"enabled == true"),object:app.buttons["sync-now"])
        XCTAssertEqual(XCTWaiter.wait(for:[ready],timeout:5),.completed)
        for _ in 0..<20 {
            XCTAssertFalse(app.progressIndicators["sync-foreground-progress"].exists)
            XCTAssertTrue(app.buttons["sync-now"].isEnabled)
            Thread.sleep(forTimeInterval:1)
        }
        app.buttons["sync-invite"].tap()
        XCTAssertTrue(app.staticTexts["quick-pair-code"].waitForExistence(timeout:10))
        let code=try XCTUnwrap(app.staticTexts["quick-pair-code"].label as String?)
        XCTAssertEqual(code.count,6)
        app.buttons["完成"].firstMatch.tap()
        XCTAssertTrue(app.buttons["sync-invite"].waitForExistence(timeout:5))
    }
}
