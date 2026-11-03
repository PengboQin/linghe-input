import XCTest

final class KeyboardPermissionProbeUITests: XCTestCase {
    @MainActor func testOpenTrialKeyboardForMetadata() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let preview = app.buttons["open-typing-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout:8))
        preview.tap()
        let field = app.textFields["sample-text"]
        XCTAssertTrue(field.waitForExistence(timeout:8))
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout:8))
        // The keyboard's viewDidAppear records hasFullAccess, learning-sharing
        // and reset-marker presence through the existing fixed diagnostics file.
        Thread.sleep(forTimeInterval: 2)
        if app.buttons["dismiss-keyboard"].exists { app.buttons["dismiss-keyboard"].tap() }
    }
}
