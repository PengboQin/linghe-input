import UIKit
import XCTest

@MainActor final class KeyboardHeightPreviewTests: XCTestCase {
    func testDoneCommitsLatestSliderValueBeforePendingPreview() throws {
        let view=KeyboardHeightAdjustmentView()
        let slider=try XCTUnwrap(view.subviews.compactMap{$0 as? UISlider}.first)
        let done=try XCTUnwrap(view.subviews.compactMap{$0 as? UIButton}.first)
        var changes:[(Double,Bool)]=[];var completed=0
        view.change={changes.append(($0,$1))};view.done={completed+=1}
        view.update(48);slider.value=67.1;slider.sendActions(for:.valueChanged)
        done.sendActions(for:.touchUpInside)
        XCTAssertEqual(changes.count,1);XCTAssertEqual(changes[0].0,68);XCTAssertTrue(changes[0].1);XCTAssertEqual(completed,1)
    }
    func testInputViewHasSavedHeightBeforeFirstLayoutOrWindowAttachment() {
        for height:CGFloat in [236,252,284,308,332] {
            let keyboard=KeyboardInputView(contentHeight:height)
            XCTAssertNil(keyboard.window)
            XCTAssertEqual(keyboard.intrinsicContentSize.height,height)
            keyboard.layoutIfNeeded()
            XCTAssertEqual(keyboard.intrinsicContentSize.height,height)
        }
    }
    func testSliderPreviewCoalescesAndEndPersistsLatestWithoutLateReplay() throws {
        let view=KeyboardHeightAdjustmentView()
        let slider=try XCTUnwrap(view.subviews.compactMap{$0 as? UISlider}.first)
        var changes:[(Double,Bool)]=[]
        view.change={changes.append(($0,$1))}
        for value:Float in [4,12,20,48,76] {slider.value=value;slider.sendActions(for:.valueChanged)}
        XCTAssertTrue(changes.isEmpty,"No geometry or defaults work for each incoming pixel event")
        let preview=expectation(description:"Coalesced preview")
        DispatchQueue.main.asyncAfter(deadline:.now()+0.07) {preview.fulfill()}
        wait(for:[preview],timeout:1)
        XCTAssertEqual(changes.count,1);XCTAssertEqual(changes[0].0,76);XCTAssertFalse(changes[0].1)
        slider.value=84;slider.sendActions(for:.valueChanged)
        slider.value=92;slider.sendActions(for:.touchUpInside)
        XCTAssertEqual(changes.count,2);XCTAssertEqual(changes[1].0,92);XCTAssertTrue(changes[1].1)
        let settle=expectation(description:"No stale preview after final save")
        DispatchQueue.main.asyncAfter(deadline:.now()+0.07) {settle.fulfill()}
        wait(for:[settle],timeout:1)
        XCTAssertEqual(changes.count,2)
    }
    func testCancelledPreviewCannotConsumeNextDrag() throws {
        let view=KeyboardHeightAdjustmentView(),slider=try XCTUnwrap(view.subviews.compactMap{$0 as? UISlider}.first)
        var changes:[(Double,Bool)]=[];view.change={changes.append(($0,$1))}
        slider.value=20;slider.sendActions(for:.valueChanged)
        slider.sendActions(for:.touchCancel)
        slider.value=72;slider.sendActions(for:.valueChanged)
        let settle=expectation(description:"Next drag preview")
        DispatchQueue.main.asyncAfter(deadline:.now()+0.07) {settle.fulfill()}
        wait(for:[settle],timeout:1)
        XCTAssertEqual(changes.count,2);XCTAssertTrue(changes[0].1)
        XCTAssertEqual(changes[1].0,72);XCTAssertFalse(changes[1].1)
    }
}
