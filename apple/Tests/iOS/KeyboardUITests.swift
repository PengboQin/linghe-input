import XCTest
import UIKit

private func compositionPosition(_ title:String,in app:XCUIApplication) {
    let language=app.inputItem("key-中")
    (language.exists ? language:app.inputItem("key-英")).press(forDuration:0.8)
    app.inputItem("布局与显示").tap();app.inputItem("拼音显示位置").tap();app.inputItem(title).tap()
}
final class KeyboardUITests: XCTestCase {
    private func clearSyntheticField(_ app:XCUIApplication) {
        // End the real editing session before changing the SwiftUI binding;
        // marked text is intentionally not published to that binding yet.
        let done=app.inputItem("dismiss-keyboard")
        if done.exists && done.isHittable {done.tap()}
        app.inputItem("clear-sample").tap();app.inputItem("sample-text").tap()
        XCTAssertEqual(app.inputItem("sample-text").value as? String,"")
    }
    private func back(_ app:XCUIApplication) {
        let visible=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in app.navigationBars.buttons.allElementsBoundByIndex.contains{$0.isHittable} },object:app)
        XCTAssertEqual(XCTWaiter.wait(for:[visible],timeout:5),.completed)
        let button=app.navigationBars.buttons.allElementsBoundByIndex.first{$0.isHittable}
        XCTAssertNotNil(button);button?.tap()
    }
    private func sharedMixed(_ enabled:Bool,in app:XCUIApplication) {
        app.inputItem("dismiss-keyboard").tap();app.inputItem("键盘与词库").tap()
        let toggle=app.switches["mixed-english-setting"]
        if (toggle.value as? String=="1") != enabled {
            let control=toggle.switches.firstMatch
            if control.exists { control.tap() } else { toggle.tap() }
        }
        back(app)
        let field=app.descendants(matching:.any).matching(identifier:"sample-text").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout:5));field.tap()
    }
    private func heightMenu(_ title:String,in app:XCUIApplication) {
        app.inputItem("key-中").press(forDuration:0.8)
        app.inputItem("布局与显示").tap();app.inputItem("键盘高度").tap();app.inputItem(title).tap()
    }
    func testChineseQuoteGridVisibleViewportDragDiagnostic() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launch()
        exerciseSystemKeyboard(fullAccessEnabled: true, verifySnapshot: false, chineseLayout: "pinyin26", freshHost: true)
        clearSyntheticField(app)
        app.inputItem("key-符").tap(); tapSymbolCategory("chinese", in: app)
        let grid = app.collectionViews["symbol-items"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        let newCode = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in grid.label.hasPrefix("symbol-grid-native-v3") }, object: grid)
        XCTAssertEqual(XCTWaiter.wait(for: [newCode], timeout: 5), .completed, "Require freshly laid-out native grid diagnostics before interpreting a drag")
        let body = app.inputItem("keyboard-body")
        let footerTop = app.inputItem("return-symbols").frame.minY
        var viewport = grid.frame.intersection(app.frame)
        if body.exists { viewport = viewport.intersection(body.frame) }
        viewport.size.height = max(0, min(viewport.maxY, footerTop) - viewport.minY)
        XCTAssertGreaterThan(viewport.height, 60)
        print("QUOTE_GRID_FRAMES grid=\(grid.frame) body=\(body.exists ? body.frame : .zero) footerTop=\(footerTop) safeViewport=\(viewport)")
        func visibleIDs() -> [String] {
            grid.cells.allElementsBoundByIndex.filter { cell in
                cell.exists && cell.frame.intersection(viewport).height >= cell.frame.height * 0.8 && cell.isHittable
            }.map(\.identifier)
        }
        func capture(_ name: String) {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "quote-grid-" + name; shot.lifetime = .keepAlways; add(shot)
        }
        let before = visibleIDs(); print("QUOTE_GRID_BEFORE \(before) native=\(grid.value ?? "nil") label=\(grid.label)"); capture("before-safe-drag")
        let quote = grid.cells["symbol-“"]
        for trial in 0..<6 {
            if quote.exists && quote.isHittable && quote.frame.intersection(viewport).height >= quote.frame.height * 0.8 { break }
            // Anchor into the remote keyboard collection's own window.
            // App-global coordinates can be routed to the host behind it.
            let origin = grid.coordinate(withNormalizedOffset: .zero)
            let localX = viewport.midX - grid.frame.minX
            let localTop = viewport.minY - grid.frame.minY
            let from = origin.withOffset(CGVector(dx: localX, dy: localTop + viewport.height * 0.78))
            let to = origin.withOffset(CGVector(dx: localX, dy: localTop + viewport.height * 0.22))
            from.press(forDuration: 0.05, thenDragTo: to)
            print("QUOTE_GRID_AFTER \(trial) \(visibleIDs()) native=\(grid.value ?? "nil") label=\(grid.label)")
        }
        capture("after-safe-drag")
        let nativeText = (grid.value as? String) ?? String(grid.label.dropFirst("symbol-grid-native-v3 ".count))
        let native = nativeText.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        XCTAssertNotNil(native, "The active remote collection must expose its native diagnostics")
        XCTAssertGreaterThan((native?["routedHits"] as? NSNumber)?.intValue ?? 0, 0, "The drag must reach the keyboard's own hit-test route")
        XCTAssertGreaterThan((native?["panBegins"] as? NSNumber)?.intValue ?? 0, 0, "A native collection pan must begin")
        XCTAssertGreaterThan((native?["offset"] as? NSNumber)?.doubleValue ?? 0, 0, "The symbol collection itself must scroll")
        XCTAssertNotEqual(visibleIDs(), before, "Dragging inside the visible symbol grid must move its content")
        XCTAssertTrue(quote.exists); XCTAssertTrue(quote.isHittable)
        quote.tap()
        XCTAssertEqual(app.inputItem("sample-text").value as? String, "“”")
    }
    func testSymbolPairingAndCaretPlacementFollowIndependentSettings() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launch()
        exerciseSystemKeyboard(fullAccessEnabled: true, verifySnapshot: false, chineseLayout: "pinyin26", freshHost: true)
        clearSyntheticField(app)
        func requireEnglishForLiteralProbe() {
            // Returning from App settings / refocusing can recreate the extension
            // in its configured default Chinese mode. Re-establish the fixture
            // after each fresh host session, before checking literal cursor edits.
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                app.inputItem("key-中").exists || app.inputItem("key-英").exists
            }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
            if app.inputItem("key-中").exists { app.inputItem("key-中").tap() }
            XCTAssertTrue(app.inputItem("key-英").waitForExistence(timeout: 5))
        }
        func tapVisibleSymbol(_ symbol: String) {
            let grid = app.collectionViews["symbol-items"]
            XCTAssertTrue(grid.waitForExistence(timeout: 5))
            let item = grid.cells["symbol-" + symbol]
            var viewport = grid.frame.intersection(app.frame)
            let footerTop = app.inputItem("return-symbols").frame.minY
            viewport.size.height = max(0, min(viewport.maxY, footerTop) - viewport.minY)
            XCTAssertGreaterThan(viewport.height, 60)
            // Scroll only this collection's visible interior. Never cross into
            // the category rail, footer keys or the containing App's form.
            for _ in 0..<10 {
                if item.exists && item.isHittable {
                    let visible = item.frame.intersection(viewport)
                    if visible.height >= item.frame.height * 0.8 { item.tap(); return }
                }
                let origin = grid.coordinate(withNormalizedOffset: .zero)
                let localX = viewport.midX - grid.frame.minX
                let localTop = viewport.minY - grid.frame.minY
                let from = origin.withOffset(CGVector(dx: localX, dy: localTop + viewport.height * 0.78))
                let to = origin.withOffset(CGVector(dx: localX, dy: localTop + viewport.height * 0.22))
                from.press(forDuration: 0.05, thenDragTo: to)
            }
            XCTFail("Symbol must be reachable in its own grid: " + symbol)
        }
        func setOptions(autoPair: Bool, caretInside: Bool) {
            let done = app.inputItem("dismiss-keyboard")
            if done.exists && done.isHittable { done.tap() }
            let settings = app.inputItem("键盘与词库"); keyboardReveal(settings, in: app); settings.tap()
            for (identifier, enabled) in [("symbol-auto-pair-setting", autoPair), ("symbol-caret-inside-setting", caretInside)] {
                let toggle = app.switches[identifier]
                keyboardReveal(toggle, in: app); XCTAssertTrue(toggle.waitForExistence(timeout: 5)); XCTAssertTrue(toggle.isHittable)
                if (toggle.value as? String == "1") != enabled {
                    let control = toggle.switches.firstMatch
                    if control.exists { control.tap() } else { toggle.tap() }
                }
                XCTAssertEqual(toggle.value as? String, enabled ? "1" : "0")
            }
            back(app); app.inputItem("sample-text").tap()
        }
        for (autoPair, inside, expected) in [(true, true, "(x)"), (true, false, "()x"), (false, true, "(x"), (false, false, "(x")] {
            setOptions(autoPair: autoPair, caretInside: inside)
            clearSyntheticField(app)
            requireEnglishForLiteralProbe()
            app.inputItem("key-符").tap(); tapSymbolCategory("english", in: app)
            tapVisibleSymbol("(")
            XCTAssertEqual(app.inputItem("sample-text").value as? String, autoPair ? "()" : "(")
            app.inputItem("return-symbols").tap(); XCTAssertTrue(app.inputItem("key-英").exists); app.inputItem("key-x").tap()
            XCTAssertEqual(app.inputItem("sample-text").value as? String, expected)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "symbol-pair-auto-\(autoPair)-inside-\(inside)"; shot.lifetime = .keepAlways; add(shot)
        }
        setOptions(autoPair: true, caretInside: true)
        clearSyntheticField(app)
        requireEnglishForLiteralProbe()
        // Curly-quote scrolling has its own focused native-pan acceptance case.
        // Keep this non-scroll matrix independent of remote drag delivery.
        app.inputItem("key-符").tap(); tapSymbolCategory("english", in: app)
        tapVisibleSymbol("\"")
        app.inputItem("return-symbols").tap(); XCTAssertTrue(app.inputItem("key-英").exists); app.inputItem("key-x").tap()
        XCTAssertEqual(app.inputItem("sample-text").value as? String, "\"x\"")
        clearSyntheticField(app)
        requireEnglishForLiteralProbe()
        app.inputItem("key-符").tap(); tapSymbolCategory("english", in: app)
        tapVisibleSymbol("'")
        app.inputItem("return-symbols").tap(); XCTAssertTrue(app.inputItem("key-英").exists); app.inputItem("key-x").tap()
        XCTAssertEqual(app.inputItem("sample-text").value as? String, "'x", "An English apostrophe must stay raw")
    }
    func testNineInitialFiltersStayExtendableAndChineseLimKeepsPriority() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launch()
        exerciseSystemKeyboard(fullAccessEnabled: true, verifySnapshot: false, chineseLayout: "nine", freshHost: true)
        sharedMixed(true, in: app)
        clearSyntheticField(app)
        let field = app.inputItem("sample-text")
        func capture(_ name: String) {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "initial-filter-lim-" + name; shot.lifetime = .keepAlways; add(shot)
        }
        func revealReading(_ reading: String) -> XCUIElement {
            let rail = app.collectionViews["pinyin-filter"]
            XCTAssertTrue(rail.waitForExistence(timeout: 5))
            let item = app.inputItem("pinyin-" + reading)
            for _ in 0..<12 { if item.exists && item.isHittable { break }; rail.swipeUp() }
            XCTAssertTrue(item.exists, "Valid unfinished reading must remain available: " + reading)
            XCTAssertTrue(item.isHittable, "The complete rail must scroll to: " + reading)
            return item
        }
        app.inputItem("nine-3").tap()
        for reading in ["d", "e", "f"] { XCTAssertTrue(app.inputItem("pinyin-" + reading).waitForExistence(timeout: 5)) }
        capture("single-three-d-e-f")
        app.inputItem("pinyin-d").tap()
        XCTAssertEqual(field.value as? String, "", "An unfinished spelling filter must not commit text")
        app.inputItem("nine-8").tap(); app.inputItem("nine-4").tap()
        let dui = app.inputItem("key-对")
        XCTAssertTrue(dui.waitForExistence(timeout: 8))
        if !dui.isHittable { app.inputItem("expand-candidates").tap() }
        XCTAssertTrue(dui.isHittable); dui.tap()
        XCTAssertEqual(field.value as? String, "对", "Selecting d then typing 84 must commit exactly one 对")
        capture("d-then-84-single-commit")
        // A new, longer pending sentence must not erase the preceding commit.
        for digit in "782636874472666" { app.inputItem("nine-" + String(digit)).tap() }
        revealReading("quan").tap()
        _ = revealReading("d"); _ = revealReading("f")
        capture("quan-tail-manual-d-f")
        XCTAssertEqual(field.value as? String, "对")
        app.inputItem("clear-composition").tap()
        XCTAssertEqual(field.value as? String, "对", "Clear only the pending sentence")
        app.inputItem("key-中").press(forDuration: 0.8)
        app.inputItem("布局与显示").tap(); app.inputItem("中文26键").tap()
        compositionPosition("拼音在文本框内", in: app)
        for letter in "lim" { app.inputItem("key-" + String(letter)).tap() }
        XCTAssertTrue(app.inputItem("key-里面").waitForExistence(timeout: 8))
        let strip = app.collectionViews["candidate-strip"]
        let first = strip.cells.firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let firstText = first.identifier.hasPrefix("key-") ? String(first.identifier.dropFirst(4)) : first.label
        XCTAssertTrue(firstText.unicodeScalars.contains { $0.properties.isIdeographic }, "Chinese abbreviation evidence must precede system English guesses")
        let marked = field.value as? String ?? ""
        XCTAssertTrue(marked.hasPrefix("对")); XCTAssertTrue(marked.contains("li m"))
        XCTAssertFalse(marked.lowercased().contains("limit"), "Pending text must retain the typed pinyin")
        capture("lim-inline-chinese-first")
        app.inputItem("expand-candidates").tap()
        let grid = app.collectionViews["candidate-list"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        func visibleEnglish() -> XCUIElement? {
            grid.cells.allElementsBoundByIndex.first { cell in
                let text = cell.identifier.hasPrefix("key-") ? String(cell.identifier.dropFirst(4)) : cell.label
                return text.count >= 3 && text.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) } && cell.isHittable
            }
        }
        for _ in 0..<6 { if visibleEnglish() != nil { break }; grid.swipeUp() }
        capture("lim-english-remains-selectable")
        guard let english = visibleEnglish() else { XCTFail("An English completion must remain reachable by an explicit choice"); return }
        let englishText = english.identifier.hasPrefix("key-") ? String(english.identifier.dropFirst(4)) : english.label
        english.tap()
        XCTAssertEqual(field.value as? String, "对" + englishText)
        compositionPosition("拼音在键盘内", in: app)
    }
    func testSelectableThemesPropagateToSystemKeyboardAndSharedPanel() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launch()
        exerciseSystemKeyboard(fullAccessEnabled: true, verifySnapshot: false, chineseLayout: "nine", freshHost: true)
        func capture(_ name: String) {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "theme59-" + name; shot.lifetime = .keepAlways; add(shot)
        }
        func openAppearance() {
            let done = app.inputItem("dismiss-keyboard")
            if done.exists && done.isHittable { done.tap() }
            let settings = app.inputItem("键盘与词库")
            keyboardReveal(settings, in: app); settings.tap()
            XCTAssertTrue(app.navigationBars["输入设置"].waitForExistence(timeout: 5))
        }
        func choose(_ identifier: String, _ title: String) {
            let picker = app.inputItem(identifier)
            keyboardReveal(picker, in: app)
            XCTAssertTrue(picker.waitForExistence(timeout: 5)); XCTAssertTrue(picker.isHittable)
            picker.tap()
            let option = app.inputItem(title)
            XCTAssertTrue(option.waitForExistence(timeout: 5)); option.tap()
            let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard picker.exists else { return false }
                return (picker.value as? String)?.contains(title) == true || picker.label.contains(title)
            }, object: picker)
            XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed, "Main App picker must read back " + title)
        }
        for (mode, accent, name) in [("浅色", "紫藤", "light-violet"), ("深色", "琥珀", "dark-amber")] {
            openAppearance()
            choose("ios-theme-mode", mode); choose("ios-theme-accent", accent)
            capture(name + "-settings")
            back(app)
            clearSyntheticField(app)
            XCTAssertTrue(app.inputItem("nine-6").waitForExistence(timeout: 10))
            for digit in "64426" { app.inputItem("nine-" + String(digit)).tap() }
            XCTAssertTrue(app.inputItem("key-你好").waitForExistence(timeout: 8))
            capture(name + "-candidate-strip")
            app.inputItem("expand-candidates").tap()
            let candidates = app.collectionViews["candidate-list"]
            XCTAssertTrue(candidates.waitForExistence(timeout: 5))
            capture(name + "-expanded-candidates")
            let hello = candidates.cells["key-你好"]
            XCTAssertTrue(hello.isHittable); hello.tap()
            XCTAssertEqual(app.inputItem("sample-text").value as? String, "你好")
            XCTAssertFalse(candidates.isHittable)
            // Post-commit continuations occupy the header. Start a fresh empty
            // synthetic document before testing the idle shared-text toolbar.
            clearSyntheticField(app)
            let shared = app.inputItem("open-shared-text")
            XCTAssertTrue(shared.waitForExistence(timeout: 5)); shared.tap()
            XCTAssertTrue(app.tables["shared-text-list"].waitForExistence(timeout: 5))
            capture(name + "-shared-text")
            app.inputItem("close-shared-text").tap()
            XCTAssertTrue(app.inputItem("nine-6").isHittable)
        }
        openAppearance()
        choose("ios-theme-mode", "跟随系统"); choose("ios-theme-accent", "胭脂")
        capture("restored-system-rose-settings")
        back(app)
    }
    func testCandidateEdgeTapsCommitDisplayedWordAndLongPressCanCancel() {
        continueAfterFailure=false
        let app=XCUIApplication();app.launch()
        app.inputItem("sample-text").tap()
        if !app.inputItem("nine-4").waitForExistence(timeout:3) {
            exerciseSystemKeyboard(fullAccessEnabled:false,verifySnapshot:false,chineseLayout:"nine",freshHost:true)
        }
        compositionPosition("拼音在键盘内",in:app)
        for expanded in [false,true] {
            clearSyntheticField(app)
            for d in "64426" {app.inputItem("nine-"+String(d)).tap()}
            if expanded {app.inputItem("expand-candidates").tap()}
            let collection=app.collectionViews[expanded ? "candidate-list":"candidate-strip"]
            let first=collection.cells.firstMatch
            XCTAssertTrue(first.waitForExistence(timeout:8));XCTAssertTrue(first.isHittable)
            let text=first.label,frame=first.frame
            XCTAssertGreaterThanOrEqual(frame.height,44)
            XCTAssertGreaterThanOrEqual(frame.width,44)
            // Exercise the full cell edge, not just the visible glyph centre.
            let visible=frame.intersection(collection.frame).intersection(app.frame)
            XCTAssertGreaterThan(visible.width,4);XCTAssertGreaterThan(visible.height,4)
            print("SYNTHETIC_CANDIDATE_TOUCH expanded=\(expanded) cell=\(frame) collection=\(collection.frame) visible=\(visible)")
            first.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:visible.minX-frame.minX+1,dy:visible.midY-frame.minY)).tap()
            let shot=XCTAttachment(screenshot:app.screenshot());shot.name="candidate-edge-after-tap";shot.lifetime = .keepAlways;add(shot)
            let pending=app.inputItem("composition-preedit")
            let pendingValue = pending.exists ? (pending.value as? String ?? "visible") : "none"
            print("SYNTHETIC_CANDIDATE_AFTER field=\(app.inputItem("sample-text").value ?? "nil") composition=\(pendingValue)")
            XCTAssertEqual(app.inputItem("sample-text").value as? String,text)
            XCTAssertFalse(app.inputItem("collapse-candidates").exists)
        }
        clearSyntheticField(app)
        for d in "64426" {app.inputItem("nine-"+String(d)).tap()}
        let first=app.collectionViews["candidate-strip"].cells.firstMatch
        XCTAssertTrue(first.waitForExistence(timeout:8))
        let dismissalPoint = CGPoint(x:app.frame.width * 0.85,y:first.frame.minY+4)
        first.press(forDuration:0.8)
        let pin=app.inputItem("恢复默认词频")
        XCTAssertTrue(pin.waitForExistence(timeout:5))
        XCTAssertEqual(app.inputItem("sample-text").value as? String,"")
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="candidate-rounded-long-press";shot.lifetime = .keepAlways;add(shot)
        // The menu belongs to the remote keyboard scene; dismiss inside that
        // scene, outside the menu, and allow UIKit's dismissal animation.
        // Native menus hide underlying remote-scene accessibility elements;
        // use the pre-menu geometry rather than querying the hidden strip.
        app.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:dismissalPoint.x,dy:dismissalPoint.y)).tap()
        let dismissed = XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:pin)
        XCTAssertEqual(XCTWaiter.wait(for:[dismissed],timeout:3),.completed)
        XCTAssertEqual(app.inputItem("sample-text").value as? String,"")
    }
    func testCandidateLeadingTouchDeliveryDiagnostic() {
        continueAfterFailure=false
        let app=XCUIApplication();app.launch()
        app.inputItem("sample-text").tap()
        if !app.inputItem("nine-4").waitForExistence(timeout:3) {
            exerciseSystemKeyboard(fullAccessEnabled:false,verifySnapshot:false,chineseLayout:"nine")
        }
        clearSyntheticField(app)
        for d in "64426" {app.inputItem("nine-"+String(d)).tap()}
        let field=app.inputItem("sample-text"),strip=app.collectionViews["candidate-strip"]
        var submitted=false
        for offset:CGFloat in [1,5,9,13,17,25,31] {
            let first=strip.cells.firstMatch,frame=first.frame,text=first.label
            first.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:offset,dy:frame.height/2)).tap()
            let value=field.value as? String ?? ""
            print("SYNTHETIC_LEADING_PROBE physical_x=\(frame.minX+offset) frame=\(frame) committed=\(!value.isEmpty)")
            if !value.isEmpty {XCTAssertEqual(value,text);submitted=true;break}
        }
        XCTAssertTrue(submitted)
    }
    func testCandidateAndSymbolGridPanNeverCommitsTouchedCell() {
        continueAfterFailure=false
        let app=XCUIApplication();app.launch()
        app.inputItem("sample-text").tap()
        if !app.inputItem("nine-4").waitForExistence(timeout:3) {
            exerciseSystemKeyboard(fullAccessEnabled:false,verifySnapshot:false,chineseLayout:"nine",freshHost:true)
        }
        compositionPosition("拼音在键盘内",in:app)
        clearSyntheticField(app)
        for d in "744" {app.inputItem("nine-"+String(d)).tap()}
        let field=app.inputItem("sample-text"),preedit=app.inputItem("composition-preedit")
        let raw=preedit.value as? String,strip=app.collectionViews["candidate-strip"]
        strip.coordinate(withNormalizedOffset:CGVector(dx:0.75,dy:0.5)).press(forDuration:0.05,thenDragTo:strip.coordinate(withNormalizedOffset:CGVector(dx:0.25,dy:0.5)))
        XCTAssertEqual(field.value as? String,"");XCTAssertEqual(preedit.value as? String,raw)
        app.inputItem("expand-candidates").tap()
        let grid=app.collectionViews["candidate-list"]
        grid.coordinate(withNormalizedOffset:CGVector(dx:0.4,dy:0.75)).press(forDuration:0.05,thenDragTo:grid.coordinate(withNormalizedOffset:CGVector(dx:0.4,dy:0.25)))
        XCTAssertEqual(field.value as? String,"");XCTAssertEqual(preedit.value as? String,raw)
        app.inputItem("collapse-candidates").tap();app.inputItem("clear-composition").tap()
        app.inputItem("key-符").tap()
        let symbols=app.collectionViews["symbol-items"]
        XCTAssertTrue(symbols.waitForExistence(timeout:5))
        symbols.coordinate(withNormalizedOffset:CGVector(dx:0.4,dy:0.75)).press(forDuration:0.05,thenDragTo:symbols.coordinate(withNormalizedOffset:CGVector(dx:0.4,dy:0.25)))
        XCTAssertEqual(field.value as? String,"")
        app.inputItem("return-symbols").tap()
    }
    func testFirstBackspaceDismissesCommittedWordPredictionsAndSecondDeletesText() {
        continueAfterFailure=false
        let app=XCUIApplication();app.launch()
        exerciseSystemKeyboard(fullAccessEnabled:true,verifySnapshot:false,chineseLayout:"pinyin26",freshHost:true)
        clearSyntheticField(app)
        for letter in "yinwei" {app.inputItem("key-"+String(letter)).tap()}
        let word=app.collectionViews["candidate-strip"].cells["key-因为"]
        XCTAssertTrue(word.waitForExistence(timeout:5));word.tap()
        let field=app.inputItem("sample-text"),strip=app.collectionViews["candidate-strip"]
        XCTAssertEqual(field.value as? String,"因为")
        XCTAssertTrue(strip.cells.firstMatch.waitForExistence(timeout:5),"Fixture must contain a real post-commit continuation")
        app.inputItem("key-⌫").tap()
        XCTAssertEqual(field.value as? String,"因为","First delete dismisses suggestions, preserving committed text")
        Thread.sleep(forTimeInterval:0.5)
        XCTAssertFalse(strip.cells.firstMatch.exists,"Late ranking cannot restore dismissed suggestions")
        app.inputItem("key-⌫").tap()
        XCTAssertEqual(field.value as? String,"因","Second delete edits the host exactly once")
        Thread.sleep(forTimeInterval:0.75)
        XCTAssertFalse(strip.cells.firstMatch.exists,"Host/context revision changes after real deletion must not restart predictions")
        app.inputItem("key-⌫").press(forDuration:0.65)
        Thread.sleep(forTimeInterval:0.5)
        XCTAssertFalse(strip.cells.firstMatch.exists,"Hold/release must keep automatic suggestions suppressed")
        for letter in "yinwei" {app.inputItem("key-"+String(letter)).tap()}
        XCTAssertTrue(app.collectionViews["candidate-strip"].cells["key-因为"].waitForExistence(timeout:5),"New typed characters re-enable normal primary candidates")
    }
    func testRepeatedExpandCollapseKeepsKeyboardAndControlFramesFixed() {
        continueAfterFailure=false
        let app=XCUIApplication();app.launch()
        exerciseSystemKeyboard(fullAccessEnabled:true,verifySnapshot:false,chineseLayout:"nine",freshHost:true)
        clearSyntheticField(app)
        for digit in "5468426" {app.inputItem("nine-"+String(digit)).tap()}
        let initial=app.inputItem("expand-candidates").frame
        let body=app.inputItem("keyboard-body").frame
        for _ in 0..<10 {
            app.inputItem("expand-candidates").coordinate(withNormalizedOffset:CGVector(dx:0.95,dy:0.8)).tap()
            let collapse=app.inputItem("collapse-candidates")
            XCTAssertTrue(collapse.exists);XCTAssertEqual(collapse.frame,initial)
            collapse.coordinate(withNormalizedOffset:CGVector(dx:0.95,dy:0.8)).tap()
            XCTAssertEqual(app.inputItem("expand-candidates").frame,initial)
            XCTAssertEqual(app.inputItem("keyboard-body").frame,body)
        }
    }
    func testPublishedNineCandidatesStayInPlaceBeforeTouchAndExpansionEdgesWork() {
        continueAfterFailure=false
        let app=XCUIApplication();app.launch()
        exerciseSystemKeyboard(fullAccessEnabled:true,verifySnapshot:false,chineseLayout:"nine",freshHost:true)
        for code in ["5468","6364","6664","44444426"] {
            clearSyntheticField(app)
            for digit in code {app.inputItem("nine-"+String(digit)).tap()}
            let strip=app.collectionViews["candidate-strip"]
            XCTAssertTrue(strip.cells.firstMatch.waitForExistence(timeout:5))
            let first=Array(strip.cells.allElementsBoundByIndex.prefix(6)).map(\.identifier)
            XCTAssertFalse(first.isEmpty)
            // No touch-down freeze: the user is only reading and aiming.
            for _ in 0..<10 {
                Thread.sleep(forTimeInterval:0.25)
                XCTAssertEqual(Array(strip.cells.allElementsBoundByIndex.prefix(first.count)).map(\.identifier),first)
            }
            let expand=app.inputItem("expand-candidates")
            XCTAssertGreaterThanOrEqual(expand.frame.width,56);XCTAssertGreaterThanOrEqual(expand.frame.height,44)
            expand.coordinate(withNormalizedOffset:CGVector(dx:0.95,dy:0.2)).tap()
            XCTAssertTrue(app.collectionViews["candidate-list"].waitForExistence(timeout:3))
            let collapse=app.inputItem("collapse-candidates")
            collapse.coordinate(withNormalizedOffset:CGVector(dx:0.95,dy:0.2)).tap()
            XCTAssertFalse(app.collectionViews["candidate-list"].isHittable)
        }
    }
    func testCommonExpressionRankingInNineAndPinyin26() {
        continueAfterFailure=false
        let app=XCUIApplication();app.launch()
        exerciseSystemKeyboard(fullAccessEnabled:false,verifySnapshot:false,chineseLayout:"nine",freshHost:true)
        clearSyntheticField(app)
        for d in "3689426" {app.inputItem("nine-"+String(d)).tap()}
        // This code also spells dou zhao (都找). Lock the requested reading
        // before comparing homophones; raw T9 ambiguity is not a rank failure.
        app.inputItem("pinyin-dou").tap()
        XCTAssertTrue(app.inputItem("pinyin-xian").waitForExistence(timeout:5));app.inputItem("pinyin-xian").tap()
        XCTAssertEqual(app.collectionViews["candidate-strip"].cells.firstMatch.identifier,"key-都先")
        app.inputItem("key-都先").tap();XCTAssertEqual(app.inputItem("sample-text").value as? String,"都先")
        clearSyntheticField(app)
        app.inputItem("key-中").press(forDuration:0.8);app.inputItem("布局与显示").tap();app.inputItem("中文26键").tap()
        for c in "douxian" {app.inputItem("key-"+String(c)).tap()}
        XCTAssertEqual(app.collectionViews["candidate-strip"].cells.firstMatch.identifier,"key-都先")
        app.inputItem("expand-candidates").tap();let rare=app.collectionViews["candidate-list"].cells["key-窦宪"]
        XCTAssertTrue(rare.exists);rare.tap();XCTAssertEqual(app.inputItem("sample-text").value as? String,"窦宪")
    }
    func testStoreMaterialCapture() {
        continueAfterFailure=false
        XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication();app.launch()
        func capture(_ name:String) {
            let shot=XCTAttachment(screenshot:app.screenshot());shot.name="store-"+name;shot.lifetime = .keepAlways;add(shot)
        }
        exerciseSystemKeyboard(fullAccessEnabled:false,verifySnapshot:false,chineseLayout:"nine",freshHost:true)
        clearSyntheticField(app)
        for d in "64426" {app.inputItem("nine-"+String(d)).tap()}
        XCTAssertTrue(app.inputItem("key-你好").exists);capture("01-nine-pinyin")
        app.inputItem("expand-candidates").tap();capture("02-expanded-candidates")
        app.collectionViews["candidate-list"].cells["key-你好"].tap()
        XCTAssertEqual(app.inputItem("sample-text").value as? String,"你好")
        XCTAssertFalse(app.inputItem("reselect-recent-commit").exists)
        clearSyntheticField(app);app.inputItem("key-中").tap()
        for c in "aoole" {app.inputItem("key-"+String(c)).tap()}
        XCTAssertTrue(app.inputItem("key-apple").waitForExistence(timeout:5));capture("03-english-correction")
        app.inputItem("key-apple").tap();XCTAssertEqual(app.inputItem("sample-text").value as? String,"apple")
        clearSyntheticField(app);if app.inputItem("key-英").exists {app.inputItem("key-英").tap()};app.inputItem("key-123").tap()
        app.inputItem("number-1").tap();app.inputItem("symbol-.").tap();app.inputItem("number-4").tap()
        XCTAssertEqual(app.inputItem("sample-text").value as? String,"1.4");capture("04-numeric-symbols")
        app.inputItem("return-numbers").tap();clearSyntheticField(app)
        app.inputItem("key-符").tap();capture("05-symbol-categories")
        app.inputItem("return-symbols").tap();app.inputItem("dismiss-keyboard").tap()
        let settings=app.inputItem("键盘与词库");keyboardReveal(settings,in:app);settings.tap();capture("06-input-settings")
        back(app)
        let legal=app.inputItem("open-legal");keyboardReveal(legal,in:app);legal.tap()
        XCTAssertTrue(app.inputItem("privacy-policy-link").exists)
        app.inputItem("open-third-party-notices").tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","Third-party notices")).firstMatch.exists)
    }
    func testContextualSemanticRankingIn26AndNineKeysPreservesHostText() {
        let app=XCUIApplication();app.launchArguments=["--context-acceptance"];app.launch()
        for layout in ["pinyin26","nine"] {
            exerciseSystemKeyboard(fullAccessEnabled:false,verifySnapshot:false,chineseLayout:layout)
            // Settings can leave XCTest's host animation transaction pending on
            // iOS27. Start a fresh host document for each mode rather than carry
            // that activation state across two unrelated synthetic fixtures.
            app.terminate();app.launch()
            app.inputItem("clear-sample").tap();app.inputItem("seed-context").tap();app.inputItem("sample-text").tap()
            for key in layout=="nine" ? "9467464":"xinqing" {app.inputItem((layout=="nine" ? "nine-":"key-")+String(key)).tap()}
            let ready=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in
                guard let value=app.collectionViews["candidate-strip"].value as? String,let data=value.data(using:.utf8),let probe=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else{return false}
                return (probe["hostContext"] as? Bool)==true && (probe["beforeCount"] as? Int)==4 && (probe["available"] as? Bool)==true && (probe["semanticRevision"] as? Int)==(probe["revision"] as? Int)
            },object:nil)
            XCTAssertEqual(XCTWaiter.wait(for:[ready],timeout:15),.completed,layout)
            XCTAssertEqual(app.inputItem("sample-text").value as? String,"今天我的")
            let target=app.inputItem("key-心情")
            if !target.isHittable {app.inputItem("expand-candidates").tap()}
            XCTAssertTrue(target.waitForExistence(timeout:5));XCTAssertTrue(target.isHittable);target.tap()
            XCTAssertEqual(app.inputItem("sample-text").value as? String,"今天我的心情")
            let image=XCTAttachment(screenshot:app.screenshot());image.lifetime = .keepAlways;add(image)
        }
    }
    func testPermissionGuidanceAndActualKeyboardAccessStatus() {
        let app=XCUIApplication();app.launch()
        let help=app.inputItem("open-keyboard-permissions")
        keyboardReveal(help,in:app);XCTAssertTrue(help.waitForExistence(timeout:10));help.tap()
        XCTAssertTrue(app.navigationBars["键盘权限"].waitForExistence(timeout:5))
        XCTAssertTrue(app.inputItem("permission-open-settings").exists)
        back(app)
        exerciseSystemKeyboard(fullAccessEnabled:false,verifySnapshot:false,chineseLayout:"pinyin26")
        app.inputItem("clear-sample").tap();app.inputItem("sample-text").tap()
        app.inputItem("key-中").press(forDuration:0.8);app.inputItem("权限").tap()
        XCTAssertTrue(app.inputItem("完全访问未开启").waitForExistence(timeout:5))
        app.inputItem("权限说明").tap()
        XCTAssertTrue(app.inputItem("基础打字与本机纠错可用").waitForExistence(timeout:5))
        app.inputItem("返回键盘").tap()
        XCTAssertTrue(app.inputItem("key-n").waitForExistence(timeout:5))
        app.inputItem("key-n").tap();app.inputItem("key-i").tap();app.inputItem("key-h").tap();app.inputItem("key-a").tap();app.inputItem("key-o").tap()
        XCTAssertTrue(app.inputItem("key-你好").waitForExistence(timeout:8));app.inputItem("key-你好").tap()
        XCTAssertEqual(app.inputItem("sample-text").value as? String,"你好")
    }
    func testFullAccessStatusComesFromTheKeyboardAfterGrant() {
        let app=XCUIApplication();app.launch()
        exerciseSystemKeyboard(fullAccessEnabled:true,verifySnapshot:false,chineseLayout:"pinyin26")
        app.inputItem("clear-sample").tap();app.inputItem("sample-text").tap()
        app.inputItem("key-中").press(forDuration:0.8);app.inputItem("权限").tap()
        XCTAssertTrue(app.inputItem("完全访问已开启").waitForExistence(timeout:5))
        app.inputItem("权限说明").tap();app.inputItem("返回键盘").tap()
        for c in "nihao" {app.inputItem("key-"+String(c)).tap()}
        XCTAssertTrue(app.inputItem("key-你好").waitForExistence(timeout:8));app.inputItem("key-你好").tap()
        XCTAssertEqual(app.inputItem("sample-text").value as? String,"你好")
    }
    func testPinyinInitialsPrefixAndDoubleTranspositionInSystemKeyboard() {
        let app=XCUIApplication();app.launch()
        exerciseSystemKeyboard(fullAccessEnabled:false,verifySnapshot:false,chineseLayout:"pinyin26")
        for (raw,target) in [("csm","吃什么"),("shih","时候"),("linaxaing","联想")] {
            app.inputItem("clear-sample").tap();app.inputItem("sample-text").tap()
            for letter in raw {app.inputItem("key-"+String(letter)).tap()}
            let candidate=app.inputItem("key-"+target)
            XCTAssertTrue(candidate.waitForExistence(timeout:10),raw)
            if !candidate.isHittable {app.inputItem("expand-candidates").tap()}
            XCTAssertTrue(candidate.isHittable);candidate.tap()
            XCTAssertEqual(app.inputItem("sample-text").value as? String,target)
        }
    }
    func testWholePunctuationRailDragsFromGlyphsEdgesAndPinyinWithoutSelecting() {
        XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication();app.launch()
        app.inputItem("sample-text").tap()
        if !app.inputItem("nine-4").waitForExistence(timeout:3) {
            exerciseSystemKeyboard(fullAccessEnabled:false,verifySnapshot:false,chineseLayout:"nine")
        }
        compositionPosition("拼音在键盘内",in:app)
        app.inputItem("clear-sample").tap()
        let field=app.descendants(matching:.any).matching(identifier:"sample-text").firstMatch
        let rail=app.collectionViews["quick-symbols"]
        func offset(_ view:XCUIElement)->Int {
            let text=view.value as? String ?? "{}"
            let value=(try? JSONSerialization.jsonObject(with:Data(text.utf8))) as? [String:Any]
            return value?["offset"] as? Int ?? 0
        }
        func settled(_ view:XCUIElement) {
            let state=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in
                let text=view.value as? String ?? "{}"
                let value=(try? JSONSerialization.jsonObject(with:Data(text.utf8))) as? [String:Any]
                return value?["dragging"] as? Bool != true && value?["decelerating"] as? Bool != true
            },object:view)
            XCTAssertEqual(XCTWaiter.wait(for:[state],timeout:4),.completed,"Wait for the preceding independent trial's native inertia/bounce, not just the host app's idle state")
        }
        func drag(_ view:XCUIElement,x:Double,down:Bool=false) {
            settled(view)
            let from=view.coordinate(withNormalizedOffset:CGVector(dx:x,dy:down ? 0.15:0.85))
            let to=view.coordinate(withNormalizedOffset:CGVector(dx:x,dy:down ? 0.85:0.15))
            from.press(forDuration:0.01,thenDragTo:to)
            settled(view)
            print("RAIL_AFTER x=\(x) down=\(down) value=\(view.value ?? "nil")")
        }
        for x in [0.97,0.03,0.25,0.5,0.75] {
            let before=offset(rail)
            print("RAIL_DRAG fraction=\(x) frame=\(rail.frame) before=\(before)")
            drag(rail,x:x);XCTAssertGreaterThan(offset(rail),before+25,"Rail must scroll even at horizontal fraction \(x)")
            let moved=offset(rail);drag(rail,x:x,down:true);XCTAssertLessThan(offset(rail),moved-25)
            XCTAssertEqual(field.value as? String,"")
        }
        // A deliberate tap still inserts exactly the visible symbol.
        let symbol=rail.cells.allElementsBoundByIndex.first { $0.isHittable && $0.frame.minY>=rail.frame.minY && $0.frame.maxY<=rail.frame.maxY }!
        let value=symbol.label;symbol.tap();XCTAssertEqual(field.value as? String,value)
        app.inputItem("clear-sample").tap()
        for d in "744" { app.inputItem("nine-"+String(d)).tap() }
        let filter=app.collectionViews["pinyin-filter"],raw=app.inputItem("composition-preedit").value as? String
        XCTAssertTrue(filter.isHittable)
        let initial=offset(filter);drag(filter,x:0.5);XCTAssertGreaterThan(offset(filter),initial+20)
        XCTAssertEqual(app.inputItem("composition-preedit").value as? String,raw)
        XCTAssertEqual(field.value as? String,"")
        app.inputItem("clear-composition").tap();app.inputItem("key-符").tap()
        let categories=app.collectionViews["symbol-categories"],initialCategory=offset(categories)
        drag(categories,x:0.97);XCTAssertGreaterThan(offset(categories),initialCategory+20)
        XCTAssertEqual(field.value as? String,"")
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="whole-rail-native-scroll";shot.lifetime = .keepAlways;add(shot)
        app.inputItem("return-symbols").tap()
    }
    func testHeightPresetsLiveDragPersistenceAndMainAppPropagation() {
        XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication();app.launch()
        exerciseSystemKeyboard(fullAccessEnabled:false,verifySnapshot:false,chineseLayout:"nine")
        app.inputItem("clear-sample").tap()
        let key=app.inputItem("nine-2"),space=app.inputItem("key-空格")
        heightMenu("矮",in:app);let low=key.frame.height,lowFooter=space.frame.height
        heightMenu("中",in:app);let medium=key.frame.height
        XCTAssertGreaterThan(medium,low+8)
        heightMenu("高",in:app);let high=key.frame.height
        XCTAssertGreaterThan(high,medium+8);XCTAssertGreaterThan(space.frame.height,lowFooter+12)
        let highFrame=key.frame
        app.inputItem("nine-6").tap();app.inputItem("nine-4").tap();XCTAssertEqual(key.frame,highFrame)
        app.inputItem("clear-composition").tap()
        app.inputItem("key-123").tap();XCTAssertEqual(app.inputItem("number-2").frame,highFrame);app.inputItem("return-numbers").tap()
        app.inputItem("key-符").tap();app.inputItem("return-symbols").tap();XCTAssertEqual(key.frame,highFrame)
        heightMenu("拖动微调…",in:app)
        let slider=app.sliders["keyboard-height-slider"]
        XCTAssertTrue(slider.isHittable);slider.adjust(toNormalizedSliderPosition:0.45)
        let custom=key.frame.height;XCTAssertGreaterThan(custom,low);XCTAssertLessThan(custom,high)
        let handle=app.inputItem("drag-keyboard-height"),origin=handle.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5))
        origin.press(forDuration:0.05,thenDragTo:origin.withOffset(CGVector(dx:0,dy:-24)))
        XCTAssertGreaterThan(key.frame.height,custom+3)
        app.inputItem("finish-keyboard-height").tap();let saved=key.frame.height
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="adjusted-taller-keys";shot.lifetime = .keepAlways;add(shot)
        app.inputItem("dismiss-keyboard").tap()
        let field=app.descendants(matching:.any).matching(identifier:"sample-text").firstMatch;field.tap()
        XCTAssertEqual(key.frame.height,saved,accuracy:1)
        // Shared settings override a previous no-full-access local height.
        app.inputItem("dismiss-keyboard").tap();app.inputItem("键盘与词库").tap();keyboardReveal(app.inputItem("open-keyboard-height"),in:app);app.inputItem("open-keyboard-height").tap()
        app.buttons["矮"].tap();app.buttons["高"].tap()
        back(app);back(app);field.tap();XCTAssertEqual(key.frame.height,high,accuracy:1)
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in app.frame.width>app.frame.height && key.isHittable },object:app)
        XCTAssertEqual(XCTWaiter.wait(for:[landscape],timeout:8),.completed)
        XCTAssertGreaterThan(key.frame.height,20);XCTAssertLessThan(key.frame.height,high)
        XCTAssertTrue(space.isHittable)
        XCUIDevice.shared.orientation = .portrait
        heightMenu("中",in:app)
    }
    func testRepeatedRevealKeepsKeyFramesAndFreshDraftWhileLearningDefers() {
        XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication();app.launch()
        exerciseSystemKeyboard(fullAccessEnabled:false,verifySnapshot:false,chineseLayout:"nine")
        app.inputItem("clear-sample").tap()
        let field=app.descendants(matching:.any).matching(identifier:"sample-text").firstMatch
        let before=app.inputItem("nine-6").frame
        for _ in 0..<3 {
            app.inputItem("dismiss-keyboard").tap();field.tap()
            let six=app.inputItem("nine-6")
            XCTAssertTrue(six.waitForExistence(timeout:8));XCTAssertEqual(six.frame,before)
            for key in "6464" { app.inputItem("nine-"+String(key)).tap() }
            XCTAssertEqual(app.inputItem("composition-preedit").value as? String,"6464")
            XCTAssertEqual(field.value as? String,"")
            app.inputItem("clear-composition").tap()
        }
    }
    func testNumericPanelNeverBlocksDecimalsAndSymbolRailLearnsAcrossEntries() {
        let app=XCUIApplication();app.launch()
        exerciseSystemKeyboard(fullAccessEnabled:false,verifySnapshot:false,chineseLayout:"nine")
        let field=app.inputItem("sample-text")
        clearSyntheticField(app)
        let original=app.inputItem("nine-4").frame
        app.inputItem("key-123").tap()
        let rail=app.collectionViews["quick-symbols"]
        let dot=rail.cells["symbol-."],at=rail.cells["symbol-@"]
        XCTAssertTrue(dot.isHittable);XCTAssertTrue(at.isHittable)
        XCTAssertLessThanOrEqual(dot.frame.height,34)
        for raw in ["1.4","0.05","1.2.3"] {
            clearSyntheticField(app)
            if !app.inputItem("number-1").exists {app.inputItem("key-123").tap()}
            for c in raw {
                if c=="." {dot.tap()}else{app.inputItem(c=="0" ? "key-0":"number-"+String(c)).tap()}
                XCTAssertFalse(app.inputItem("composition-preedit").exists && app.inputItem("composition-preedit").isHittable)
            }
            XCTAssertEqual(field.value as? String,raw)
            XCTAssertTrue(app.inputItem("number-4").isHittable)
        }
        clearSyntheticField(app)
        if !app.inputItem("number-1").exists {app.inputItem("key-123").tap()}
        for _ in 0..<12 {at.tap()}
        app.inputItem("return-numbers").tap()
        XCTAssertEqual(app.inputItem("nine-4").frame,original)
        let learnedRail=app.collectionViews["quick-symbols"]
        let learned=learnedRail.cells["symbol-@"]
        XCTAssertTrue(learned.isHittable,"A frequent symbol must move into the visible rail, without erasing older higher-frequency symbols")
        XCTAssertLessThanOrEqual(learned.frame.maxY,learnedRail.frame.maxY)
        clearSyntheticField(app)
        for c in "64426" {app.inputItem("nine-"+String(c)).tap()}
        let pendingWord=app.collectionViews["candidate-strip"].cells.firstMatch.label
        XCTAssertFalse(pendingWord.isEmpty)
        app.inputItem("key-123").tap()
        XCTAssertFalse(app.inputItem("composition-preedit").exists && app.inputItem("composition-preedit").isHittable)
        app.inputItem("number-1").tap();app.collectionViews["quick-symbols"].cells["symbol-."].tap();app.inputItem("number-4").tap()
        XCTAssertEqual(field.value as? String,pendingWord+"1.4")
        let image=XCTAttachment(screenshot:app.screenshot());image.name="compact-adaptive-symbols-and-literal-decimal";image.lifetime = .keepAlways;add(image)
    }
    func testEnglishTypoCandidatesAreReadableAndInlineDraftHasNoInsertedSpaces() {
        let app=XCUIApplication();app.launch()
        exerciseSystemKeyboard(fullAccessEnabled:false,verifySnapshot:false,chineseLayout:"letters")
        let field=app.inputItem("sample-text")
        clearSyntheticField(app);compositionPosition("拼音在文本框内",in:app)
        var raw=""
        for letter in "apple" {
            raw.append(letter);app.inputItem("key-"+String(letter)).tap()
            XCTAssertEqual(field.value as? String,raw)
        }
        let choice=app.inputItem("key-apple");XCTAssertTrue(choice.waitForExistence(timeout:8))
        XCTAssertGreaterThanOrEqual(choice.frame.width,65);choice.tap();XCTAssertEqual(field.value as? String,"apple")
        clearSyntheticField(app);app.inputItem("key-中").tap()
        for input in ["aoole","applr","aplpe","aple","appple"] {
            clearSyntheticField(app)
            if app.inputItem("key-中").exists {app.inputItem("key-中").tap()}
            for c in input {app.inputItem("key-"+String(c)).tap()}
            XCTAssertEqual(field.value as? String,input)
            let apple=app.inputItem("key-apple");XCTAssertTrue(apple.waitForExistence(timeout:8));XCTAssertTrue(apple.isHittable)
            let image=XCTAttachment(screenshot:app.screenshot());image.name="english-neighbor-"+input;image.lifetime = .keepAlways;add(image)
            apple.tap();XCTAssertEqual(field.value as? String,"apple")
        }
        if app.inputItem("key-英").exists {app.inputItem("key-英").tap()}
        for input in ["lue","lve"] {
            clearSyntheticField(app)
            if app.inputItem("key-英").exists {app.inputItem("key-英").tap()}
            for c in input {app.inputItem("key-"+String(c)).tap()}
            let word=app.inputItem("key-略");XCTAssertTrue(word.waitForExistence(timeout:8));word.tap();XCTAssertEqual(field.value as? String,"略")
        }
    }
    func testNumericHalfWidthSymbolsAndEnglishLanguageSlotStayAligned() {
        let app=XCUIApplication();app.launch()
        exerciseSystemKeyboard(fullAccessEnabled:false,verifySnapshot:false,chineseLayout:"nine")
        app.inputItem("clear-sample").tap()
        let field=app.descendants(matching:.any).matching(identifier:"sample-text").firstMatch
        let language=app.inputItem("key-中").frame
        app.inputItem("key-123").tap()
        XCTAssertEqual(app.collectionViews["quick-symbols"].cells.firstMatch.label,".")
        XCTAssertFalse(app.inputItem("symbol-，").exists)
        app.inputItem("number-1").tap();app.inputItem("symbol-.").tap();app.inputItem("number-5").tap()
        XCTAssertEqual(field.value as? String,"1.5")
        app.inputItem("return-numbers").tap();app.inputItem("key-中").tap()
        XCTAssertTrue(app.inputItem("key-q").isHittable)
        let english=app.inputItem("key-英").frame,clear=app.inputItem("clear-composition").frame,space=app.inputItem("key-空格").frame
        XCTAssertEqual(english.minX,language.minX,accuracy:1);XCTAssertEqual(english.width,language.width,accuracy:1)
        XCTAssertLessThanOrEqual(clear.maxX,space.minX);XCTAssertGreaterThanOrEqual(english.minX,space.maxX)
        XCTAssertLessThan(app.inputItem("key-123").frame.maxX,clear.minX)
        app.inputItem("clear-composition").tap();XCTAssertEqual(field.value as? String,"1.5")
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="english-language-slot-and-number-clear";shot.lifetime = .keepAlways;add(shot)
        app.inputItem("key-英").tap();XCTAssertTrue(app.inputItem("nine-2").isHittable)
    }
    func testCommonSymbolsPromoteExplicitUsageOnNextEntry() {
        let app=XCUIApplication();app.launch()
        exerciseSystemKeyboard(fullAccessEnabled:false,verifySnapshot:false,chineseLayout:"nine")
        app.inputItem("clear-sample").tap();app.inputItem("key-符").tap()
        tapSymbolCategory("english",in:app)
        for _ in 0..<8 { app.inputItem("symbol-!").tap() }
        tapSymbolCategory("common",in:app)
        let first=app.collectionViews["symbol-items"].cells.firstMatch
        let promoted=XCTNSPredicateExpectation(predicate:NSPredicate(format:"identifier == 'symbol-!'"),object:first)
        XCTAssertEqual(XCTWaiter.wait(for:[promoted],timeout:5),.completed)
        app.inputItem("symbol-!").tap();XCTAssertEqual(first.identifier,"symbol-!")
        app.inputItem("return-symbols").tap();app.inputItem("key-符").tap()
        XCTAssertEqual(app.collectionViews["symbol-items"].cells.firstMatch.identifier,"symbol-!")
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="adaptive-common-symbols";shot.lifetime = .keepAlways;add(shot)
        app.inputItem("return-symbols").tap()
    }
    func testSharedTextDeniedReturnsWithoutMovingKeys() {
        let app=XCUIApplication();app.launch()
        exerciseSystemKeyboard(fullAccessEnabled:false,verifySnapshot:false,chineseLayout:"nine")
        clearSyntheticField(app)
        let toolbar=XCTAttachment(screenshot:app.screenshot());toolbar.name="plain-toolbar-icons";toolbar.lifetime = .keepAlways;add(toolbar)
        let frame=app.inputItem("nine-2").frame
        app.inputItem("open-shared-text").tap()
        XCTAssertTrue(app.tables["shared-text-list"].waitForExistence(timeout:5))
        XCTAssertTrue(app.staticTexts["shared-text-status"].label.contains("完全访问"))
        XCTAssertFalse(app.inputItem("nine-2").isHittable);XCTAssertFalse(app.inputItem("key-符").isHittable)
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="native-keyboard-sharing-permission";shot.lifetime = .keepAlways;add(shot)
        app.inputItem("close-shared-text").tap();XCTAssertEqual(app.inputItem("nine-2").frame,frame)
        app.inputItem("nine-6").tap();app.inputItem("nine-4").tap()
        XCTAssertEqual(app.inputItem("composition-preedit").value as? String,"64")
        XCTAssertFalse(app.inputItem("open-shared-text").isHittable)
        app.inputItem("clear-composition").tap()
    }
    func testColdNineCoordinatesStayFixedAndAlternating64DoesNotSelectSyllableBreak() {
        XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication();app.launch()
        exerciseSystemKeyboard(fullAccessEnabled:false,verifySnapshot:false,chineseLayout:"nine")
        app.inputItem("clear-sample").tap();app.inputItem("dismiss-keyboard").tap()
        let field=app.descendants(matching:.any).matching(identifier:"sample-text").firstMatch;field.tap()
        XCTAssertTrue(app.inputItem("keyboard-settings").isHittable,"Start from the empty toolbar, not existing continuation candidates")
        let six=app.inputItem("nine-6"),four=app.inputItem("nine-4"),separator=app.inputItem("nine-1")
        let first=[six.frame,four.frame,separator.frame]
        let p6=six.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)),p4=four.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5))
        var expected=""
        for _ in 0..<8 {
            p6.tap();expected += "6"
            XCTAssertEqual(six.frame,first[0]);XCTAssertEqual(four.frame,first[1]);XCTAssertEqual(separator.frame,first[2])
            p4.tap();expected += "4"
            XCTAssertEqual(app.inputItem("composition-preedit").value as? String,expected)
        }
        // Repeat after clearing, then compare inline composition with identical
        // physical key coordinates. Space/rail gestures keep their release action.
        app.inputItem("clear-composition").tap();compositionPosition("拼音在文本框内",in:app)
        XCTAssertEqual(six.frame,first[0]);XCTAssertEqual(four.frame,first[1])
        p6.tap();p4.tap();XCTAssertEqual(app.inputItem("clear-composition").value as? String,"64")
        app.inputItem("clear-composition").tap();compositionPosition("拼音在键盘内",in:app)
        app.inputItem("key-123").tap();app.inputItem("return-numbers").tap()
        XCTAssertEqual(app.inputItem("key-空格").label,"空格")
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="native-background-cold-keys";shot.lifetime = .keepAlways;add(shot)
    }
    func testDeletingAndRetypingHomophonePromotesNewConfirmedWord() {
        let app=XCUIApplication();app.launch()
        exerciseSystemKeyboard(fullAccessEnabled:true,verifySnapshot:false,chineseLayout:"nine")
        app.inputItem("clear-sample").tap()
        let field=app.descendants(matching:.any).matching(identifier:"sample-text").firstMatch
        for d in "64426" { app.inputItem("nine-"+String(d)).tap() }
        app.inputItem("expand-candidates").tap();app.collectionViews["candidate-list"].cells["key-拟好"].tap()
        XCTAssertEqual(field.value as? String,"拟好")
        app.inputItem("key-⌫").tap();app.inputItem("key-⌫").tap();XCTAssertEqual(field.value as? String,"")
        for d in "64426" { app.inputItem("nine-"+String(d)).tap() }
        app.inputItem("expand-candidates").tap()
        let list=app.collectionViews["candidate-list"],correct=list.cells["key-你好"],rejected=list.cells["key-拟好"]
        XCTAssertTrue(correct.isHittable);XCTAssertTrue(rejected.exists)
        XCTAssertTrue(correct.frame.minY<rejected.frame.minY || (correct.frame.minY==rejected.frame.minY && correct.frame.minX<rejected.frame.minX))
        correct.tap();XCTAssertEqual(field.value as? String,"你好")
        app.inputItem("clear-sample").tap()
        for d in "64426" { app.inputItem("nine-"+String(d)).tap() }
        app.inputItem("expand-candidates").tap()
        XCTAssertTrue(correct.frame.minY<rejected.frame.minY || (correct.frame.minY==rejected.frame.minY && correct.frame.minX<rejected.frame.minX))
        correct.tap();XCTAssertEqual(field.value as? String,"你好")
    }
    func testLongPersonalCandidateOwnsItsRowAndWrapsWithoutOverlappingShortWords() {
        let app=XCUIApplication();app.launch()
        exerciseSystemKeyboard(fullAccessEnabled:true,verifySnapshot:false,chineseLayout:"nine")
        let text="This synthetic candidate is deliberately long enough to wrap across several lines and remain completely readable in the expanded candidate list."
        app.inputItem("clear-sample").tap();app.inputItem("dismiss-keyboard").tap();app.inputItem("键盘与词库").tap();keyboardReveal(app.inputItem("open-personal-lexicon"),in:app);app.inputItem("open-personal-lexicon").tap()
        let existing=app.inputItem("personal-entry-zzqa")
        if existing.exists { existing.swipeLeft();app.buttons.matching(NSPredicate(format:"label == 'Delete' OR label == '删除'")).firstMatch.tap() }
        app.inputItem("add-personal-phrase").tap()
        let field=app.textFields["personal-text"],content=field.exists ? field:app.textViews["personal-text"]
        content.tap();content.typeText(text)
        let trigger=app.textFields["personal-trigger"];trigger.tap();trigger.typeText("zzqa")
        app.inputItem("save-personal-entry").tap();XCTAssertTrue(existing.waitForExistence(timeout:5))
        back(app);back(app)
        let sample=app.descendants(matching:.any).matching(identifier:"sample-text").firstMatch;sample.tap()
        for d in "9972" { app.inputItem("nine-"+String(d)).tap() }
        let preview=app.collectionViews["candidate-strip"].cells.matching(NSPredicate(format:"label == %@",text)).firstMatch
        XCTAssertLessThan(preview.frame.width,app.collectionViews["candidate-strip"].frame.width)
        app.inputItem("expand-candidates").tap()
        let list=app.collectionViews["candidate-list"],long=list.cells.matching(NSPredicate(format:"label == %@",text)).firstMatch
        XCTAssertEqual(long.label,text);XCTAssertGreaterThan(long.frame.height,44);XCTAssertGreaterThan(long.frame.width,list.frame.width*0.8)
        for cell in list.cells.allElementsBoundByIndex where cell.identifier != long.identifier && cell.isHittable { XCTAssertFalse(cell.frame.intersects(long.frame),"Long phrases must not share vertical space with another candidate") }
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="aligned-long-candidates";shot.lifetime = .keepAlways;add(shot)
        long.tap();XCTAssertEqual(sample.value as? String,text)
        app.inputItem("dismiss-keyboard").tap();app.inputItem("键盘与词库").tap();keyboardReveal(app.inputItem("open-personal-lexicon"),in:app);app.inputItem("open-personal-lexicon").tap()
        existing.swipeLeft();app.buttons.matching(NSPredicate(format:"label == 'Delete' OR label == '删除'")).firstMatch.tap();XCTAssertFalse(existing.exists)
    }
    func testOSSupplementaryTextReplacementUsesNineCodeAndCanBeDisabled() {
        let app=XCUIApplication();app.launch()
        exerciseSystemKeyboard(fullAccessEnabled:false,verifySnapshot:false,chineseLayout:"nine")
        app.inputItem("clear-sample").tap();app.inputItem("dismiss-keyboard").tap()
        let settings=XCUIApplication(bundleIdentifier:"com.apple.Preferences");settings.launch()
        keyboardCell(settings,"identifier == 'General' OR label == 'General' OR label == '通用'").tap()
        keyboardCell(settings,"label == 'Keyboard' OR label == '键盘'").tap()
        keyboardCell(settings,"identifier == 'USER_DICTIONARY' OR label == 'Text Replacement' OR label == '文本替换' OR label == '自定短语' OR label == '自定义短语'").tap()
        settings.navigationBars.buttons.matching(NSPredicate(format:"label == 'Add' OR label == '添加' OR identifier == 'Add'")).firstMatch.tap()
        let fields=settings.textFields
        XCTAssertEqual(fields.count,2)
        fields.element(boundBy:0).tap();fields.element(boundBy:0).typeText("synthetic os phrase")
        fields.element(boundBy:1).tap();fields.element(boundBy:1).typeText("zzqa")
        settings.navigationBars.buttons.matching(NSPredicate(format:"label == 'Save' OR label == '存储' OR label == '保存'")).firstMatch.tap()
        app.activate()
        let field=app.descendants(matching:.any).matching(identifier:"sample-text").firstMatch;field.tap()
        // Explicit refresh includes the OS supplement snapshot, with no full access.
        app.inputItem("key-中").press(forDuration:0.8);app.inputItem("词库与联想").tap();app.inputItem("刷新词库").tap()
        let refreshed=XCTNSPredicateExpectation(predicate:NSPredicate(format:"label == %@","词库已更新"),object:app.staticTexts["learning-status"])
        XCTAssertEqual(XCTWaiter.wait(for:[refreshed],timeout:8),.completed)
        for d in "9972" { app.inputItem("nine-"+String(d)).tap() }
        let phrase=app.inputItem("key-synthetic os phrase")
        XCTAssertTrue(phrase.waitForExistence(timeout:8));phrase.tap();XCTAssertEqual(field.value as? String,"synthetic os phrase")
        app.inputItem("dismiss-keyboard").tap();app.inputItem("键盘与词库").tap()
        let toggle=app.switches["system-lexicon-setting"],control=toggle.switches.firstMatch
        if toggle.value as? String=="1" { if control.exists { control.tap() } else { toggle.tap() } }
        back(app);field.tap()
        for d in "9972" { app.inputItem("nine-"+String(d)).tap() }
        XCTAssertFalse(phrase.exists);app.inputItem("clear-composition").tap()
        app.inputItem("dismiss-keyboard").tap();app.inputItem("键盘与词库").tap()
        let on=app.switches["system-lexicon-setting"],inner=on.switches.firstMatch
        if on.value as? String=="0" { if inner.exists { inner.tap() } else { on.tap() } }
        back(app)
        settings.activate()
        let row=settings.cells.containing(.staticText,identifier:"synthetic os phrase").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout:5));row.swipeLeft()
        settings.buttons.matching(NSPredicate(format:"label == 'Delete' OR label == '删除'")).firstMatch.tap()
        XCTAssertFalse(row.exists)
    }
    func testCommitHasNoReselectEntryInNineAndPinyin26() {
        let app=XCUIApplication();app.launch()
        exerciseSystemKeyboard(fullAccessEnabled:false,verifySnapshot:false,chineseLayout:"nine")
        clearSyntheticField(app)
        let field=app.inputItem("sample-text")
        for d in "64426" { app.inputItem("nine-"+String(d)).tap() }
        app.inputItem("key-你好").tap();XCTAssertEqual(field.value as? String,"你好")
        XCTAssertFalse(app.inputItem("reselect-recent-commit").exists)
        let nine=XCTAttachment(screenshot:app.screenshot());nine.name="nine-commit-without-reselect";nine.lifetime = .keepAlways;add(nine)
        app.inputItem("symbol-，").tap();XCTAssertEqual(field.value as? String,"你好，")
        app.inputItem("key-中").press(forDuration:0.8);app.inputItem("布局与显示").tap();app.inputItem("中文26键").tap()
        compositionPosition("拼音在文本框内",in:app)
        for c in "xiexie" { app.inputItem("key-"+String(c)).tap() }
        app.inputItem("key-谢谢").tap();XCTAssertEqual(field.value as? String,"你好，谢谢")
        XCTAssertFalse(app.inputItem("reselect-recent-commit").exists)
        let letters=XCTAttachment(screenshot:app.screenshot());letters.name="pinyin26-commit-without-reselect";letters.lifetime = .keepAlways;add(letters)
        compositionPosition("拼音在键盘内",in:app)
    }
    func testSystemSizePortraitLandscapeAndExpandedCandidates() {
        XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication();app.launch()
        exerciseSystemKeyboard(fullAccessEnabled:false,verifySnapshot:false,chineseLayout:"nine")
        app.inputItem("clear-sample").tap()
        compositionPosition("拼音在键盘内",in:app)
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let key=app.inputItem("nine-2"),space=app.inputItem("key-空格")
        let ready=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in key.isHittable && space.isHittable && app.frame.height>app.frame.width },object:app)
        XCTAssertEqual(XCTWaiter.wait(for:[ready],timeout:8),.completed)
        let portraitKey=key.frame,portraitSpace=space.frame
        for d in "64426" { app.inputItem("nine-"+String(d)).tap() }
        let preedit=app.inputItem("composition-preedit")
        XCTAssertTrue(preedit.isHittable)
        XCTAssertGreaterThan(key.frame.height,24)
        XCTAssertLessThanOrEqual(app.collectionViews["candidate-strip"].frame.maxY,key.frame.minY+1)
        let metrics=XCTAttachment(string:"portraitKey=\(portraitKey); pendingKey=\(key.frame); preedit=\(preedit.frame); footer=\(space.frame)")
        metrics.name="system-layout-metrics";metrics.lifetime = .keepAlways;add(metrics)
        XCTAssertEqual(space.frame.minY,portraitSpace.minY,accuracy:1)
        app.inputItem("expand-candidates").tap()
        let list=app.collectionViews["candidate-list"];XCTAssertTrue(list.isHittable)
        XCTAssertGreaterThan(list.frame.height,120)
        let expandedShot=XCTAttachment(screenshot:app.screenshot());expandedShot.name="expanded-system-size";expandedShot.lifetime = .keepAlways;add(expandedShot)
        list.swipeUp();XCTAssertTrue(app.inputItem("collapse-candidates").exists);app.inputItem("collapse-candidates").tap()
        app.inputItem("clear-composition").tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in app.frame.width>app.frame.height && key.isHittable },object:app)
        XCTAssertEqual(XCTWaiter.wait(for:[landscape],timeout:8),.completed)
        XCTAssertTrue(space.isHittable);XCTAssertGreaterThan(key.frame.width,portraitKey.width)
        XCTAssertLessThanOrEqual(key.frame.height,portraitKey.height+1)
        app.inputItem("key-123").tap();XCTAssertTrue(app.inputItem("number-9").isHittable)
        app.inputItem("key-符").tap();let symbols=app.collectionViews["symbol-items"]
        XCTAssertTrue(symbols.isHittable);symbols.swipeUp()
        let shot=XCTAttachment(screenshot:app.screenshot());shot.lifetime = .keepAlways;add(shot)
        app.inputItem("return-symbols").tap();app.inputItem("return-numbers").tap()
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(key.waitForExistence(timeout:5))
    }
    func testPinyin26MissingLetterRecoversWholePhrase() {
        let app=XCUIApplication();app.launch()
        exerciseSystemKeyboard(fullAccessEnabled:false,verifySnapshot:false,chineseLayout:"pinyin26")
        app.inputItem("clear-sample").tap()
        let field=app.descendants(matching:.any).matching(identifier:"sample-text").firstMatch
        for letter in "shshenme" {app.inputItem("key-"+String(letter)).tap()}
        let recovered=app.inputItem("key-是什么")
        XCTAssertTrue(recovered.waitForExistence(timeout:5))
        recovered.tap();XCTAssertEqual(field.value as? String,"是什么")
        for letter in "shishenme" {app.inputItem("key-"+String(letter)).tap()}
        app.inputItem("key-是什么").tap();XCTAssertEqual(field.value as? String,"是什么是什么")
    }
    func testMixedPinyin26SelectedPrefixInlineAndMainSwitch() {
        let app=XCUIApplication();app.launch()
        exerciseSystemKeyboard(fullAccessEnabled:true,verifySnapshot:false,chineseLayout:"pinyin26")
        app.inputItem("clear-sample").tap();sharedMixed(true,in:app)
        let field=app.descendants(matching:.any).matching(identifier:"sample-text").firstMatch
        compositionPosition("拼音在文本框内",in:app)
        for letter in "nihaoapi" { app.inputItem("key-"+String(letter)).tap() }
        app.inputItem("expand-candidates").tap()
        app.collectionViews["candidate-list"].cells["key-你好"].tap()
        XCTAssertTrue(app.inputItem("collapse-candidates").exists)
        app.inputItem("key-API").tap()
        XCTAssertEqual(field.value as? String,"你好API");XCTAssertTrue(app.inputItem("key-中").isHittable)
        XCTAssertFalse(app.inputItem("collapse-candidates").exists)
        for letter in "xiexie" { app.inputItem("key-"+String(letter)).tap() };app.inputItem("key-谢谢").tap()
        for letter in "review" { app.inputItem("key-"+String(letter)).tap() }
        XCTAssertTrue((field.value as? String ?? "").hasSuffix("review"))
        app.inputItem("key-review").tap();XCTAssertEqual(field.value as? String,"你好API谢谢review")
        // Not in our small vocabulary: this exercises the actual OS dictionary.
        for letter in "strawberry" { app.inputItem("key-"+String(letter)).tap() }
        app.inputItem("key-strawberry").tap();XCTAssertEqual(field.value as? String,"你好API谢谢reviewstrawberry")
        sharedMixed(false,in:app)
        for letter in "review" { app.inputItem("key-"+String(letter)).tap() }
        XCTAssertFalse(app.inputItem("key-review").exists)
        app.inputItem("clear-composition").tap();sharedMixed(true,in:app)
        compositionPosition("拼音在键盘内",in:app)
    }
    func testMixedNineLocalSwitchAndExplicitPinyinWins() {
        let app=XCUIApplication();app.launch()
        exerciseSystemKeyboard(fullAccessEnabled:false,verifySnapshot:false,chineseLayout:"nine")
        app.inputItem("clear-sample").tap();sharedMixed(true,in:app)
        let field=app.descendants(matching:.any).matching(identifier:"sample-text").firstMatch
        for digit in "274" { app.inputItem("nine-"+String(digit)).tap() }
        XCTAssertNotEqual(app.collectionViews["candidate-strip"].cells.firstMatch.label,"API")
        let visibleAPI=app.collectionViews["candidate-strip"].cells["key-API"]
        let allAPI=app.descendants(matching:.any).matching(identifier:"key-API").allElementsBoundByIndex
        print("API_GEOMETRY visible=\(visibleAPI.frame) matches=\(allAPI.map{String(describing:$0.frame)+":"+String($0.isHittable)})")
        XCTAssertEqual(app.inputItem("key-API").frame,visibleAPI.frame,"Hidden expanded list must not shadow the visible candidate")
        app.inputItem("key-API").tap();XCTAssertEqual(field.value as? String,"API")
        for digit in "43556" { app.inputItem("nine-"+String(digit)).tap() }
        XCTAssertTrue(app.inputItem("key-hello").exists)
        app.inputItem("pinyin-he").tap();XCTAssertFalse(app.inputItem("key-hello").exists)
        app.inputItem("clear-composition").tap()
        for digit in "43556" { app.inputItem("nine-"+String(digit)).tap() }
        app.inputItem("key-hello").tap();XCTAssertEqual(field.value as? String,"APIhello")
        app.inputItem("key-中").press(forDuration:0.8);app.inputItem("词库与联想").tap();app.inputItem("中英混输").tap()
        app.inputItem("dismiss-keyboard").tap();field.tap()
        app.inputItem("clear-sample").tap();field.tap()
        for digit in "274" { app.inputItem("nine-"+String(digit)).tap() }
        XCTAssertFalse(app.inputItem("key-API").exists)
        app.inputItem("clear-composition").tap()
        app.inputItem("key-中").press(forDuration:0.8);app.inputItem("词库与联想").tap();app.inputItem("中英混输").tap()
        for digit in "274" { app.inputItem("nine-"+String(digit)).tap() }
        app.inputItem("key-API").tap();XCTAssertEqual(field.value as? String,"API")
        XCTAssertTrue(app.inputItem("key-中").isHittable)
    }
    func testPersonalWordSettingsToPinyin26Keyboard() {
        let app=XCUIApplication();app.launch()
        exerciseSystemKeyboard(fullAccessEnabled:true,verifySnapshot:false,chineseLayout:"pinyin26")
        let field=app.descendants(matching:.any).matching(identifier:"sample-text").firstMatch
        app.inputItem("clear-sample").tap();app.inputItem("dismiss-keyboard").tap();app.inputItem("键盘与词库").tap();keyboardReveal(app.inputItem("open-personal-lexicon"),in:app);app.inputItem("open-personal-lexicon").tap()
        let existing=app.inputItem("personal-entry-he cheng ci")
        if existing.exists { existing.swipeLeft();app.buttons.matching(NSPredicate(format:"label == 'Delete' OR label == '删除'")).firstMatch.tap() }
        app.inputItem("add-personal-word").tap()
        let text=app.textFields["personal-text"],content=text.exists ? text:app.textViews["personal-text"]
        content.tap();content.typeText("synthetic term")
        let trigger=app.textFields["personal-trigger"];trigger.tap();trigger.typeText("he cheng ci")
        app.inputItem("save-personal-entry").tap();XCTAssertTrue(existing.waitForExistence(timeout:5))
        back(app);XCTAssertTrue(app.navigationBars["输入设置"].waitForExistence(timeout:5));back(app)
        XCTAssertTrue(field.waitForExistence(timeout:5));field.tap()
        for letter in "hechengci" { app.inputItem("key-"+String(letter)).tap() }
        let term=app.inputItem("key-synthetic term");XCTAssertTrue(term.waitForExistence(timeout:5));term.tap()
        XCTAssertEqual(field.value as? String,"synthetic term")
        app.inputItem("dismiss-keyboard").tap();app.inputItem("键盘与词库").tap();keyboardReveal(app.inputItem("open-personal-lexicon"),in:app);app.inputItem("open-personal-lexicon").tap()
        existing.swipeLeft();app.buttons.matching(NSPredicate(format:"label == 'Delete' OR label == '删除'")).firstMatch.tap()
        XCTAssertFalse(existing.exists)
    }
    func testPersonalEnglishPhraseTakesPriorityWithoutDuplicateCandidate() {
        let app=XCUIApplication();app.launch()
        exerciseSystemKeyboard(fullAccessEnabled:true,verifySnapshot:false,chineseLayout:"pinyin26")
        app.inputItem("clear-sample").tap();sharedMixed(true,in:app)
        let field=app.descendants(matching:.any).matching(identifier:"sample-text").firstMatch
        app.inputItem("dismiss-keyboard").tap();app.inputItem("键盘与词库").tap();keyboardReveal(app.inputItem("open-personal-lexicon"),in:app);app.inputItem("open-personal-lexicon").tap()
        let entry=app.inputItem("personal-entry-review")
        if entry.exists { entry.swipeLeft();app.buttons.matching(NSPredicate(format:"label == 'Delete' OR label == '删除'")).firstMatch.tap() }
        app.inputItem("add-personal-phrase").tap()
        let text=app.textFields["personal-text"],content=text.exists ? text:app.textViews["personal-text"]
        content.tap();content.typeText("review")
        let trigger=app.textFields["personal-trigger"];trigger.tap();trigger.typeText("review")
        app.inputItem("save-personal-entry").tap();XCTAssertTrue(entry.waitForExistence(timeout:5))
        back(app);XCTAssertTrue(app.navigationBars["输入设置"].waitForExistence(timeout:5));back(app);field.tap()
        for letter in "review" { app.inputItem("key-"+String(letter)).tap() }
        let candidates=app.collectionViews["candidate-strip"].cells.matching(identifier:"key-review")
        XCTAssertEqual(candidates.count,1);candidates.firstMatch.tap();XCTAssertEqual(field.value as? String,"review")
        app.inputItem("dismiss-keyboard").tap();app.inputItem("键盘与词库").tap();keyboardReveal(app.inputItem("open-personal-lexicon"),in:app);app.inputItem("open-personal-lexicon").tap()
        entry.swipeLeft();app.buttons.matching(NSPredicate(format:"label == 'Delete' OR label == '删除'")).firstMatch.tap()
        XCTAssertFalse(entry.exists)
    }
    func testPersonalPhraseSettingsToNineKeyboardAndDelete() {
        let app=XCUIApplication();app.launch()
        exerciseSystemKeyboard(fullAccessEnabled:true,verifySnapshot:false,chineseLayout:"nine")
        let field=app.descendants(matching:.any).matching(identifier:"sample-text").firstMatch
        app.inputItem("clear-sample").tap()
        app.inputItem("dismiss-keyboard").tap();app.inputItem("键盘与词库").tap()
        keyboardReveal(app.inputItem("open-personal-lexicon"),in:app);app.inputItem("open-personal-lexicon").tap()
        if app.inputItem("personal-entry-dz").exists {
            app.inputItem("personal-entry-dz").swipeLeft();app.buttons.matching(NSPredicate(format:"label == 'Delete' OR label == '删除'")).firstMatch.tap()
        }
        app.inputItem("add-personal-phrase").tap()
        let text=app.textFields["personal-text"]
        let content=text.exists ? text:app.textViews["personal-text"]
        content.tap();content.typeText("synthetic reply")
        let trigger=app.textFields["personal-trigger"];trigger.tap();trigger.typeText("dz")
        app.inputItem("save-personal-entry").tap()
        XCTAssertTrue(app.inputItem("personal-entry-dz").waitForExistence(timeout:5))
        let image=XCTAttachment(screenshot:app.screenshot());image.lifetime = .keepAlways;add(image)
        back(app);XCTAssertTrue(app.navigationBars["输入设置"].waitForExistence(timeout:5));back(app)
        XCTAssertTrue(field.waitForExistence(timeout:5));field.tap()
        for digit in "39" { app.inputItem("nine-"+String(digit)).tap() }
        let candidate=app.inputItem("key-synthetic reply")
        XCTAssertTrue(candidate.waitForExistence(timeout:5));candidate.tap()
        XCTAssertEqual(field.value as? String,"synthetic reply")
        app.inputItem("dismiss-keyboard").tap();app.inputItem("键盘与词库").tap();keyboardReveal(app.inputItem("open-personal-lexicon"),in:app);app.inputItem("open-personal-lexicon").tap()
        app.inputItem("personal-entry-dz").swipeLeft();app.buttons.matching(NSPredicate(format:"label == 'Delete' OR label == '删除'")).firstMatch.tap()
        XCTAssertFalse(app.inputItem("personal-entry-dz").exists)
        back(app);XCTAssertTrue(app.navigationBars["输入设置"].waitForExistence(timeout:5));back(app)
        XCTAssertTrue(field.waitForExistence(timeout:5));field.tap()
        for digit in "39" { app.inputItem("nine-"+String(digit)).tap() }
        XCTAssertFalse(app.inputItem("key-synthetic reply").exists)
        app.inputItem("clear-composition").tap()
    }
    func testInlineCompositionCancelCommitAndExpandedReturn() {
        let app=XCUIApplication();app.launch()
        exerciseSystemKeyboard(fullAccessEnabled:false,verifySnapshot:false,chineseLayout:"nine")
        let field=app.descendants(matching:.any).matching(identifier:"sample-text").firstMatch
        let original=field.value as? String ?? ""
        compositionPosition("拼音在文本框内",in:app)
        for digit in "64426" { app.inputItem("nine-"+String(digit)).tap() }
        let preview=XCTNSPredicateExpectation(predicate:NSPredicate(format:"value CONTAINS %@","ni hao"),object:field)
        XCTAssertEqual(XCTWaiter.wait(for:[preview],timeout:5),.completed)
        app.inputItem("clear-composition").tap();XCTAssertEqual(field.value as? String,original)
        for digit in "64426" { app.inputItem("nine-"+String(digit)).tap() }
        app.inputItem("expand-candidates").tap();app.inputItem("key-你好").tap()
        XCTAssertEqual(field.value as? String,original+"你好")
        XCTAssertTrue(app.inputItem("nine-2").isHittable)
        XCTAssertFalse(app.inputItem("collapse-candidates").exists)
        // The next round must be typeable without manually closing the grid.
        for digit in "64426" { app.inputItem("nine-"+String(digit)).tap() }
        app.inputItem("key-⌫").tap();XCTAssertTrue((field.value as? String ?? "").hasPrefix(original+"你好"))
        app.inputItem("clear-composition").tap();XCTAssertEqual(field.value as? String,original+"你好")
        compositionPosition("拼音在键盘内",in:app)
        for digit in "64426" { app.inputItem("nine-"+String(digit)).tap() }
        XCTAssertEqual(field.value as? String,original+"你好")
        app.inputItem("expand-candidates").tap();app.inputItem("key-你好").tap()
        XCTAssertEqual(field.value as? String,original+"你好你好")
        XCTAssertTrue(app.inputItem("nine-2").isHittable)
    }
    func testInlinePinyin26KeepsPartialSelectionExpanded() {
        let app=XCUIApplication();app.launch()
        exerciseSystemKeyboard(fullAccessEnabled:false,verifySnapshot:false,chineseLayout:"pinyin26")
        let field=app.descendants(matching:.any).matching(identifier:"sample-text").firstMatch
        let original=field.value as? String ?? ""
        compositionPosition("拼音在文本框内",in:app)
        for letter in "nihaoshijie" { app.inputItem("key-"+String(letter)).tap() }
        XCTAssertTrue((field.value as? String ?? "").contains("ni"))
        app.inputItem("expand-candidates").tap()
        let expanded=app.collectionViews["candidate-list"]
        expanded.cells["key-你好"].tap()
        print("SYNTHETIC_PARTIAL_GRID "+expanded.debugDescription)
        print("SYNTHETIC_PARTIAL_FIELD "+String(describing:field.value))
        let partialImage=XCTAttachment(screenshot:app.screenshot());partialImage.lifetime = .keepAlways;add(partialImage)
        XCTAssertTrue(app.inputItem("collapse-candidates").exists,"Partial selection still needs the candidate grid")
        expanded.cells["key-世界"].tap()
        XCTAssertEqual(field.value as? String,original+"你好世界")
        XCTAssertTrue(app.inputItem("key-n").isHittable)
        XCTAssertFalse(app.inputItem("collapse-candidates").exists)
        compositionPosition("拼音在键盘内",in:app)
    }
    func testMixedInitialsKeepHaoDeAndAllowPrefixSelectionThenEnglishCompletion() {
        let app=XCUIApplication();app.launch()
        exerciseSystemKeyboard(fullAccessEnabled:false,verifySnapshot:false,chineseLayout:"nine")
        let field=app.inputItem("sample-text")
        app.inputItem("clear-sample").tap();field.tap();compositionPosition("拼音在键盘内",in:app)
        for digit in "4444442633" {app.inputItem("nine-"+String(digit)).tap()}
        let whole=app.inputItem("key-哈哈哈哈哈好的")
        XCTAssertTrue(whole.waitForExistence(timeout:10));XCTAssertTrue(whole.isHittable)
        XCTAssertTrue(app.inputItem("composition-preedit").label.contains("hao de"))
        app.inputItem("expand-candidates").tap()
        let grid=app.collectionViews["candidate-list"],prefix=grid.cells["key-哈哈哈哈哈"]
        for _ in 0..<8 {if prefix.exists && prefix.isHittable{break};grid.swipeUp()}
        XCTAssertTrue(prefix.isHittable);prefix.tap()
        XCTAssertEqual(field.value as? String,"哈哈哈哈哈")
        let good=app.inputItem("key-好的");XCTAssertTrue(good.waitForExistence(timeout:8));good.tap()
        XCTAssertEqual(field.value as? String,"哈哈哈哈哈好的");XCTAssertFalse(app.inputItem("collapse-candidates").exists)
        let snapshot=XCTAttachment(screenshot:app.screenshot());snapshot.lifetime = .keepAlways;add(snapshot)
        app.inputItem("clear-sample").tap();field.tap();app.inputItem("key-中").tap()
        for letter in "eleph" {app.inputItem("key-"+String(letter)).tap()}
        let elephant=app.inputItem("key-elephant");XCTAssertTrue(elephant.waitForExistence(timeout:8));elephant.tap()
        XCTAssertEqual(field.value as? String,"elephant")
        app.inputItem("clear-sample").tap();field.tap()
        for letter in "wrold" {app.inputItem("key-"+String(letter)).tap()}
        XCTAssertEqual(field.value as? String,"wrold")
        let world=app.inputItem("key-world");XCTAssertTrue(world.waitForExistence(timeout:8));world.tap()
        XCTAssertEqual(field.value as? String,"world")
    }
    func testRepeatedNineInitialsStayReadableAndExpandInTheCandidateBar() {
        let app=XCUIApplication();app.launch()
        exerciseSystemKeyboard(fullAccessEnabled:false,verifySnapshot:false,chineseLayout:"nine")
        let field=app.inputItem("sample-text")
        app.inputItem("clear-sample").tap();field.tap()
        compositionPosition("拼音在文本框内",in:app)
        for _ in 0..<4 {app.inputItem("nine-4").tap()}
        let haha=app.inputItem("key-哈哈哈哈")
        XCTAssertTrue(haha.waitForExistence(timeout:10));XCTAssertTrue(haha.isHittable)
        XCTAssertEqual(field.value as? String,"h h h h")
        let expand=app.inputItem("expand-candidates"),strip=app.collectionViews["candidate-strip"]
        XCTAssertTrue(expand.isHittable);XCTAssertEqual(expand.frame.minY,strip.frame.minY,accuracy:1)
        XCTAssertEqual(expand.frame.height,strip.frame.height,accuracy:1)
        let before=XCTAttachment(screenshot:app.screenshot());before.lifetime = .keepAlways;add(before)
        expand.tap();XCTAssertTrue(app.inputItem("collapse-candidates").isHittable)
        XCTAssertFalse(app.inputItem("nine-4").isHittable)
        app.collectionViews["candidate-list"].cells["key-哈哈哈哈"].tap()
        XCTAssertEqual(field.value as? String,"哈哈哈哈")
        XCTAssertFalse(app.inputItem("collapse-candidates").exists);XCTAssertTrue(app.inputItem("nine-4").isHittable)
        app.inputItem("clear-sample").tap();field.tap()
        compositionPosition("拼音在键盘内",in:app)
        for _ in 0..<4 {app.inputItem("nine-4").tap()}
        app.inputItem("key-⌫").tap()
        XCTAssertTrue(app.inputItem("key-哈哈哈").waitForExistence(timeout:10))
        XCTAssertEqual(field.value as? String,"")
        XCTAssertEqual(app.inputItem("composition-preedit").label,"h h h")
        app.inputItem("key-哈哈哈").tap();XCTAssertEqual(field.value as? String,"哈哈哈")
    }
    func testMainSettingsCompositionPositionOverridesLocalMenuAcrossReload() {
        let app=XCUIApplication();app.launch()
        exerciseSystemKeyboard(fullAccessEnabled:true,verifySnapshot:false,chineseLayout:"nine")
        compositionPosition("拼音在键盘内",in:app)
        let field=app.descendants(matching:.any).matching(identifier:"sample-text").firstMatch
        let original=field.value as? String ?? ""
        app.inputItem("dismiss-keyboard").tap();app.inputItem("键盘与词库").tap()
        app.inputItem("composition-position-setting").tap();app.inputItem("文本框内").tap()
        app.navigationBars.buttons.firstMatch.tap();field.tap()
        for digit in "64426" { app.inputItem("nine-"+String(digit)).tap() }
        XCTAssertTrue((field.value as? String ?? "").contains("ni hao"))
        app.inputItem("clear-composition").tap();XCTAssertEqual(field.value as? String,original)
        app.inputItem("dismiss-keyboard").tap();app.inputItem("键盘与词库").tap()
        app.inputItem("composition-position-setting").tap();app.inputItem("键盘内").tap()
        app.navigationBars.buttons.firstMatch.tap();field.tap()
        for digit in "64426" { app.inputItem("nine-"+String(digit)).tap() }
        XCTAssertEqual(field.value as? String,original)
        app.inputItem("clear-composition").tap()
    }
    func testManualPinyinFilterKeepsAlternativeFouAfterQuan() {
        let app=XCUIApplication();app.launch()
        exerciseSystemKeyboard(fullAccessEnabled:false,verifySnapshot:false,chineseLayout:"nine")
        let field=app.descendants(matching:.any).matching(identifier:"sample-text").firstMatch
        let host=field.value as? String ?? ""
        for digit in "782636874472666" { app.inputItem("nine-"+String(digit)).tap() }
        app.inputItem("pinyin-quan").tap()
        XCTAssertTrue(app.inputItem("pinyin-dou").exists)
        let rail=app.collectionViews["pinyin-filter"]
        let fou=app.inputItem("pinyin-fou")
        // Native scrolling cells outside the viewport are not materialized in
        // accessibility. Bring the spelling into view before checking it.
        for _ in 0..<4 {if fou.exists && fou.isHittable {break};rail.swipeUp()}
        XCTAssertTrue(fou.exists,"Valid spellings must survive word prediction")
        fou.tap()
        XCTAssertTrue(app.staticTexts["composition-preedit"].label.hasPrefix("quan fou"))
        XCTAssertEqual(field.value as? String,host,"Manual filters must never commit host text")
        app.inputItem("key-⌫").tap()
        XCTAssertTrue(app.inputItem("pinyin-dou").exists)
        app.inputItem("pinyin-dou").tap()
        for reading in ["shi","pao","mo"] { app.inputItem("pinyin-"+reading).tap() }
        XCTAssertTrue(app.staticTexts["composition-preedit"].label.hasPrefix("quan dou shi pao mo"))
        XCTAssertEqual(field.value as? String,host)
        app.inputItem("clear-composition").tap()
    }
    func testControlOriginScrollingAndReadableNineModeSwitch() {
        let checker = UITextChecker(), word = "hel"
        let completions = checker.completions(forPartialWordRange: NSRange(location: 0, length: word.utf16.count), in: word, language: "en_US") ?? []
        print("ENGLISH_DIAG publicSystemDictionary prefix=hel suggestions=\(Array(completions.prefix(8)))")
        let app = XCUIApplication(); app.launch()
        exerciseSystemKeyboard(fullAccessEnabled: false, verifySnapshot: false, chineseLayout: "nine")
        let field = app.descendants(matching: .any).matching(identifier: "sample-text").firstMatch
        app.inputItem("key-符").tap()
        let symbols = app.collectionViews["symbol-items"]
        let first = app.inputItem("symbol-，")
        let before = first.frame.minY, hostBefore = field.value as? String ?? ""
        let button = app.inputItem("symbol-：")
        // Keep x fixed: a left-dominant diagonal is not a vertical scroll test.
        let column = (button.frame.midX - symbols.frame.minX) / symbols.frame.width
        let end = symbols.coordinate(withNormalizedOffset: CGVector(dx: column, dy: 0.05))
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.05, thenDragTo: end)
        print("SYMBOL_SCROLL_GEOMETRY before=\(before) collection=\(symbols.frame) state=\(symbols.value ?? "missing")")
        let afterButton = first.exists ? first.frame.minY : -1
        XCTAssertLessThan(afterButton, before - 20, "Dragging from a symbol button must scroll")
        let gutter = symbols.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.85))
        gutter.press(forDuration: 0.05, thenDragTo: symbols.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.05)))
        let afterGutter = first.exists ? first.frame.minY : -1
        let hostUnchanged = (field.value as? String ?? "") == hostBefore
        XCTAssertTrue(hostUnchanged, "Dragging must cancel symbol insertion")
        print("DRAG_DIAG symbols before=\(before) onButton=\(afterButton) onGutter=\(afterGutter) hostUnchanged=\(hostUnchanged)")
        let image = XCTAttachment(screenshot: app.screenshot()); image.lifetime = .keepAlways; add(image)
        app.inputItem("return-symbols").tap()
        app.inputItem("keyboard-settings").tap(); app.inputItem("布局与显示").tap();app.inputItem("中文26键").tap()
        for letter in "shi" { app.inputItem("key-" + String(letter)).tap() }
        app.inputItem("expand-candidates").tap()
        let candidates = app.collectionViews["candidate-list"]
        let point = CGPoint(x: candidates.frame.minX + candidates.frame.width * 0.375, y: candidates.frame.minY + candidates.frame.height * 0.72)
        guard let origin = candidates.cells.allElementsBoundByIndex.first(where: { $0.frame.contains(point) }) else { XCTFail("A visible candidate must cover the drag origin"); return }
        let top = candidates.cells.firstMatch
        let topID = top.identifier, topBefore = top.frame.minY
        origin.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.05, thenDragTo: candidates.coordinate(withNormalizedOffset: CGVector(dx: (origin.frame.midX - candidates.frame.minX) / candidates.frame.width, dy: 0.05)))
        let topAfter = candidates.cells[topID].exists ? candidates.cells[topID].frame.minY : -1
        let expanded = app.inputItem("collapse-candidates").exists
        XCTAssertLessThan(topAfter, topBefore - 20, "Dragging from a candidate button must scroll")
        XCTAssertTrue(expanded, "Dragging must cancel candidate choice")
        XCTAssertEqual(field.value as? String ?? "", hostBefore)
        print("DRAG_DIAG candidates onButton before=\(topBefore) after=\(topAfter) expanded=\(expanded)")
        if expanded { app.inputItem("collapse-candidates").tap() }; app.inputItem("clear-composition").tap()
        app.inputItem("keyboard-settings").tap(); app.inputItem("布局与显示").tap();app.inputItem("中文九宫格").tap()
        for digit in "64426" { app.inputItem("nine-" + String(digit)).tap() }
        let draftSpace = app.inputItem("key-空格")
        let beforeDrag = field.value as? String ?? ""
        draftSpace.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).press(forDuration: 0.6, thenDragTo: draftSpace.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)))
        XCTAssertEqual(field.value as? String ?? "", beforeDrag, "Moving composition cursor must not submit pinyin")
        XCTAssertTrue(app.inputItem("expand-candidates").exists)
        app.inputItem("clear-composition").tap()
        for digit in "64426" { app.inputItem("nine-" + String(digit)).tap() }
        let shown = app.staticTexts["composition-preedit"].label, beforeSwitch = field.value as? String ?? ""
        app.inputItem("key-中").tap()
        let afterSwitch = field.value as? String ?? ""
        XCTAssertEqual(String(afterSwitch.dropFirst(beforeSwitch.count)), shown.replacingOccurrences(of: " ", with: ""))
        XCTAssertFalse(afterSwitch.contains("64426"))
        print("MODE_DIAG displayed=\(shown) inserted=\(String(afterSwitch.dropFirst(beforeSwitch.count)))")
    }
    func testCandidatePinMenuEnglishCompletionAndSpaceCursor() {
        let app = XCUIApplication(); app.launch()
        exerciseSystemKeyboard(fullAccessEnabled: false, verifySnapshot: false)
        let field = app.descendants(matching: .any).matching(identifier: "sample-text").firstMatch
        for letter in "shi" { app.inputItem("key-" + String(letter)).tap() }
        let strip = app.collectionViews["candidate-strip"]
        let first = strip.cells.firstMatch, initialText = first.label
        // A horizontal drag beginning on a candidate also cancels its tap.
        let beforeX = first.frame.minX
        let viewport = strip.frame
        guard let origin = strip.cells.allElementsBoundByIndex.first(where: { let frame = $0.frame; return frame.midX > viewport.midX && frame.maxX <= viewport.maxX && frame.width > 20 && frame.contains(CGPoint(x: frame.midX, y: viewport.midY)) }) else { XCTFail("Visible horizontal candidate required"); return }
        origin.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.05, thenDragTo: strip.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)))
        XCTAssertTrue(app.inputItem("expand-candidates").exists)
        XCTAssertTrue(!strip.cells["key-" + initialText].exists || strip.cells["key-" + initialText].frame.minX < beforeX - 20)
        app.inputItem("expand-candidates").tap()
        let grid = app.collectionViews["candidate-list"]
        guard let target = grid.cells.allElementsBoundByIndex.first(where: { $0.frame.minY >= grid.frame.minY && $0.frame.maxY <= grid.frame.maxY && $0.isHittable && $0.label.count == 1 && (Int($0.value as? String ?? "") ?? 0) >= 8 }) else { XCTFail("Non-first candidate required"); return }
        let text = target.label
        target.press(forDuration: 0.9)
        let pin = app.inputItem("候选置顶")
        XCTAssertTrue(pin.waitForExistence(timeout: 5)); pin.tap()
        XCTAssertEqual(grid.cells.firstMatch.label, text)
        grid.cells.firstMatch.press(forDuration: 0.9)
        XCTAssertTrue(app.inputItem("取消置顶").waitForExistence(timeout: 5)); app.inputItem("取消置顶").tap()
        let restoreTarget = app.inputItem("key-" + text)
        restoreTarget.press(forDuration: 0.9)
        XCTAssertTrue(app.inputItem("恢复默认词频").waitForExistence(timeout: 5)); app.inputItem("恢复默认词频").tap()
        XCTAssertEqual(field.value as? String, "你好", "Candidate management must not commit the draft")
        app.inputItem("collapse-candidates").tap(); app.inputItem("clear-composition").tap()
        app.inputItem("key-中").tap()
        for letter in "hel" { app.inputItem("key-" + String(letter)).tap() }
        let hello = app.inputItem("key-hello")
        XCTAssertTrue(hello.waitForExistence(timeout: 5)); hello.tap()
        XCTAssertEqual(field.value as? String, "你好hello")
        let space = app.inputItem("key-空格")
        space.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).press(forDuration: 0.6, thenDragTo: space.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)))
        XCTAssertEqual(field.value as? String, "你好hello", "Cursor gesture must not insert a space")
        app.inputItem("key-x").tap()
        let moved = field.value as? String ?? ""
        XCTAssertTrue(moved.contains("x")); XCTAssertFalse(moved.hasSuffix("x"), "Space drag must move the host cursor")
        let image = XCTAttachment(screenshot: app.screenshot()); image.lifetime = .keepAlways; add(image)
    }
    func testSideRailScrollStartsOnSymbolAndPinyinButtons() {
        let app = XCUIApplication(); app.launch()
        exerciseSystemKeyboard(fullAccessEnabled: false, verifySnapshot: false, chineseLayout: "nine")
        let field = app.descendants(matching: .any).matching(identifier: "sample-text").firstMatch
        let rail = app.collectionViews["quick-symbols"], first = app.inputItem("symbol-，")
        let before = first.frame.minY, text = field.value as? String
        app.inputItem("symbol-！").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.05, thenDragTo: rail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)))
        XCTAssertTrue(!first.exists || first.frame.minY < before - 20)
        XCTAssertEqual(field.value as? String, text)
        for digit in "744" { app.inputItem("nine-" + String(digit)).tap() }
        let filter = app.collectionViews["pinyin-filter"]
        let overflows = filter.cells.count > 3
        print("PINYIN_RAIL items=\(filter.cells.count) overflows=\(overflows)")
        let top = filter.cells.firstMatch, topID = top.identifier, topBefore = top.frame.minY
        let pendingBeforeDrag=app.staticTexts["composition-preedit"].label
        let origin = overflows ? (filter.cells.allElementsBoundByIndex.first(where: { $0.frame.midY > filter.frame.midY && $0.frame.maxY <= filter.frame.maxY }) ?? top) : top
        origin.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.05, thenDragTo: filter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)))
        if overflows { XCTAssertTrue(!filter.cells[topID].exists || filter.cells[topID].frame.minY < topBefore - 20) }
        XCTAssertEqual(app.staticTexts["composition-preedit"].label,pendingBeforeDrag,"Syllable drag must not choose a reading")
        XCTAssertEqual(field.value as? String, text)
        app.inputItem("clear-composition").tap()
    }
    func testFixedFooterNestedPanelReturnAndNoPreview() {
        let app = XCUIApplication(); app.launch()
        exerciseSystemKeyboard(fullAccessEnabled: false, verifySnapshot: false, chineseLayout: "nine")
        let symbol = app.inputItem("key-符").frame, digits = app.inputItem("key-123").frame
        let language = app.inputItem("key-中").frame, space = app.inputItem("key-空格").frame, enter = app.inputItem("return-key").frame
        func same(_ item: String, _ rect: CGRect) {
            let actual = app.inputItem(item).frame
            XCTAssertEqual(actual.minX, rect.minX, accuracy: 1); XCTAssertEqual(actual.minY, rect.minY, accuracy: 1)
            XCTAssertEqual(actual.width, rect.width, accuracy: 1); XCTAssertEqual(actual.height, rect.height, accuracy: 1)
        }
        app.inputItem("key-符").tap()
        same("return-symbols",symbol);same("key-123",digits);same("key-中",language);same("key-空格",space);same("return-key",enter)
        app.inputItem("key-123").tap()
        same("key-符",symbol);same("return-numbers",digits);same("key-中",language);same("key-0",space);same("return-key",enter)
        app.inputItem("return-numbers").tap();XCTAssertTrue(app.collectionViews["symbol-items"].exists)
        app.inputItem("return-symbols").tap();XCTAssertTrue(app.inputItem("nine-2").exists)
        app.inputItem("key-中").tap()
        same("key-英",language);same("key-符",symbol);same("key-123",digits);same("key-空格",space)
        app.inputItem("key-符").tap();same("return-symbols",symbol);app.inputItem("return-symbols").tap()
        XCTAssertTrue(app.inputItem("key-q").exists)
        app.inputItem("key-q").press(forDuration: 0.5)
        XCTAssertFalse(app.staticTexts["key-preview"].exists)
        app.inputItem("key-英").tap()
        for digit in "64426" { app.inputItem("nine-" + String(digit)).tap() }
        let expand = app.inputItem("expand-candidates").frame
        app.inputItem("expand-candidates").tap();same("collapse-candidates",expand)
        app.inputItem("collapse-candidates").tap()
        let screenshot = XCTAttachment(screenshot:app.screenshot());screenshot.lifetime = .keepAlways;add(screenshot)
        app.inputItem("clear-composition").tap()
        app.inputItem("keyboard-settings").tap();XCTAssertFalse(app.buttons["手写"].exists);XCTAssertFalse(app.buttons["笔画"].exists)
        app.inputItem("布局与显示").tap();app.inputItem("中文26键").tap();same("key-符",symbol);same("key-123",digits);same("key-中",language)
        app.inputItem("key-符").tap();same("return-symbols",symbol);app.inputItem("return-symbols").tap()
        XCTAssertTrue(app.inputItem("key-n").exists)
    }
    func testCompactPunctuationAndFooterColumnAlignment() {
        let app=XCUIApplication();app.launch()
        exerciseSystemKeyboard(fullAccessEnabled:false,verifySnapshot:false,chineseLayout:"nine")
        let rail=app.collectionViews["quick-symbols"]
        for text in ["，","。","！","？"] {
            let item=app.inputItem("symbol-"+text)
            XCTAssertTrue(item.isHittable);XCTAssertEqual(item.frame.height,44,accuracy:1)
            XCTAssertGreaterThanOrEqual(item.frame.minY,rail.frame.minY-1);XCTAssertLessThanOrEqual(item.frame.maxY,rail.frame.maxY+1)
        }
        func column(_ lower:String,_ upper:String) {
            let a=app.inputItem(lower).frame,b=app.inputItem(upper).frame
            XCTAssertEqual(a.minX,b.minX,accuracy:1);XCTAssertEqual(a.width,b.width,accuracy:1)
        }
        column("key-123","nine-7");column("key-空格","nine-8")
        if !app.inputItem("switch-system-keyboard").exists { column("key-中","nine-9") }
        let originalSpace=app.inputItem("key-空格").frame
        XCTAssertLessThan(originalSpace.width,app.frame.width*0.3)
        let originalNumber=app.inputItem("key-123").frame,originalLanguage=app.inputItem("key-中").frame
        app.inputItem("key-123").tap();column("return-numbers","number-7");column("key-0","number-8")
        XCTAssertEqual(app.inputItem("key-中").frame.minX,originalLanguage.minX,accuracy:1)
        app.inputItem("return-numbers").tap();app.inputItem("key-符").tap()
        XCTAssertEqual(app.inputItem("key-123").frame.minX,originalNumber.minX,accuracy:1)
        XCTAssertEqual(app.inputItem("key-空格").frame.width,originalSpace.width,accuracy:1)
        app.inputItem("return-symbols").tap()
        let image=XCTAttachment(screenshot:app.screenshot());image.lifetime = .keepAlways;add(image)
    }
    func testBoundaryTranspositionLongSentenceCommitsOnlyAfterSelection() {
        let app=XCUIApplication();app.launch()
        exerciseSystemKeyboard(fullAccessEnabled:false,verifySnapshot:false,chineseLayout:"nine")
        app.inputItem("clear-sample").tap()
        let field=app.descendants(matching:.any).matching(identifier:"sample-text").firstMatch
        for digit in "74642296354263243496" { app.inputItem("nine-"+String(digit)).tap() }
        let updated=XCTNSPredicateExpectation(predicate:NSPredicate(format:"value == '候选已更新'"),object:app.inputItem("expand-candidates"))
        XCTAssertEqual(XCTWaiter.wait(for:[updated],timeout:10),.completed)
        XCTAssertEqual(field.value as? String,"")
        let candidate=app.inputItem("key-请把文件发给我")
        if !candidate.isHittable {
            app.inputItem("expand-candidates").tap()
            for _ in 0..<8 { if candidate.isHittable { break };app.collectionViews["candidate-list"].swipeUp() }
        }
        XCTAssertTrue(candidate.isHittable);candidate.tap()
        XCTAssertEqual(field.value as? String,"请把文件发给我")
        XCTAssertTrue(app.inputItem("nine-2").isHittable)
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="boundary-transpose-long-sentence";shot.lifetime = .keepAlways;add(shot)
    }
    func testNineTypoCandidateAndConfirmedReplacement() {
        let app=XCUIApplication();app.launch()
        exerciseSystemKeyboard(fullAccessEnabled:false,verifySnapshot:false,chineseLayout:"nine")
        let field=app.descendants(matching:.any).matching(identifier:"sample-text").firstMatch
        app.inputItem("clear-sample").tap();field.tap()
        for digit in "64425" { app.inputItem("nine-"+String(digit)).tap() }
        let corrected=app.inputItem("key-你好")
        XCTAssertTrue(corrected.waitForExistence(timeout:8));XCTAssertTrue(corrected.isHittable)
        corrected.tap();XCTAssertEqual(field.value as? String,"你好")
        // Fully remove the recent own commit, then explicitly select a different
        // word for the same code. This must train that choice without replaying text.
        app.inputItem("key-⌫").tap();app.inputItem("key-⌫").tap()
        XCTAssertEqual(field.value as? String,"")
        for digit in "64426" { app.inputItem("nine-"+String(digit)).tap() }
        let alternatives=app.collectionViews["candidate-strip"].cells.allElementsBoundByIndex
        guard let other=alternatives.first(where:{$0.isHittable && $0.identifier != "key-你好" && $0.label.count==2}) else { XCTFail("Real alternative must exist");return }
        let word=other.label;other.tap();XCTAssertEqual(field.value as? String,word)
        let image=XCTAttachment(screenshot:app.screenshot());image.lifetime = .keepAlways;add(image)
    }
    func testSelectedPrefixWholeDeletionLearnsNewDirection() {
        let app=XCUIApplication();app.launch()
        exerciseSystemKeyboard(fullAccessEnabled:false,verifySnapshot:false,chineseLayout:"nine")
        let field=app.descendants(matching:.any).matching(identifier:"sample-text").firstMatch
        app.inputItem("clear-sample").tap();field.tap()
        var keys:[Character:XCUICoordinate]=[:]
        for digit in "23456789" { keys[digit]=app.inputItem("nine-"+String(digit)).coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)) }
        for digit in "746464" { keys[digit]!.tap() }
        let prefix=app.inputItem("key-请")
        if !prefix.isHittable {
            app.inputItem("expand-candidates").tap()
            for _ in 0..<4 { if prefix.isHittable { break };app.collectionViews["candidate-list"].swipeUp() }
        }
        XCTAssertTrue(prefix.isHittable);prefix.tap();XCTAssertEqual(field.value as? String,"")
        app.inputItem("key-你").tap();XCTAssertEqual(field.value as? String,"请你")
        let delete=app.inputItem("key-⌫");delete.tap();delete.tap();XCTAssertEqual(field.value as? String,"")
        for digit in "7464646" { keys[digit]!.tap() }
        let replacement=app.inputItem("key-请您")
        XCTAssertTrue(replacement.waitForExistence(timeout:5));XCTAssertTrue(replacement.isHittable);replacement.tap()
        XCTAssertEqual(field.value as? String,"请您")
    }
    func testSemanticSentenceAssemblyAndLateResultCancellation() {
        let app=XCUIApplication();app.launch()
        exerciseSystemKeyboard(fullAccessEnabled:false,verifySnapshot:false,chineseLayout:"nine")
        let field=app.descendants(matching:.any).matching(identifier:"sample-text").firstMatch
        app.inputItem("clear-sample").tap();field.tap()
        for digit in "7464223494492432942426" { app.inputItem("nine-"+String(digit)).tap() }
        let updated=XCTNSPredicateExpectation(predicate:NSPredicate(format:"value == '候选已更新'"),object:app.inputItem("expand-candidates"))
        XCTAssertEqual(XCTWaiter.wait(for:[updated],timeout:15),.completed)
        XCTAssertEqual(field.value as? String,"")
        if !app.inputItem("key-请把地址再发一遍").isHittable { app.inputItem("expand-candidates").tap() }
        let target=app.inputItem("key-请把地址再发一遍")
        for _ in 0..<6 { if target.isHittable { break };app.collectionViews["candidate-list"].swipeUp() }
        XCTAssertTrue(target.isHittable);target.tap();XCTAssertEqual(field.value as? String,"请把地址再发一遍")
        for digit in "64425" { app.inputItem("nine-"+String(digit)).tap() }
        app.inputItem("clear-composition").tap()
        let stale=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in
            let label=app.staticTexts["composition-preedit"];return label.exists && !label.label.isEmpty
        },object:nil);stale.isInverted=true
        XCTAssertEqual(XCTWaiter.wait(for:[stale],timeout:0.5),.completed)
        XCTAssertEqual(field.value as? String,"请把地址再发一遍")
        let image=XCTAttachment(screenshot:app.screenshot());image.lifetime = .keepAlways;add(image)
    }
    // Real-device smoke uses the already configured keyboard; no Settings or
    // learning preferences are changed and no candidate is committed.
    func testCommonYouFirstCandidateDoesNotBecomeAnEditedPhrase() {
        let app=XCUIApplication();app.launch()
        exerciseSystemKeyboard(fullAccessEnabled:false,verifySnapshot:false,chineseLayout:"nine")
        let field=app.descendants(matching:.any).matching(identifier:"sample-text").firstMatch
        app.inputItem("clear-sample").tap();field.tap()
        for digit in "968" { app.inputItem("nine-"+String(digit)).tap() }
        let ready=XCTNSPredicateExpectation(predicate:NSPredicate(format:"value == '候选已更新'"),object:app.inputItem("expand-candidates"))
        XCTAssertEqual(XCTWaiter.wait(for:[ready],timeout:15),.completed)
        XCTAssertEqual(app.inputItem("key-有").value as? String,"0")
        XCTAssertEqual(app.inputItem("composition-preedit").label,"you")
        XCTAssertEqual(field.value as? String,"")
        for digit in "94943" { app.inputItem("nine-"+String(digit)).tap() }
        let phraseReady=XCTNSPredicateExpectation(predicate:NSPredicate(format:"value == '候选已更新'"),object:app.inputItem("expand-candidates"))
        XCTAssertEqual(XCTWaiter.wait(for:[phraseReady],timeout:15),.completed)
        XCTAssertEqual(app.inputItem("key-有一些").value as? String,"0")
        for digit in "94678" { app.inputItem("nine-"+String(digit)).tap() }
        let fullReady=XCTNSPredicateExpectation(predicate:NSPredicate(format:"value == '候选已更新'"),object:app.inputItem("expand-candidates"))
        XCTAssertEqual(XCTWaiter.wait(for:[fullReady],timeout:15),.completed)
        XCTAssertEqual(app.inputItem("key-有一些因素").value as? String,"0")
        app.inputItem("key-有一些因素").tap();XCTAssertEqual(field.value as? String,"有一些因素")
        let image=XCTAttachment(screenshot:app.screenshot());image.lifetime = .keepAlways;add(image)
    }
    func testStablePinyinAndFullWidthLettersWithPunctuationContinuation() {
        let app=XCUIApplication();app.launch()
        exerciseSystemKeyboard(fullAccessEnabled:false,verifySnapshot:false,chineseLayout:"pinyin26")
        let field=app.descendants(matching:.any).matching(identifier:"sample-text").firstMatch
        app.inputItem("clear-sample").tap();field.tap()
        let q=app.inputItem("key-q"),a=app.inputItem("key-a"),z=app.inputItem("key-z")
        XCTAssertGreaterThan(q.frame.width,30)
        XCTAssertEqual(q.frame.width,a.frame.width,accuracy:1);XCTAssertEqual(q.frame.width,z.frame.width,accuracy:1)
        XCTAssertEqual(a.frame.minX-q.frame.minX,(q.frame.width+4)/2,accuracy:1)
        XCTAssertEqual(z.frame.minX-q.frame.minX,(q.frame.width+4)*1.5,accuracy:1)
        for letter in "ruguoming tianxiayu".filter({$0 != " "}) { app.inputItem("key-"+String(letter)).tap() }
        let phrase=app.inputItem("key-如果明天下雨")
        if !phrase.isHittable { app.inputItem("expand-candidates").tap() }
        XCTAssertTrue(phrase.waitForExistence(timeout:10));phrase.tap()
        XCTAssertEqual(field.value as? String,"如果明天下雨")
        app.inputItem("key-符").tap();app.inputItem("symbol-，").tap();app.inputItem("return-symbols").tap()
        XCTAssertEqual(field.value as? String,"如果明天下雨，")
        let next=app.inputItem("key-就")
        XCTAssertTrue(next.waitForExistence(timeout:10))
        if !next.isHittable { app.inputItem("expand-candidates").tap() }
        next.tap();XCTAssertEqual(field.value as? String,"如果明天下雨，就")
        app.inputItem("clear-sample").tap();field.tap()
        // Reset the document context, return to nine keys for incremental display.
        app.inputItem("keyboard-settings").tap();app.inputItem("布局与显示").tap();app.inputItem("中文九宫格").tap()
        for digit in "9663694243946474924542694" {
            app.inputItem("nine-"+String(digit)).tap()
            let displayed=app.inputItem("composition-preedit").label
            XCTAssertFalse(displayed.contains("wxyz"));XCTAssertFalse(displayed.contains("mno ghi"))
        }
        let image=XCTAttachment(screenshot:app.screenshot());image.lifetime = .keepAlways;add(image)
        app.inputItem("clear-composition").tap();XCTAssertEqual(field.value as? String,"")
    }
    func testDeviceSemanticSmokeWithoutCommit() {
        let app=XCUIApplication();app.launch()
        let field=app.descendants(matching:.any).matching(identifier:"sample-text").firstMatch
        app.inputItem("clear-sample").tap();field.tap()
        XCTAssertTrue(app.inputItem("nine-6").waitForExistence(timeout:10))
        for digit in "7464223494492432942426" { app.inputItem("nine-"+String(digit)).tap() }
        let updated=XCTNSPredicateExpectation(predicate:NSPredicate(format:"value == '候选已更新'"),object:app.inputItem("expand-candidates"))
        XCTAssertEqual(XCTWaiter.wait(for:[updated],timeout:15),.completed)
        XCTAssertEqual(field.value as? String,"")
        var expanded=false
        let target=app.inputItem("key-请把地址再发一遍")
        if !target.isHittable {
            app.inputItem("expand-candidates").tap();expanded=true
            for _ in 0..<6 { if target.isHittable { break };app.collectionViews["candidate-list"].swipeUp() }
        }
        XCTAssertTrue(target.isHittable)
        if expanded { app.inputItem("collapse-candidates").tap() }
        app.inputItem("clear-composition").tap();XCTAssertEqual(field.value as? String,"")
    }
    func testJointNineCorrectionKeepsDraftUntilCandidateSelection() {
        let app=XCUIApplication();app.launch()
        exerciseSystemKeyboard(fullAccessEnabled:false,verifySnapshot:false,chineseLayout:"nine")
        let field=app.descendants(matching:.any).matching(identifier:"sample-text").firstMatch
        app.inputItem("clear-sample").tap();field.tap()
        for digit in "642696942644374884" { app.inputItem("nine-"+String(digit)).tap() }
        let updated=XCTNSPredicateExpectation(predicate:NSPredicate(format:"value == '候选已更新'"),object:app.inputItem("expand-candidates"))
        XCTAssertEqual(XCTWaiter.wait(for:[updated],timeout:10),.completed)
        XCTAssertEqual(field.value as? String,"")
        app.inputItem("expand-candidates").tap()
        let candidate=app.inputItem("key-你好我想喝水")
        for _ in 0..<6 { if candidate.isHittable { break };app.collectionViews["candidate-list"].swipeUp() }
        XCTAssertTrue(candidate.isHittable);candidate.tap()
        XCTAssertEqual(field.value as? String,"你好我想喝水")
        let image=XCTAttachment(screenshot:app.screenshot());image.lifetime = .keepAlways;add(image)
    }
    func testQualityBatchMissingExtraAndLockedReading() {
        let app=XCUIApplication();app.launch()
        exerciseSystemKeyboard(fullAccessEnabled:false,verifySnapshot:false,chineseLayout:"nine")
        let field=app.descendants(matching:.any).matching(identifier:"sample-text").firstMatch
        for code in ["6426","644426"] {
            app.inputItem("clear-sample").tap();field.tap()
            for digit in code { app.inputItem("nine-"+String(digit)).tap() }
            let updated=XCTNSPredicateExpectation(predicate:NSPredicate(format:"value == '候选已更新'"),object:app.inputItem("expand-candidates"))
            XCTAssertEqual(XCTWaiter.wait(for:[updated],timeout:10),.completed)
            if !app.inputItem("key-你好").isHittable {
                app.inputItem("expand-candidates").tap()
                for _ in 0..<5 { if app.inputItem("key-你好").isHittable { break };app.collectionViews["candidate-list"].swipeUp() }
            }
            XCTAssertTrue(app.inputItem("key-你好").isHittable);app.inputItem("key-你好").tap()
            XCTAssertEqual(field.value as? String,"你好")
        }
        app.inputItem("clear-sample").tap();field.tap()
        for digit in "64425" { app.inputItem("nine-"+String(digit)).tap() }
        app.inputItem("pinyin-ni").tap()
        let target=app.inputItem("key-你好");XCTAssertTrue(target.waitForExistence(timeout:10))
        XCTAssertTrue(app.staticTexts["composition-preedit"].label.hasPrefix("ni"))
        if !target.isHittable { app.inputItem("expand-candidates").tap() }
        app.inputItem("key-你好").tap();XCTAssertEqual(field.value as? String,"你好")
        let image=XCTAttachment(screenshot:app.screenshot());image.lifetime = .keepAlways;add(image)
    }
    override func setUpWithError() throws { continueAfterFailure = false }
    func testNativeHostKeyboardPresentation() {
        probeNativeHost(secure: false)
    }
    func testNativeSecureHostKeyboardPresentation() {
        probeNativeHost(secure: true)
    }
    private func probeNativeHost(secure: Bool) {
        let app = XCUIApplication()
        if secure { app.launchEnvironment["PRIVATE_INPUT_PROBE_SECURE_HOST"] = "1" }
        app.launch()
        let open = app.inputItem("open-native-host-probe")
        keyboardReveal(open, in: app); XCTAssertTrue(open.waitForExistence(timeout: 10)); open.tap()
        let geometry = app.staticTexts["native-host-geometry"]
        XCTAssertTrue(geometry.waitForExistence(timeout: 10))
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS 'notification_visible=1'"), object: geometry)
        let result = XCTWaiter.wait(for: [visible], timeout: 8)
        let diagnostic = geometry.value as? String ?? geometry.label
        let attachment = XCTAttachment(string: diagnostic); attachment.lifetime = .keepAlways; add(attachment)
        print("NATIVE_HOST_GEOMETRY " + diagnostic)
        XCTAssertEqual(result, .completed, "Native UIKit host keyboard must be on screen: " + diagnostic)
        if secure {
            XCTAssertFalse(app.inputItem("key-n").exists, "Secure fields must be handled by the system keyboard")
            let keyboard = app.keyboards.firstMatch
            XCTAssertTrue(keyboard.exists); XCTAssertTrue(keyboard.frame.intersects(app.frame))
            return
        }
        if !app.inputItem("key-n").exists {
            let globe = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Next keyboard' OR label CONTAINS[c] 'Switch keyboard' OR identifier == 'switch-system-keyboard' OR label CONTAINS '下一个键盘' OR label CONTAINS '切换键盘'")).firstMatch
            XCTAssertTrue(globe.waitForExistence(timeout: 5)); globe.press(forDuration: 1)
            let items = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '灵鹤输入法'"))
            XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 5))
            guard let ours = items.allElementsBoundByIndex.first(where: { $0.isHittable && $0.frame.midY > app.frame.height / 2 }) else { XCTFail("Own keyboard must be in the menu"); return }
            ours.tap()
        }
        let key = app.inputItem("key-n")
        XCTAssertTrue(key.waitForExistence(timeout: 10))
        XCTAssertLessThan(key.frame.maxY, app.frame.maxY, "A keyboard element below the viewport cannot prove typing")
        XCTAssertTrue(key.isHittable)
        for letter in ["n", "i", "h", "a", "o"] { app.inputItem("key-" + letter).tap() }
        app.inputItem("key-你好").tap()
        XCTAssertEqual(app.textFields["native-host-field"].value as? String, "你好")
    }
    func testHostOfflineEngine() {
        let app = XCUIApplication(); app.activate()
        let dismiss = app.inputItem("dismiss-keyboard")
        if dismiss.exists && dismiss.isHittable { dismiss.tap() }
        let smoke = app.inputItem("engine-smoke")
        keyboardReveal(smoke, in: app)
        XCTAssertTrue(smoke.waitForExistence(timeout: 20)); smoke.tap()
        keyboardReveal(app.staticTexts["engine-result"], in: app)
        XCTAssertEqual(app.staticTexts["engine-result"].label, "候选验证通过")
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.lifetime = .keepAlways; add(attachment)
    }
    func testSystemKeyboardWithoutFullAccess() {
        XCUIApplication().launch()
        exerciseSystemKeyboard(fullAccessEnabled: false, verifySnapshot: false)
    }
    func testCandidateExpansionHasAccessibleTouchArea() {
        let app=XCUIApplication();app.launch();app.inputItem("sample-text").tap()
        if !app.inputItem("nine-4").waitForExistence(timeout:3) {exerciseSystemKeyboard(fullAccessEnabled:false,verifySnapshot:false,chineseLayout:"nine")}
        clearSyntheticField(app)
        for digit in "64426" { app.inputItem("nine-"+String(digit)).tap() }
        let expand=app.inputItem("expand-candidates")
        XCTAssertTrue(expand.waitForExistence(timeout:5));XCTAssertGreaterThanOrEqual(expand.frame.width,44);XCTAssertGreaterThanOrEqual(expand.frame.height,44)
        expand.tap()
        let collapse=app.inputItem("collapse-candidates")
        XCTAssertTrue(collapse.waitForExistence(timeout:5),"Center activation must expand; \(expand.debugDescription)")
        let attachment=XCTAttachment(screenshot:app.screenshot());attachment.lifetime = .keepAlways;add(attachment)
        collapse.tap();XCTAssertTrue(app.inputItem("nine-4").waitForExistence(timeout:5))
    }
    func testRealDictionaryScrollLongCandidateAndPreservesEnglishSwitchDraft() {
        let app = XCUIApplication(); app.launch()
        exerciseSystemKeyboard(fullAccessEnabled: false, verifySnapshot: false)
        let clear = app.inputItem("clear-sample")
        XCTAssertTrue(clear.isHittable); clear.tap()
        let field = app.descendants(matching: .any).matching(identifier: "sample-text").firstMatch
        field.tap()
        for key in Array("nihao").map(String.init) { app.inputItem("key-" + key).tap() }
        app.inputItem("key-中").tap()
        XCTAssertEqual(field.value as? String, "nihao", "Changing mode must preserve raw letters without inserting display spaces")
        for key in Array("hello").map(String.init) { app.inputItem("key-" + key).tap() }
        app.inputItem("key-⇧").tap(); app.inputItem("key-W").tap()
        XCTAssertEqual(field.value as? String, "nihaohelloW")
        app.inputItem("key-英").tap()
        for key in Array("zhonghuarenmingongheguo").map(String.init) { app.inputItem("key-" + key).tap() }
        let longWord = app.inputItem("key-中华人民共和国")
        XCTAssertTrue(longWord.waitForExistence(timeout: 8)); XCTAssertTrue(longWord.isHittable)
        XCTAssertGreaterThan(longWord.frame.width, 130, "Long candidates must not be squeezed into one seventh of the keyboard")
        let image = XCTAttachment(screenshot: app.screenshot()); image.lifetime = .keepAlways; add(image)
        longWord.tap(); XCTAssertEqual(field.value as? String, "nihaohelloW中华人民共和国")
        for key in Array("shi").map(String.init) { app.inputItem("key-" + key).tap() }
        app.inputItem("expand-candidates").tap()
        let list = app.collectionViews["candidate-list"]; list.swipeUp()
        guard let chosen = list.cells.allElementsBoundByIndex.first(where: { $0.frame.minY >= list.frame.minY && $0.frame.maxY <= list.frame.maxY && $0.frame.width > 0 && (Int($0.value as? String ?? "") ?? 0) >= 7 && $0.label.count == 1 && $0.isHittable }) else { XCTFail("Scroll must expose further real candidates"); return }
        let selected = chosen.label; chosen.tap()
        XCTAssertEqual(field.value as? String, "nihaohelloW中华人民共和国" + selected)
    }
    func testSettingsLanguageAndChineseLayoutRemainSeparate() {
        let app = XCUIApplication(); app.launch()
        exerciseSystemKeyboard(fullAccessEnabled: true, verifySnapshot: false)
        app.inputItem("dismiss-keyboard").tap(); app.inputItem("键盘与词库").tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '中文布局'")).firstMatch.tap(); app.inputItem("中文 · 26 键").tap()
        let english = app.switches["默认英文输入"]
        if english.value as? String != "1" { let toggle = english.switches.firstMatch; if toggle.exists { toggle.tap() } else { english.tap() } }
        XCTAssertEqual(english.value as? String, "1")
        app.navigationBars.buttons.firstMatch.tap()
        let field = app.descendants(matching: .any).matching(identifier: "sample-text").firstMatch; field.tap()
        XCTAssertTrue(app.inputItem("key-英").waitForExistence(timeout: 5)); app.inputItem("key-x").tap()
        XCTAssertTrue(["你好x", "你x好", "x你好"].contains(field.value as? String ?? ""))
        app.inputItem("key-英").tap(); XCTAssertTrue(app.inputItem("key-n").exists); XCTAssertFalse(app.inputItem("nine-2").exists)
        app.inputItem("dismiss-keyboard").tap(); app.inputItem("键盘与词库").tap()
        let restore = app.switches["默认英文输入"]; if restore.value as? String == "1" { let toggle = restore.switches.firstMatch; if toggle.exists { toggle.tap() } else { restore.tap() } }
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '中文布局'")).firstMatch.tap(); app.inputItem("中文 · 九宫格").tap()
        app.navigationBars.buttons.firstMatch.tap(); field.tap(); XCTAssertTrue(app.inputItem("nine-2").waitForExistence(timeout: 5))
    }
    func testNineSyllableFilterNumbersAndCategorizedSymbols() {
        let app = XCUIApplication(); app.launch()
        exerciseSystemKeyboard(fullAccessEnabled: false, verifySnapshot: false, chineseLayout: "nine")
        let field = app.descendants(matching: .any).matching(identifier: "sample-text").firstMatch
        let chineseFrame = app.inputItem("nine-2").frame
        for digit in "64426" { app.inputItem("nine-" + String(digit)).tap() }
        XCTAssertFalse(app.staticTexts["composition-preedit"].label.contains(where:{$0.isNumber}))
        XCTAssertTrue(app.collectionViews["pinyin-filter"].exists)
        XCTAssertTrue(app.inputItem("pinyin-mi").waitForExistence(timeout: 5)); app.inputItem("pinyin-mi").tap()
        XCTAssertEqual(field.value as? String, "你好", "Syllable selection must never insert host text")
        XCTAssertTrue(app.staticTexts["composition-preedit"].label.hasPrefix("mi"))
        XCTAssertFalse(app.staticTexts["composition-preedit"].label.contains(where: { $0.isNumber }))
        XCTAssertFalse(app.inputItem("key-你好").isHittable, "mi must actually remove the ni reading")
        XCTAssertFalse(app.inputItem("undo-pinyin-filter").exists)
        app.inputItem("key-⌫").tap()
        XCTAssertEqual(field.value as? String,"你好","Deleting a filter must leave host text unchanged")
        app.inputItem("pinyin-ni").tap()
        XCTAssertTrue(app.inputItem("pinyin-hao").waitForExistence(timeout: 5)); app.inputItem("pinyin-hao").tap()
        app.inputItem("key-⌫").tap()
        XCTAssertTrue(app.inputItem("pinyin-hao").exists,"Delete must undo only the latest syllable filter")
        app.inputItem("pinyin-hao").tap()
        XCTAssertEqual(field.value as? String, "你好")
        app.inputItem("key-你好").tap(); XCTAssertEqual(field.value as? String,"你好你好")
        for digit in "64" { app.inputItem("nine-" + String(digit)).tap() }
        app.inputItem("key-123").tap()
        let numberFrame = app.inputItem("number-2").frame
        XCTAssertEqual(numberFrame.minX, chineseFrame.minX, accuracy: 1); XCTAssertEqual(numberFrame.width, chineseFrame.width, accuracy: 1)
        XCTAssertTrue(app.collectionViews["quick-symbols"].exists)
        XCTAssertEqual(field.value as? String,"你好你好", "Switching panels must preserve the draft")
        app.inputItem("return-numbers").tap(); XCTAssertTrue(app.collectionViews["pinyin-filter"].exists)
        app.inputItem("clear-composition").tap(); app.inputItem("key-123").tap()
        app.inputItem("number-1").tap(); app.inputItem("key-0").tap(); app.inputItem("symbol-.").tap()
        XCTAssertEqual(field.value as? String,"你好你好10.")
        app.inputItem("return-numbers").tap(); app.inputItem("key-符").tap()
        tapSymbolCategory("bullets", in: app); app.inputItem("symbol-•").tap()
        XCTAssertEqual(field.value as? String,"你好你好10.•")
        tapSymbolCategory("english", in: app); app.inputItem("symbol-,").tap()
        XCTAssertEqual(field.value as? String,"你好你好10.•,")
        tapSymbolCategory("chinese", in: app); app.inputItem("symbol-。").tap()
        XCTAssertEqual(field.value as? String,"你好你好10.•,。")
        tapSymbolCategory("special", in: app)
        app.inputItem("symbol-©").tap(); XCTAssertEqual(field.value as? String,"你好你好10.•,。©")
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.lifetime = .keepAlways; add(screenshot)
    }
    private func tapSymbolCategory(_ category: String, in app: XCUIApplication) {
        let scroll = app.collectionViews["symbol-categories"], target = app.inputItem("symbol-category-" + category)
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        for _ in 0..<8 {
            let frame = target.frame, viewport = scroll.frame
            let visible = frame.intersection(viewport)
            if visible.height >= frame.height * 0.8 && viewport.contains(CGPoint(x: frame.midX, y: frame.midY)) && target.isHittable { target.tap(); return }
            let upward = frame.midY > viewport.midY
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.8 : 0.2)).press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.2 : 0.8)))
        }
        XCTFail("Category must be reachable in its own scroll region")
    }
    func testNineDisplayAndLongPressDeletion() {
        let app = XCUIApplication(); app.launch()
        exerciseSystemKeyboard(fullAccessEnabled: false, verifySnapshot: false, chineseLayout: "nine")
        let field = app.descendants(matching: .any).matching(identifier: "sample-text").firstMatch
        app.inputItem("key-中").tap()
        let text = "abcdefghijklmnopqrstuvwxyzabcdefghij"
        for letter in text { app.inputItem("key-" + String(letter)).tap() }
        let initial = field.value as? String ?? ""
        app.inputItem("key-⌫").tap(); XCTAssertEqual(field.value as? String, String(initial.dropLast()), "One tap must delete once")
        app.inputItem("key-⌫").press(forDuration: 1.1)
        let held = field.value as? String ?? ""
        XCTAssertLessThan(held.count, initial.count - 5, "Holding delete must repeat")
        XCTAssertFalse(held.isEmpty)
        Thread.sleep(forTimeInterval: 0.35)
        XCTAssertEqual(field.value as? String, held, "Releasing delete must stop repetition")
        app.inputItem("key-x").tap(); XCTAssertEqual(field.value as? String, held + "x")
        app.inputItem("key-英").tap()
        for digit in "64426" { app.inputItem("nine-" + String(digit)).tap() }
        XCTAssertEqual(app.staticTexts["composition-preedit"].label, "ni hao")
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.lifetime = .keepAlways; add(screenshot)
        for digit in "744543" { app.inputItem("nine-" + String(digit)).tap() }
        app.inputItem("key-⌫").press(forDuration: 0.65)
        XCTAssertEqual(field.value as? String, held + "x", "Deleting the pending code must preserve committed text while digits remain")
        XCTAssertFalse(app.staticTexts["composition-preedit"].label.contains(where: { $0.isNumber }))
        app.inputItem("clear-composition").tap(); app.inputItem("key-符").tap()
        XCTAssertFalse(app.inputItem("scroll-symbol-categories").exists)
        XCTAssertFalse(app.inputItem("scroll-symbol-items").exists)
        XCTAssertLessThan(app.collectionViews["symbol-categories"].frame.maxX, app.collectionViews["symbol-items"].frame.minX)
        XCTAssertTrue(app.inputItem("symbol-，").isHittable)
        let symbols = app.collectionViews["symbol-items"]
        let punctuation = app.inputItem("symbol-：")
        let column = (punctuation.frame.midX - symbols.frame.minX) / symbols.frame.width
        punctuation.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.05, thenDragTo: symbols.coordinate(withNormalizedOffset: CGVector(dx: column, dy: 0.05)))
        XCTAssertFalse(app.inputItem("symbol-，").isHittable)
    }
    func testZCompactKeyboardFullCandidateScrollAndSymbolRail() {
        let app = XCUIApplication(); app.launch()
        exerciseSystemKeyboard(fullAccessEnabled: false, verifySnapshot: false, chineseLayout: "nine")
        XCTAssertFalse(app.inputItem("key-26键").exists); XCTAssertFalse(app.inputItem("key-9键").exists)
        XCTAssertFalse(app.inputItem("previous-candidates").exists); XCTAssertFalse(app.inputItem("next-candidates").exists)
        let field = app.descendants(matching: .any).matching(identifier: "sample-text").firstMatch
        for digit in "644" { app.inputItem("nine-" + String(digit)).tap() }
        app.inputItem("clear-composition").tap(); XCTAssertEqual(field.value as? String,"你好")
        let rail = app.collectionViews["quick-symbols"]; rail.swipeUp()
        guard let symbol = rail.cells.allElementsBoundByIndex.first(where: { $0.frame.minY >= rail.frame.minY && $0.frame.maxY <= rail.frame.maxY && $0.frame.width > 0 && !["，", "。", "！"].contains($0.label) && $0.isHittable }) else { XCTFail("Symbol rail must expose further symbols after scrolling"); return }
        let punctuation = symbol.label; symbol.tap()
        app.inputItem("key-中").tap(); for letter in "hi" { app.inputItem("key-" + String(letter)).tap() }
        XCTAssertEqual(field.value as? String,"你好" + punctuation + "hi")
        app.inputItem("key-英").tap(); app.inputItem("keyboard-settings").tap(); app.inputItem("布局与显示").tap();app.inputItem("中文26键").tap()
        for letter in "shi" { app.inputItem("key-" + String(letter)).tap() }
        let strip = app.collectionViews["candidate-strip"]; XCTAssertGreaterThan(strip.frame.width, app.frame.width * 0.8)
        XCTAssertFalse(app.inputItem("keyboard-settings").isHittable)
        app.inputItem("expand-candidates").tap()
        let list = app.collectionViews["candidate-list"]; XCTAssertGreaterThan(list.frame.height,180)
        XCTAssertFalse(app.inputItem("key-n").isHittable)
        var choice: XCUIElement?
        for _ in 0..<6 {
            choice = list.cells.allElementsBoundByIndex.first { $0.frame.minY >= list.frame.minY && $0.frame.maxY <= list.frame.maxY && $0.frame.width > 0 && (Int($0.value as? String ?? "") ?? 0) >= 12 && $0.label.count == 1 && $0.isHittable }
            if choice != nil { break }; list.swipeUp()
        }
        guard let chosen = choice else { XCTFail("Scrolling must expose candidates beyond the first engine page"); return }
        let selectedText = chosen.label
        let image = XCTAttachment(screenshot: app.screenshot()); image.lifetime = .keepAlways; add(image)
        chosen.tap(); XCTAssertEqual(field.value as? String,"你好" + punctuation + "hi" + selectedText)
        XCTAssertTrue(app.inputItem("key-n").isHittable)
        app.inputItem("keyboard-settings").tap(); app.inputItem("布局与显示").tap();app.inputItem("中文九宫格").tap()
        app.inputItem("key-123").tap(); app.inputItem("number-1").tap(); app.inputItem("key-0").tap()
        XCTAssertEqual(field.value as? String,"你好" + punctuation + "hi" + selectedText + "10")
        app.inputItem("hide-keyboard").tap()
    }
    func testSharedSnapshotReadWithoutFullAccess() {
        exerciseSystemKeyboard(fullAccessEnabled: false, verifySnapshot: true)
    }
    func testSharedSnapshotWithFullAccess() {
        exerciseSystemKeyboard(fullAccessEnabled: true, verifySnapshot: true)
    }
    func testActualKeyboardImportsLearningWithoutFullAccess() {
        exerciseSystemKeyboard(fullAccessEnabled: false, verifySnapshot: false, learningFixture: true)
    }
    func testActualKeyboardImportsNetworkLearningWithoutFullAccess() throws {
        guard ProcessInfo.processInfo.environment["PRIVATE_INPUT_NETWORK_LEARNING_UI"] == "1" else {
            throw XCTSkip("Requires the successful owned network sync fixture, without preparing a replacement learning snapshot")
        }
        XCUIApplication().launch()
        exerciseSystemKeyboard(fullAccessEnabled: false, verifySnapshot: false, networkLearning: true)
    }
}

extension XCTestCase {
    fileprivate func keyboardReveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 {
            if element.exists && element.frame.height > 0 && element.frame.midY > 80 && element.frame.midY < app.frame.maxY - 100 && element.isHittable { return }
            app.collectionViews.firstMatch.swipeUp()
        }
    }
    fileprivate func keyboardCell(_ app: XCUIApplication, _ predicate: String) -> XCUIElement {
        let item = app.descendants(matching: .any).matching(NSPredicate(format: predicate)).firstMatch
        for _ in 0..<8 {
            if item.exists && item.frame.height > 0 && item.frame.midY > 60 && item.frame.midY < app.frame.maxY - 60 && item.isHittable { return item }
            if item.exists && item.frame.midY < 60 { app.swipeDown() } else { app.swipeUp() }
        }
        return item
    }
    func exerciseSystemKeyboard(fullAccessEnabled: Bool, verifySnapshot: Bool, learningFixture: Bool = false, networkLearning: Bool = false, sharedTextFixture: Bool = false, sharingPaused: Bool = false, chineseLayout: String = "pinyin26", freshHost: Bool = false) {
        var initialChecksum: String?
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences"); settings.launch()
        let general = keyboardCell(settings, "identifier == 'General' OR label == 'General' OR label == '通用'")
        XCTAssertTrue(general.waitForExistence(timeout: 10)); general.tap()
        let keyboard = keyboardCell(settings, "label == 'Keyboard' OR label == '键盘'")
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5)); keyboard.tap()
        let keyboards = settings.cells["KEYBOARDS"]
        XCTAssertTrue(keyboards.waitForExistence(timeout: 5)); keyboards.tap()
        let existing = settings.cells.matching(NSPredicate(format: "label CONTAINS '灵鹤输入法'")).firstMatch
        if !existing.exists {
            keyboardCell(settings, "label BEGINSWITH 'Add New Keyboard' OR label BEGINSWITH '添加新键盘'").tap()
            let item = settings.cells.matching(NSPredicate(format: "label CONTAINS '灵鹤输入法'")).firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 8)); item.tap()
        }
        let detail = settings.cells.matching(NSPredicate(format: "label CONTAINS '灵鹤输入法'")).firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 5)); detail.tap()
        let fullAccess = settings.switches.matching(NSPredicate(format: "label CONTAINS 'Allow Full Access' OR label CONTAINS '允许完全访问'")).firstMatch
        XCTAssertTrue(fullAccess.waitForExistence(timeout: 5))
        let expected = fullAccessEnabled ? "1" : "0"
        if fullAccess.value as? String != expected {
            let toggle = fullAccess.switches.firstMatch
            if toggle.exists { toggle.tap() } else { fullAccess.tap() }
            if fullAccessEnabled {
                let allow = settings.buttons.matching(NSPredicate(format: "label == 'Allow' OR label == '允许'")).firstMatch
                if allow.waitForExistence(timeout: 3) { allow.tap() }
            }
        }
        XCTAssertEqual(fullAccess.value as? String, expected)
        let app = XCUIApplication(); app.activate()
        if freshHost { app.terminate();app.launch() }
        if learningFixture {
            let prepare = app.inputItem("prepare-learning-fixture")
            for _ in 0..<5 { if prepare.exists && prepare.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(prepare.waitForExistence(timeout: 5)); prepare.tap()
            XCTAssertEqual(app.staticTexts["learning-fixture-result"].label, "学习快照已准备")
            let checksumButton = app.inputItem("check-learning-checksum")
            keyboardReveal(checksumButton, in: app); checksumButton.tap()
            keyboardReveal(app.staticTexts["learning-checksum"], in: app)
            XCTAssertTrue(app.staticTexts["learning-checksum"].waitForExistence(timeout: 5))
            initialChecksum = app.staticTexts["learning-checksum"].label
            XCTAssertEqual(initialChecksum?.count, 64)
            for _ in 0..<3 { app.collectionViews.firstMatch.swipeDown() }
        }
        if networkLearning {
            // Read only. The archive must be the one written by the actual
            // containing-app network flow, not a synthetic replacement here.
            let checksum = app.inputItem("check-learning-checksum")
            keyboardReveal(checksum, in: app); checksum.tap()
            initialChecksum = app.staticTexts["learning-checksum"].label
            XCTAssertEqual(initialChecksum?.count, 64)
            for _ in 0..<3 { app.collectionViews.firstMatch.swipeDown() }
        }
        if verifySnapshot {
            let prepare = app.inputItem("prepare-snapshot")
            for _ in 0..<4 { if prepare.exists && prepare.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(prepare.waitForExistence(timeout: 5)); prepare.tap()
            XCTAssertEqual(app.staticTexts["snapshot-result"].label, "共享快照已准备")
            app.swipeDown()
        }
        let clear = app.inputItem("clear-sample")
        XCTAssertTrue(clear.waitForExistence(timeout: 10)); clear.tap()
        let field = app.descendants(matching: .any).matching(identifier: "sample-text").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap()
        // The dedicated simulator may show the stock keyboard's first-use
        // gesture tip. Dismiss that tip before opening its keyboard menu.
        let continueTip = app.inputItem("Continue")
        if continueTip.exists && continueTip.isHittable { continueTip.tap() }
        // Extension launch is asynchronous after focus/full-access changes.
        // Wait for an already selected keyboard before looking for a menu.
        if !app.inputItem("clear-composition").waitForExistence(timeout: 10) {
            let globe = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Next keyboard' OR label CONTAINS[c] 'Switch keyboard' OR identifier == 'switch-system-keyboard' OR label CONTAINS '下一个键盘' OR label CONTAINS '切换键盘' OR label == '🌐'")).firstMatch
            XCTAssertTrue(globe.waitForExistence(timeout: 5)); globe.press(forDuration: 1)
            let menuItems = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '灵鹤输入法'"))
            XCTAssertTrue(menuItems.firstMatch.waitForExistence(timeout: 5))
            // Exclude the containing app's navigation title with the same name.
            guard let ours = menuItems.allElementsBoundByIndex.first(where: { $0.isHittable && $0.frame.midY > app.frame.height / 2 }) else {
                XCTFail("Our keyboard must appear in the actual system keyboard menu"); return
            }
            ours.tap()
        }
        // Changing the system full-access switch invalidates the old extension
        // connection. Require the real keyboard, not just a tapped menu label.
        let keyboardReady = app.inputItem("clear-composition")
        if !keyboardReady.waitForExistence(timeout: 10) {
            for _ in 0..<3 {
                let next = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Next keyboard' OR label CONTAINS[c] 'Switch keyboard' OR identifier == 'switch-system-keyboard' OR label CONTAINS '下一个键盘' OR label CONTAINS '切换键盘' OR label == '🌐'")).firstMatch
                guard next.exists else { break }
                next.tap()
                if keyboardReady.waitForExistence(timeout: 5) { break }
            }
        }
        XCTAssertTrue(keyboardReady.exists, "Actual extension must load after the permission transition")
        print("KEYBOARD_GEOMETRY " + String(describing: keyboardReady.frame))
        let onscreen = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: keyboardReady)
        XCTAssertEqual(XCTWaiter.wait(for: [onscreen], timeout: 30), .completed, "Software keyboard must be visible before tapping keys")
        app.inputItem("clear-composition").tap()
        compositionPosition("拼音在键盘内",in:app)
        app.inputItem("keyboard-settings").tap()
        app.inputItem("布局与显示").tap();app.inputItem(chineseLayout == "nine" ? "中文九宫格" : "中文26键").tap()
        XCTAssertTrue(chineseLayout == "nine" ? app.inputItem("nine-2").exists : app.inputItem("key-n").exists)
        if sharedTextFixture {
            let open = app.inputItem("open-shared-text")
            XCTAssertTrue(open.waitForExistence(timeout: 5)); open.tap()
            let remote = app.staticTexts["SYNTHETIC-REMOTE-TEXT"]
            if fullAccessEnabled && !sharingPaused {
                XCTAssertTrue(remote.waitForExistence(timeout: 5))
                XCTAssertEqual(app.inputItem("close-shared-text").value as? String, "main-identity-blocked", "Keyboard must read only the separate local cache key")
                remote.tap(); XCTAssertEqual(field.value as? String, "SYNTHETIC-REMOTE-TEXT")
            } else {
                XCTAssertFalse(remote.exists)
                XCTAssertTrue(app.staticTexts["shared-text-status"].label.contains(fullAccessEnabled ? "暂停" : "完全访问"))
                app.inputItem("close-shared-text").tap()
                for key in ["n", "i", "h", "a", "o"] { app.inputItem("key-" + key).tap() }
                XCTAssertFalse(app.inputItem("open-shared-text").isHittable, "Text insertion must not discard unfinished composition")
                app.inputItem("key-你好").tap(); XCTAssertEqual(field.value as? String, "你好", "Denied clipboard permission must not break ordinary input")
            }
            let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.lifetime = .keepAlways; add(attachment)
            return
        }
        if learningFixture || networkLearning {
            app.inputItem("keyboard-settings").tap(); app.inputItem("词库与联想").tap();app.inputItem("刷新词库").tap()
        }
        if verifySnapshot {
            let probe = app.staticTexts["group-permission-probe"]
            XCTAssertTrue(probe.waitForExistence(timeout: 5))
            print("P1_PERMISSION_RESULT " + (probe.value as? String ?? "missing"))
            XCTAssertTrue(probe.label.contains("快照可读"), "Containing app snapshot must be readable from the actual keyboard")
            if fullAccessEnabled { XCTAssertTrue(probe.label.contains("写入允许")) }
            // Do not assert OS denial solely from Simulator. Record actual results;
            // the production path independently gates writes by hasFullAccess.
        }
        for key in (chineseLayout == "nine" ? ["6", "4", "4", "2", "6"] : ["n", "i", "h", "a", "o"]) {
            let b = app.inputItem((chineseLayout == "nine" ? "nine-" : "key-") + key); XCTAssertTrue(b.waitForExistence(timeout: 5)); b.tap()
            if (learningFixture || networkLearning) && key == "i" { XCTAssertFalse(app.inputItem("keyboard-settings").isHittable, "Settings must not discard an unfinished composition") }
        }
        let word = learningFixture || networkLearning ? "拟好" : "你好"
        let candidate = app.inputItem("key-" + word)
        XCTAssertTrue(candidate.waitForExistence(timeout: 8))
        if learningFixture || networkLearning { XCTAssertEqual(candidate.value as? String, "0", "Imported peer preference must become the first actual keyboard candidate") }
        candidate.tap()
        XCTAssertEqual(field.value as? String, word)
        if learningFixture || networkLearning {
            app.inputItem("keyboard-settings").tap(); app.inputItem("词库与联想").tap();app.inputItem("刷新词库").tap()
            let dismiss = app.inputItem("dismiss-keyboard")
            XCTAssertTrue(dismiss.waitForExistence(timeout: 5)); dismiss.tap()
            app.swipeUp()
            let check = app.inputItem("check-learning-checksum")
            keyboardReveal(check, in: app)
            XCTAssertTrue(check.waitForExistence(timeout: 5)); check.tap()
            keyboardReveal(app.staticTexts["learning-checksum"], in: app)
            XCTAssertEqual(app.staticTexts["learning-checksum"].label, initialChecksum, "No-full-access keyboard must not publish even when sharing is requested")
        }
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.lifetime = .keepAlways; add(attachment)
    }
}

extension XCUIApplication {
    // Native collection items are cells, regular keys remain UIButtons.
    func inputItem(_ identifier: String) -> XCUIElement { descendants(matching: .any).matching(identifier: identifier).firstMatch }
}
