import Foundation

/// One platform-neutral palette for the Apple apps and their keyboard surfaces.
/// Theme preferences stay local; neither surrounding text nor learning data lives here.
struct InputTheme: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case system, light, dark
        var id: Self { self }
        var title: String { switch self { case .system: return "跟随系统"; case .light: return "浅色"; case .dark: return "深色" } }
    }
    enum Accent: String, Codable, CaseIterable, Identifiable {
        case rose, amber, violet, graphite
        var id: Self { self }
        var title: String { switch self { case .rose: return "胭脂"; case .amber: return "琥珀"; case .violet: return "紫藤"; case .graphite: return "石墨" } }
        var color: RGB {
            switch self {
            case .rose: return .init(0.62, 0.18, 0.34)
            case .amber: return .init(0.53, 0.32, 0.06)
            case .violet: return .init(0.43, 0.27, 0.65)
            case .graphite: return .init(0.32, 0.35, 0.39)
            }
        }
    }
    struct RGB: Equatable {
        let red: Double, green: Double, blue: Double
        init(_ red: Double, _ green: Double, _ blue: Double) { self.red = red; self.green = green; self.blue = blue }
        init(gray: Double) { self.init(gray, gray, gray) }
        func blended(fraction: Double, with other: Self) -> Self {
            .init(red * (1 - fraction) + other.red * fraction,
                  green * (1 - fraction) + other.green * fraction,
                  blue * (1 - fraction) + other.blue * fraction)
        }
        var luminance: Double {
            func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
        func contrast(with other: Self) -> Double { (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05) }
    }
    struct Palette {
        let background, text, secondary, selection, selectedText, accent: RGB
        let key, rail: RGB
    }
    var mode: Mode = .system
    var accent: Accent = .rose
    init(mode: Mode = .system, accent: Accent = .rose) { self.mode = mode; self.accent = accent }
    init(mode: String?, accent: String?) { self.init(mode: mode.flatMap(Mode.init(rawValue:)) ?? .system, accent: accent.flatMap(Accent.init(rawValue:)) ?? .rose) }
    func palette(dark: Bool) -> Palette {
        let text = RGB(gray: dark ? 0.96 : 0.10)
        return .init(background: dark ? .init(0.10, 0.10, 0.11) : .init(gray: 1),
                     text: text, secondary: .init(gray: dark ? 0.76 : 0.36),
                     selection: accent.color.blended(fraction: dark ? 0.40 : 0.86, with: .init(gray: dark ? 0 : 1)),
                     selectedText: text,
                     accent: dark ? accent.color.blended(fraction: 0.55, with: .init(gray: 1)) : accent.color,
                     key: .init(gray: dark ? 0.20 : 1), rail: .init(gray: dark ? 0.14 : 0.94))
    }
}
