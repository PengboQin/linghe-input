import AppKit

/// Non-activating “已记住 X　撤销” card shown under the caret after a new phrase is
/// remembered. It never takes focus; the next keystroke, focus change or undo hides it.
final class MacPhraseNotice: NSObject {
    private final class NoticeWindow: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    private let window = NoticeWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let label = NSTextField(labelWithString: "")
    private let undo = NSButton(title: "撤销", target: nil, action: nil)
    private var onUndo: (() -> Void)?
    private(set) var phrase: String?

    override init() {
        super.init()
        window.level = .popUpMenu; window.isOpaque = false; window.backgroundColor = .clear
        window.hasShadow = true; window.hidesOnDeactivate = false; window.becomesKeyOnlyIfNeeded = true
        MacThemePreferences.apply(to: window)
        let surface = NSView(); surface.wantsLayer = true; surface.layer?.cornerRadius = 8
        label.font = .systemFont(ofSize: 13); label.lineBreakMode = .byTruncatingTail
        undo.bezelStyle = .inline; undo.font = .systemFont(ofSize: 13, weight: .medium)
        undo.target = self; undo.action = #selector(undoPressed); undo.setAccessibilityLabel("撤销记住的词")
        let stack = NSStackView(views: [label, undo]); stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor), stack.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: surface.topAnchor), stack.bottomAnchor.constraint(equalTo: surface.bottomAnchor)])
        window.contentView = surface
    }

    func show(phrase: String, caret: NSRect, onUndo: @escaping () -> Void) {
        self.phrase = phrase; self.onUndo = onUndo
        let palette = MacThemePreferences.current.palette(dark: NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        window.contentView?.layer?.backgroundColor = palette.background.cgColor
        label.stringValue = "已记住 " + phrase; label.textColor = .secondaryLabelColor
        window.contentView?.layoutSubtreeIfNeeded()
        let size = window.contentView?.fittingSize ?? NSSize(width: 160, height: 30)
        var origin = NSPoint(x: caret.minX, y: caret.minY - size.height - 6)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(caret.origin) }) ?? NSScreen.main {
            let frame = screen.visibleFrame
            origin.x = min(max(origin.x, frame.minX), frame.maxX - size.width)
            if origin.y < frame.minY { origin.y = caret.maxY + 6 }
        }
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        window.orderFrontRegardless()
    }

    func hide() { phrase = nil; onUndo = nil; window.orderOut(nil) }

    @objc private func undoPressed() { let action = onUndo; hide(); action?() }
}
