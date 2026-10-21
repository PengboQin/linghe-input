import SwiftUI
import UIKit

struct InputThemeModifier: ViewModifier {
    @State private var theme = KeyboardPreferences.appearanceTheme
    func body(content: Content) -> some View {
        content
            .preferredColorScheme(theme.mode.colorScheme)
            .tint(Color(uiColor: UIColor { traits in theme.palette(dark: traits.userInterfaceStyle == .dark).accent.uiColor }))
            .onAppear { KeyboardPreferences.observeUpdates(); theme = KeyboardPreferences.appearanceTheme }
            .onReceive(NotificationCenter.default.publisher(for: KeyboardPreferences.updated)) { _ in theme = KeyboardPreferences.appearanceTheme }
    }
}
