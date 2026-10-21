import XCTest

final class SyncUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func visible(_ element: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<8 {
            if element.exists && element.frame.height > 0 && element.frame.midY > 80 && element.frame.midY < app.frame.maxY - 80 && element.isHittable { return }
            app.collectionViews.firstMatch.swipeUp()
        }
    }
    @MainActor private func enable(_ toggle: XCUIElement, in app: XCUIApplication) {
        visible(toggle, app)
        let inner = toggle.switches.firstMatch
        if inner.exists { inner.tap() } else { toggle.tap() }
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed, "Consent must remain on")
    }
    private struct Peer: Decodable { let invitation: String; let code: String?; let received_from_ios: Bool; let phase: String }
    private func peer(_ url: URL) async throws -> Peer {
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(Peer.self, from: data)
    }
    private func requireOwnKeyboard(_ app: XCUIApplication) {
        if app.buttons["key-n"].waitForExistence(timeout: 3) || app.buttons["nine-2"].exists || app.inputItem("clear-composition").exists { return }
        let globe = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Next keyboard' OR label CONTAINS[c] 'Switch keyboard' OR identifier == 'switch-system-keyboard' OR label CONTAINS '下一个键盘' OR label CONTAINS '切换键盘'")).firstMatch
        XCTAssertTrue(globe.waitForExistence(timeout: 5)); globe.press(forDuration: 1)
        let choices = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '灵鹤输入法'"))
        XCTAssertTrue(choices.firstMatch.waitForExistence(timeout: 5))
        guard let ours = choices.allElementsBoundByIndex.first(where: { $0.isHittable && $0.frame.midY > app.frame.height / 2 }) else { XCTFail("Own keyboard must be offered by the system"); return }
        ours.tap(); XCTAssertTrue(app.inputItem("clear-composition").waitForExistence(timeout: 10))
    }
    @MainActor func testNativeSharedTextPagesAndActualKeyboard() async throws {
        guard let address=ProcessInfo.processInfo.environment["PRIVATE_INPUT_UI_CONTROL"],let url=URL(string:address) else { throw XCTSkip("Owned local relay required") }
        let app=XCUIApplication()
        app.launchEnvironment["PRIVATE_INPUT_SIM_SYNC_SCOPE"]=ProcessInfo.processInfo.environment["PRIVATE_INPUT_SIM_SYNC_SCOPE"]
        app.launch()
        let open=app.inputItem("open-sync");visible(open,app);open.tap()
        let disconnect=app.inputItem("sync-disconnect")
        if disconnect.waitForExistence(timeout:2) {
            visible(disconnect,app);disconnect.tap();app.sheets.buttons["断开连接"].tap()
        }
        let change=app.inputItem("sync-change-invitation")
        if change.waitForExistence(timeout:1) { visible(change,app);change.tap() }
        let invitation=app.textFields["sync-invitation"];XCTAssertTrue(invitation.waitForExistence(timeout:8))
        invitation.tap();invitation.typeText(try await peer(url).invitation)
        let join=app.inputItem("sync-join");visible(join,app);join.tap()
        let getCode=app.inputItem("sync-get-code"),code=app.staticTexts["sync-code"]
        XCTAssertTrue(getCode.waitForExistence(timeout:10))
        for _ in 0..<8 {
            if code.exists { break };visible(getCode,app);getCode.tap();_ = code.waitForExistence(timeout:2)
        }
        let expectedCode=try await peer(url).code
        XCTAssertEqual(code.label,expectedCode)
        for _ in 0..<12 { if try await peer(url).phase == "paired" { break };try await Task.sleep(nanoseconds:500_000_000) }
        app.inputItem("sync-confirm").tap()
        let clipboard=app.switches["sync-clipboard"]
        XCTAssertTrue(clipboard.waitForExistence(timeout:10),"Pair result: " + app.staticTexts["sync-status"].debugDescription);enable(clipboard,in:app)
        let sync=app.inputItem("sync-now");visible(sync,app);sync.tap()
        let inbox=app.inputItem("sync-open-shared-text");visible(inbox,app);inbox.tap()
        let remote=app.staticTexts["SYNTHETIC-REMOTE-TEXT"]
        XCTAssertTrue(remote.waitForExistence(timeout:15))
        let mainShot=XCTAttachment(screenshot:app.screenshot());mainShot.name="native-main-shared-inbox";mainShot.lifetime = .keepAlways;add(mainShot)
        remote.tap();XCTAssertTrue(app.inputItem("copy-shared-text").isEnabled)
        XCTAssertEqual(app.staticTexts["shared-inbox-full-text"].label,"SYNTHETIC-REMOTE-TEXT")
        app.navigationBars.buttons.element(boundBy:0).tap()
        app.inputItem("compose-shared-text").tap()
        let outgoing=app.textViews["sync-outgoing"];XCTAssertTrue(outgoing.waitForExistence(timeout:5));outgoing.tap()
        requireOwnKeyboard(app)
        if app.inputItem("key-中").exists { app.inputItem("key-中").tap() }
        for letter in "syntheticiosmessage" { app.inputItem("key-"+String(letter)).tap() }
        XCTAssertEqual(outgoing.value as? String,"syntheticiosmessage")
        app.inputItem("sync-send").tap()
        var delivered=false
        for _ in 0..<15 { if try await peer(url).received_from_ios { delivered=true;break };try await Task.sleep(nanoseconds:500_000_000) }
        XCTAssertTrue(delivered,"Synthetic peer must decrypt the actual outgoing UI text")
        XCTAssertTrue(app.inputItem("compose-shared-text").waitForExistence(timeout:5))
        app.navigationBars.buttons.element(boundBy:0).tap();app.navigationBars.buttons.element(boundBy:0).tap()
        exerciseSystemKeyboard(fullAccessEnabled:true,verifySnapshot:false,chineseLayout:"nine")
        app.inputItem("clear-sample").tap()
        let field=app.descendants(matching:.any).matching(identifier:"sample-text").firstMatch
        let original=app.inputItem("nine-2").frame
        app.inputItem("open-shared-text").tap()
        let list=app.tables["shared-text-list"];XCTAssertTrue(list.waitForExistence(timeout:5))
        print("SHARED_LAYOUT key=\(original) list=\(list.frame)")
        XCTAssertFalse(app.inputItem("nine-2").isHittable)
        let long=list.cells.containing(NSPredicate(format:"label BEGINSWITH %@","共享长文本：")).firstMatch
        XCTAssertTrue(long.waitForExistence(timeout:5));long.buttons.firstMatch.tap()
        let full=app.textViews["shared-text-full-content"]
        XCTAssertTrue(full.waitForExistence(timeout:5));XCTAssertTrue((full.value as? String ?? "").hasSuffix("全文尾部标记"))
        full.swipeUp();XCTAssertEqual(field.value as? String,"")
        let detailShot=XCTAttachment(screenshot:app.screenshot());detailShot.name="native-keyboard-shared-full-text";detailShot.lifetime = .keepAlways;add(detailShot)
        app.navigationBars.buttons.matching(NSPredicate(format:"label == '共享文本'")).firstMatch.tap()
        let firstY=list.cells.firstMatch.frame.minY
        list.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.8)).press(forDuration:0.05,thenDragTo:list.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.15)))
        XCTAssertEqual(field.value as? String,"")
        XCTAssertTrue(!list.cells.firstMatch.isHittable || list.cells.firstMatch.frame.minY != firstY)
        app.inputItem("close-shared-text").tap();XCTAssertEqual(app.inputItem("nine-2").frame,original)
        app.inputItem("open-shared-text").tap();app.inputItem("refresh-shared-text").tap()
        let short=app.staticTexts["SYNTHETIC-REMOTE-TEXT"];XCTAssertTrue(short.waitForExistence(timeout:5));short.tap()
        XCTAssertEqual(field.value as? String,"SYNTHETIC-REMOTE-TEXT")
        XCTAssertTrue(app.inputItem("nine-2").isHittable)
        let keyboardShot=XCTAttachment(screenshot:app.screenshot());keyboardShot.name="shared-text-returned-to-keyboard";keyboardShot.lifetime = .keepAlways;add(keyboardShot)
        // Pausing from the main native settings page removes the old cache.
        app.inputItem("dismiss-keyboard").tap();app.inputItem("open-sync").tap()
        let off=app.switches["sync-clipboard"],control=off.switches.firstMatch
        if control.exists { control.tap() } else { off.tap() }
        app.navigationBars.buttons.element(boundBy:0).tap();field.tap();app.inputItem("open-shared-text").tap()
        XCTAssertTrue(app.staticTexts["shared-text-status"].label.contains("暂停"))
        XCTAssertFalse(app.staticTexts["SYNTHETIC-REMOTE-TEXT"].exists)
        app.inputItem("close-shared-text").tap();app.inputItem("dismiss-keyboard").tap()
        app.inputItem("open-sync").tap();let stop=app.inputItem("sync-disconnect");visible(stop,app);stop.tap();app.sheets.buttons["断开连接"].tap()
    }
    @MainActor func testDeviceJoinTextAndLearningInSystemKeyboard() async throws {
        guard let address = ProcessInfo.processInfo.environment["PRIVATE_INPUT_UI_CONTROL"], let url = URL(string: address) else { throw XCTSkip("Run scripts/test_ios_sync_ui.py with the owned counterpart") }
        let app = XCUIApplication(); app.launch()
        let open = app.buttons["open-sync"]
        visible(open, app); XCTAssertTrue(open.waitForExistence(timeout: 10)); open.tap()
        let disconnect = app.buttons["sync-disconnect"]
        if disconnect.waitForExistence(timeout: 2) {
            visible(disconnect, app); disconnect.tap()
            let action = app.sheets.buttons["断开连接"].firstMatch
            XCTAssertTrue(action.waitForExistence(timeout: 5)); action.tap()
        }
        let change = app.buttons["sync-change-invitation"]
        if change.waitForExistence(timeout: 2) { visible(change, app); change.tap() }
        let invitation = app.textFields["sync-invitation"]
        XCTAssertTrue(invitation.waitForExistence(timeout: 10)); invitation.tap(); invitation.typeText(try await peer(url).invitation)
        let join = app.buttons["sync-join"]; visible(join, app); join.tap()
        let getCode = app.buttons["sync-get-code"]
        XCTAssertTrue(getCode.waitForExistence(timeout: 15), "Join state: " + app.staticTexts["sync-status"].debugDescription)
        let code = app.staticTexts["sync-code"]
        for _ in 0..<8 {
            if code.exists { break }
            visible(getCode, app); getCode.tap()
            _ = code.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(code.exists)
        let expected = try await peer(url).code
        XCTAssertEqual(code.label, expected, "Actual iOS and native counterpart must derive the same code")
        // The synthetic owner still performs a separate confirmation step.
        // A joiner cannot request the group key until that step has completed.
        for _ in 0..<10 {
            if try await peer(url).phase == "paired" { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        let ownerPhase = try await peer(url).phase
        XCTAssertEqual(ownerPhase, "paired")
        let confirm = app.buttons["sync-confirm"]; visible(confirm, app); confirm.tap()
        let learning = app.switches["sync-learning"], clipboard = app.switches["sync-clipboard"]
        let connected = learning.waitForExistence(timeout: 15)
        let error = app.staticTexts["sync-status"]
        let reason = error.exists ? error.label + " " + (error.value as? String ?? "") : "no visible error"
        XCTAssertTrue(connected, "After confirmation: " + reason)
        XCTAssertEqual(learning.value as? String, "0"); XCTAssertEqual(clipboard.value as? String, "0")
        enable(learning, in: app); XCTAssertTrue(clipboard.waitForExistence(timeout: 5))
        enable(clipboard, in: app)
        let sync = app.buttons["sync-now"]; visible(sync, app); sync.tap()
        let remote = app.staticTexts["SYNTHETIC-REMOTE-TEXT"]
        visible(remote, app); XCTAssertTrue(remote.waitForExistence(timeout: 15))
        let outgoing = app.textViews["sync-outgoing"]; visible(outgoing, app); outgoing.tap()
        // typeText cannot faithfully generate our extension's keystrokes.
        // Exercise its real English, shift and symbol buttons instead.
        requireOwnKeyboard(app)
            app.buttons["key-中"].tap(); app.buttons["key-⇧"].tap()
            for chunk in ["SYNTHETIC", "IOS", "TEXT"] {
                for letter in chunk.map(String.init) { app.buttons["key-" + letter].tap() }
                if chunk != "TEXT" {
                    app.buttons["key-123"].tap(); app.buttons["key--"].tap(); app.buttons["key-ABC"].tap()
                }
            }
            app.buttons["key-英"].tap() // Restore Chinese and lower-case keys.
        XCTAssertEqual(outgoing.value as? String, "SYNTHETIC-IOS-TEXT")
        let send = app.buttons["sync-send"]; visible(send, app); send.tap()
        var delivered = false
        for _ in 0..<12 {
            if try await peer(url).received_from_ios { delivered = true; break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTAssertTrue(delivered, "Counterpart must decrypt the iOS text")
        app.terminate(); app.launch()
        exerciseSystemKeyboard(fullAccessEnabled: false, verifySnapshot: false, networkLearning: true)
        app.terminate(); app.launch()
        exerciseSystemKeyboard(fullAccessEnabled: false, verifySnapshot: false, sharedTextFixture: true)
        app.terminate(); app.launch()
        exerciseSystemKeyboard(fullAccessEnabled: true, verifySnapshot: false, sharedTextFixture: true)
        let done = app.buttons["dismiss-keyboard"]; if done.exists { done.tap() }
        for _ in 0..<3 { app.collectionViews.firstMatch.swipeDown() }
        let settings = app.buttons["open-sync"]; visible(settings, app); settings.tap()
        let clipConsent = app.switches["sync-clipboard"]
        visible(clipConsent, app)
        let inner = clipConsent.switches.firstMatch; if inner.exists { inner.tap() } else { clipConsent.tap() }
        let paused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0'"), object: clipConsent)
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 5), .completed)
        app.terminate(); app.launch()
        exerciseSystemKeyboard(fullAccessEnabled: true, verifySnapshot: false, sharedTextFixture: true, sharingPaused: true)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor func testStopSyntheticLabForDelivery() {
        let app = XCUIApplication(); app.launch()
        let open = app.buttons["open-sync"]; visible(open, app)
        XCTAssertTrue(open.waitForExistence(timeout: 10)); open.tap()
        let stop = app.buttons["sync-disconnect"]
        if stop.waitForExistence(timeout: 5) {
            visible(stop, app); stop.tap()
            let confirm = app.sheets.buttons["断开连接"].firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        }
        XCTAssertTrue(app.textFields["sync-invitation"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.switches["sync-learning"].exists)
        app.buttons["BackButton"].tap()
        XCTAssertTrue(app.buttons["clear-sample"].waitForExistence(timeout: 5))
    }
}
