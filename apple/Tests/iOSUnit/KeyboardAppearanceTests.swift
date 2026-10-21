import UIKit
import XCTest

@available(iOS 17.0, *)
@MainActor final class KeyboardAppearanceTests: XCTestCase {
    func testHiddenControllerDropsPreviousHostOverrideBeforeShowing() {
        let parent=UIViewController(),child=UIViewController()
        parent.loadViewIfNeeded();parent.addChild(child);parent.view.addSubview(child.view);child.didMove(toParent:parent)
        parent.overrideUserInterfaceStyle = .dark;child.overrideUserInterfaceStyle = .dark
        XCTAssertEqual(child.traitCollection.userInterfaceStyle,.dark)
        child.view.isHidden=true;parent.overrideUserInterfaceStyle = .light;parent.updateTraitsIfNeeded();parent.view.updateTraitsIfNeeded()
        KeyboardAppearanceSync.apply(to:child)
        XCTAssertEqual(child.overrideUserInterfaceStyle,.unspecified)
        XCTAssertEqual(child.traitCollection.userInterfaceStyle,.light)
        child.view.isHidden=false
        XCTAssertEqual(child.traitCollection.userInterfaceStyle,.light)
    }
    func testHostAppearanceChangesReachChildColorsWithoutPinnedOverride() {
        let parent=UIViewController(),child=UIViewController()
        parent.loadViewIfNeeded();parent.addChild(child);parent.view.addSubview(child.view);child.didMove(toParent:parent)
        let label=UILabel();label.textColor = .label;child.view.addSubview(label)
        parent.overrideUserInterfaceStyle = .dark;parent.updateTraitsIfNeeded();parent.view.updateTraitsIfNeeded();KeyboardAppearanceSync.apply(to:child)
        XCTAssertEqual(label.traitCollection.userInterfaceStyle,.dark)
        parent.overrideUserInterfaceStyle = .light;parent.updateTraitsIfNeeded();parent.view.updateTraitsIfNeeded();KeyboardAppearanceSync.apply(to:child)
        XCTAssertEqual(label.traitCollection.userInterfaceStyle,.light)
        parent.overrideUserInterfaceStyle = .dark;parent.updateTraitsIfNeeded();parent.view.updateTraitsIfNeeded();KeyboardAppearanceSync.apply(to:child)
        XCTAssertEqual(label.traitCollection.userInterfaceStyle,.dark)
        XCTAssertEqual(child.overrideUserInterfaceStyle,.unspecified)
        XCTAssertEqual(child.view.overrideUserInterfaceStyle,.unspecified)
        XCTAssertTrue(UIView.areAnimationsEnabled)
    }
}
