#if os(iOS)
import UIKit
import SwiftUI

extension InputTheme.Mode {
    var interfaceStyle: UIUserInterfaceStyle { switch self { case .system: return .unspecified; case .light: return .light; case .dark: return .dark } }
    var colorScheme: ColorScheme? { switch self { case .system: return nil; case .light: return .light; case .dark: return .dark } }
}
extension InputTheme.RGB {
    var uiColor: UIColor { .init(red: red, green: green, blue: blue, alpha: 1) }
}

/// Dynamic colors resolve using the receiving view's traits, never a cached host
/// keyboardAppearance. Preferences are read once per refresh, not once per label.
enum InputThemeColors {
    private(set) static var current = InputTheme()
    static func refresh(_ theme: InputTheme) { current = theme }
    private static func color(_ key: KeyPath<InputTheme.Palette, InputTheme.RGB>, lightDarkening: Double = 0) -> UIColor {
        UIColor { traits in
            let dark = traits.userInterfaceStyle == .dark
            let value = current.palette(dark: dark)[keyPath: key]
            // The native keyboard's light material is darker than an app page.
            // Preserve the shared hue while protecting text against its gray plate.
            return (!dark && lightDarkening > 0 ? value.blended(fraction: lightDarkening, with: .init(gray: 0)) : value).uiColor
        }
    }
    static var background: UIColor { color(\.background) }
    static var text: UIColor { color(\.text) }
    static var secondary: UIColor { color(\.secondary, lightDarkening: 1.0 / 6.0) }
    static var accent: UIColor { color(\.accent, lightDarkening: 0.12) }
    static var selection: UIColor { color(\.selection) }
    static var selectedText: UIColor { color(\.selectedText) }
    static var key: UIColor { color(\.key) }
    static var rail: UIColor { color(\.rail) }
}

#endif
