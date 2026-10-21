import UIKit
import XCTest

@MainActor final class InputThemeTests: XCTestCase {
    func testAllApplePalettesAndPressedStatesKeepTextReadable() {
        for accent in InputTheme.Accent.allCases {
            for dark in [false, true] {
                let p = InputTheme(accent: accent).palette(dark: dark)
                for surface in [p.background, p.key, p.rail, p.selection] {
                    XCTAssertGreaterThanOrEqual(p.text.contrast(with: surface), 4.5, "\(accent) \(dark)")
                    XCTAssertGreaterThanOrEqual(p.secondary.contrast(with: surface), 4.5, "\(accent) \(dark)")
                }
                XCTAssertGreaterThanOrEqual(p.accent.contrast(with: p.background), 4.5)
                XCTAssertGreaterThanOrEqual(p.selectedText.contrast(with: p.selection), 4.5)
            }
        }
    }
    func testNativeKeyboardPlateWorstCaseKeepsAllForegroundTextReadable() {
        defer { InputThemeColors.refresh(.init()) }
        func rgb(_ color: UIColor, _ traits: UITraitCollection) -> InputTheme.RGB {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, alpha: CGFloat = 0
            XCTAssertTrue(color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &alpha))
            XCTAssertEqual(alpha, 1)
            return .init(Double(r), Double(g), Double(b))
        }
        for accent in InputTheme.Accent.allCases {
            InputThemeColors.refresh(.init(accent: accent))
            for (style, surfaces) in [
                (UIUserInterfaceStyle.light, [InputTheme.RGB(gray: 0.80), .init(210.0 / 255, 212.0 / 255, 219.0 / 255)]),
                (.dark, [InputTheme.RGB(gray: 0.20)])
            ] {
                let traits = UITraitCollection(userInterfaceStyle: style)
                for surface in surfaces {
                    for foreground in [InputThemeColors.text, InputThemeColors.secondary, InputThemeColors.accent] {
                        XCTAssertGreaterThanOrEqual(rgb(foreground, traits).contrast(with: surface), 4.5, "\(accent) \(style)")
                    }
                }
            }
        }
    }
    func testPersistedThemeDefaultsAndEnumRoundTrip() throws {
        XCTAssertEqual(InputTheme(mode: nil, accent: nil), InputTheme())
        XCTAssertEqual(InputTheme(mode: "invalid", accent: "invalid"), InputTheme())
        for mode in InputTheme.Mode.allCases {
            for accent in InputTheme.Accent.allCases {
                let value = InputTheme(mode: mode, accent: accent)
                XCTAssertEqual(try JSONDecoder().decode(InputTheme.self, from: JSONEncoder().encode(value)), value)
                XCTAssertEqual(InputTheme(mode: mode.rawValue, accent: accent.rawValue), value)
            }
        }
    }
    @available(iOS 17.0, *)
    func testExplicitOppositeAppearanceThenSystemDoesNotRetainOverride() {
        let parent = UIViewController(), child = UIViewController()
        parent.loadViewIfNeeded(); parent.addChild(child); parent.view.addSubview(child.view); child.didMove(toParent: parent)
        parent.overrideUserInterfaceStyle = .light
        parent.updateTraitsIfNeeded(); parent.view.updateTraitsIfNeeded()
        XCTAssertEqual(parent.traitCollection.userInterfaceStyle, .light)
        KeyboardAppearanceSync.apply(to: child, mode: .dark)
        XCTAssertEqual(child.traitCollection.userInterfaceStyle, .dark)
        parent.overrideUserInterfaceStyle = .dark
        // Publish the host change before testing whether the child can inherit
        // it again. An unattached synthetic host otherwise keeps its old traits.
        parent.updateTraitsIfNeeded(); parent.view.updateTraitsIfNeeded()
        XCTAssertEqual(parent.traitCollection.userInterfaceStyle, .dark)
        XCTAssertEqual(parent.view.traitCollection.userInterfaceStyle, .dark)
        KeyboardAppearanceSync.apply(to: child, mode: .light)
        XCTAssertEqual(child.traitCollection.userInterfaceStyle, .light)
        child.view.isHidden = true
        KeyboardAppearanceSync.apply(to: child, mode: .system)
        XCTAssertEqual(child.overrideUserInterfaceStyle, .unspecified)
        XCTAssertEqual(child.traitCollection.userInterfaceStyle, .dark)
        parent.overrideUserInterfaceStyle = .light
        parent.updateTraitsIfNeeded(); parent.view.updateTraitsIfNeeded()
        KeyboardAppearanceSync.apply(to: child, mode: .system)
        XCTAssertEqual(child.traitCollection.userInterfaceStyle, .light)
        XCTAssertTrue(UIView.areAnimationsEnabled)
    }
    func testDynamicColorsAndSharedTextUseSelectedTheme() {
        defer { InputThemeColors.refresh(.init()) }
        for accent in InputTheme.Accent.allCases {
            let theme = InputTheme(accent: accent); InputThemeColors.refresh(theme)
            for (style, dark) in [(UIUserInterfaceStyle.light, false), (.dark, true)] {
                let traits = UITraitCollection(userInterfaceStyle: style)
                let expectedAccent = dark ? theme.palette(dark: true).accent : theme.palette(dark: false).accent.blended(fraction: 0.12, with: .init(gray: 0))
                XCTAssertEqual(InputThemeColors.accent.resolvedColor(with: traits), expectedAccent.uiColor)
                let panel = SharedTextPanel(); panel.loadViewIfNeeded(); panel.overrideUserInterfaceStyle = style; panel.applyTheme()
                XCTAssertEqual(panel.view.backgroundColor?.resolvedColor(with: traits).cgColor.alpha ?? 0, 0)
                let bars = [panel.navigationBar.standardAppearance, panel.navigationBar.scrollEdgeAppearance].compactMap { $0 }
                for bar in bars {
                    let color = bar.titleTextAttributes[.foregroundColor] as? UIColor
                    XCTAssertEqual(color?.resolvedColor(with: traits), theme.palette(dark: dark).text.uiColor)
                    XCTAssertEqual(bar.backgroundColor?.cgColor.alpha ?? 0, 0)
                }
            }
        }
    }
}
