import AppKit
import SwiftUI

struct MacTheme: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case system, light, dark
        var id: Self { self }
        var title: String { switch self {case .system: return "跟随系统"; case .light: return "浅色"; case .dark: return "深色"} }
        var appearance: NSAppearance? {
            switch self {case .system: return nil; case .light: return NSAppearance(named: .aqua); case .dark: return NSAppearance(named: .darkAqua)}
        }
    }
    enum Accent: String, Codable, CaseIterable, Identifiable {
        case rose, amber, violet, graphite
        var id: Self { self }
        var title: String {switch self {case .rose: return "胭脂"; case .amber: return "琥珀"; case .violet: return "紫藤"; case .graphite: return "石墨"}}
        var color: NSColor { InputTheme.Accent(rawValue:rawValue)!.color.nsColor }
    }
    var mode: Mode = .system
    var accent: Accent = .rose
    func palette(dark: Bool) -> MacThemePalette { .init(theme:InputTheme(mode:mode.rawValue,accent:accent.rawValue),dark:dark) }
}

struct MacThemePalette {
    let background, text, secondary, selection, selectedText, accent: NSColor
    init(theme:InputTheme,dark:Bool) {
        let palette=theme.palette(dark:dark)
        background=palette.background.nsColor;text=palette.text.nsColor;secondary=palette.secondary.nsColor
        selection=palette.selection.nsColor;selectedText=palette.selectedText.nsColor;accent=palette.accent.nsColor
    }
}

private extension InputTheme.RGB {
    var nsColor:NSColor {NSColor(srgbRed:red,green:green,blue:blue,alpha:1)}
}

enum MacThemePreferences {
    static let updated = Notification.Name("PrivateInputMacThemeUpdated")
    static let key = "mac-appearance-v1"
    static func read(from store: UserDefaults = .standard) -> MacTheme {
        guard let data=store.data(forKey:key), data.count<=512,
              let value=try? JSONDecoder().decode(MacTheme.self,from:data) else {return .init()}
        return value
    }
    static func write(_ value: MacTheme, to store: UserDefaults = .standard) {
        guard let data=try? JSONEncoder().encode(value) else {return}
        store.set(data,forKey:key)
        NotificationCenter.default.post(name:updated,object:nil)
    }
    static var current: MacTheme {read()}
    static func apply(to window: NSWindow) {window.appearance=current.mode.appearance}
}

struct MacAppearanceSettings: View {
    @State private var theme=MacThemePreferences.current
    var body: some View {
        Section("外观") {
            Picker("明暗模式",selection:Binding(get:{theme.mode},set:{theme.mode=$0;MacThemePreferences.write(theme)})) {
                ForEach(MacTheme.Mode.allCases) {Text($0.title).tag($0)}
            }.accessibilityIdentifier("mac-theme-mode")
            Picker("主题色",selection:Binding(get:{theme.accent},set:{theme.accent=$0;MacThemePreferences.write(theme)})) {
                ForEach(MacTheme.Accent.allCases) {accent in
                    Label {Text(accent.title)} icon: {Image(systemName:"circle.fill").foregroundStyle(Color(nsColor:accent.color))}.tag(accent)
                }
            }.accessibilityIdentifier("mac-theme-accent")
        }.onReceive(NotificationCenter.default.publisher(for:MacThemePreferences.updated)) {_ in theme=MacThemePreferences.current}
    }
}
