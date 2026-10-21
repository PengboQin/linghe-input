import Foundation

// One value for every layout. Compact keyboards use half the added height so
// landscape keeps a useful amount of the document visible.
enum KeyboardHeight {
    static let presets: [(title: String, extra: Double)] = [("矮", 0), ("中", 48), ("高", 96)]
    static let defaultExtra: Double = 48
    static func normalized(_ extra: Double) -> Double {
        guard extra.isFinite else { return defaultExtra }
        return (min(96, max(0, extra)) / 4).rounded() * 4
    }
    static func height(extra: Double, compact: Bool, tablet: Bool, viewportHeight: Double) -> Double {
        let base: Double = compact ? 164 : (tablet ? 264 : 232)
        let requested = base + normalized(extra) * (compact ? 0.5 : 1)
        return min(requested, max(base, min(420, viewportHeight * 0.58)))
    }
}
