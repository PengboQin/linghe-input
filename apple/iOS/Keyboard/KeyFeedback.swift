import UIKit

final class FeedbackButton: UIButton {
    var feedback: ((FeedbackButton, Bool) -> Void)?
    var accessibilityAction: (() -> Void)?
    override func accessibilityActivate() -> Bool {
        if let accessibilityAction { accessibilityAction(); return true }
        return super.accessibilityActivate()
    }
    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            backgroundColor = isHighlighted ? InputThemeColors.selection : normalBackground
            feedback?(self, isHighlighted)
        }
    }
    var normalBackground: UIColor = .clear
    func applyTheme() {
        tintColor = InputThemeColors.text
        setTitleColor(InputThemeColors.text, for: .normal)
        setTitleColor(InputThemeColors.selectedText, for: .highlighted)
        normalBackground = InputThemeColors.key
        backgroundColor = isHighlighted ? InputThemeColors.selection : normalBackground
    }
}

// Keep flat rail/function styling while the button owns its press feedback.
extension UIButton {
    func normalBackgroundIfFeedback(_ color: UIColor) {
        backgroundColor = color; (self as? FeedbackButton)?.normalBackground = color
    }
}
