import XCTest

/// Explicit physical-device acceptance only; no simulator preferences or real
/// clipboard are read. The invitation is supplied by the private test runner.
final class RealDeviceSyncUITests:XCTestCase {
    override func setUpWithError() throws { continueAfterFailure=false }
    @MainActor private func shown(_ element:XCUIElement,in app:XCUIApplication) {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            app.collectionViews.firstMatch.swipeUp()
        }
    }
    @MainActor private func enable(_ element:XCUIElement,in app:XCUIApplication) {
        shown(element,in:app)
        if element.value as? String != "1" {
            let inner=element.switches.firstMatch
            if inner.exists { inner.tap() } else { element.tap() }
        }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"value == '1'"),object:element)],timeout:10),.completed)
    }
    @MainActor func testPairWithRealMacAndReceivePersonalEntries() throws {
        guard ProcessInfo.processInfo.environment["PRIVATE_INPUT_REAL_SYNC_ACCEPTANCE"]=="1",
              let invitation=ProcessInfo.processInfo.environment["PRIVATE_INPUT_REAL_INVITATION"] else {
            throw XCTSkip("Run only the private physical-device acceptance workflow")
        }
        let app=XCUIApplication();app.launch()
        let devices=app.buttons["设备与同步"];XCTAssertTrue(devices.waitForExistence(timeout:15));devices.tap()
        let input=app.textFields["sync-invitation"];XCTAssertTrue(input.waitForExistence(timeout:10))
        input.tap()
        let chinese=app.inputItem("key-中")
        if chinese.waitForExistence(timeout:3) { chinese.tap() }
        input.typeText(invitation)
        XCTAssertEqual(input.value as? String,invitation)
        let join=app.inputItem("sync-join");shown(join,in:app);join.tap()
        let getCode=app.inputItem("sync-get-code"),code=app.staticTexts["sync-code"]
        XCTAssertTrue(getCode.waitForExistence(timeout:20))
        print("REAL_SYNC_PHASE=request-submitted")
        for _ in 0..<90 {
            if code.exists { break }
            shown(getCode,in:app);if getCode.isEnabled { getCode.tap() }
            if code.waitForExistence(timeout:1) { break }
        }
        XCTAssertTrue(code.exists,"Mac must issue a challenge for this request")
        print("REAL_SYNC_PHONE_CODE="+code.label)
        let confirm=app.inputItem("sync-confirm"),count=app.inputItem("sync-device-count")
        func paired() -> Bool {
            count.exists && (count.label+(count.value as? String ?? "")+count.staticTexts.allElementsBoundByIndex.map(\.label).joined()).contains("2 台设备")
        }
        for _ in 0..<90 {
            if paired() { break }
            if confirm.exists && confirm.isEnabled { shown(confirm,in:app);confirm.tap() }
            _ = count.waitForExistence(timeout:1)
        }
        XCTAssertTrue(count.exists,"Mac confirmation and phone grant acceptance required")
        XCTAssertTrue(paired(),count.label)
        print("REAL_SYNC_PHASE=paired")
        enable(app.switches["sync-learning"],in:app)
        enable(app.switches["sync-clipboard"],in:app)
        let sync=app.inputItem("sync-now");shown(sync,in:app);sync.tap()
        app.navigationBars.buttons.element(boundBy:0).tap()
        app.buttons["键盘与词库"].tap()
        let personal=app.inputItem("open-personal-lexicon");shown(personal,in:app);personal.tap()
        let word=app.inputItem("personal-entry-he cheng tong bu ci")
        let phrase=app.inputItem("personal-entry-tbcs")
        XCTAssertTrue(word.waitForExistence(timeout:15))
        XCTAssertTrue(phrase.waitForExistence(timeout:15))
        XCTAssertTrue(word.label.contains("合成同步词"))
        XCTAssertTrue(phrase.label.contains("合成快捷短语"))
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="physical-phone-received-mac-word-and-phrase";shot.lifetime = .keepAlways;add(shot)
        print("REAL_SYNC_PHASE=mac-word-and-phrase-received")
    }
}
