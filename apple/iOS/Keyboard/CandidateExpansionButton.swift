import UIKit

/// The complete visible rectangle belongs to this control, including padding.
final class CandidateExpansionButton:UIButton {
    static let touchWidth: CGFloat = 56
    static func canToggle(expanded:Bool,choicesAvailable:Bool,hasComposition:Bool,deferred:Bool,english:Bool)->Bool {
        expanded || choicesAvailable || (!english && hasComposition && deferred)
    }
    override func point(inside point:CGPoint,with event:UIEvent?)->Bool {
        bounds.contains(point)
    }
}

/// Shared by the real keyboard and geometry probes. Expansion changes which
/// surfaces receive touches, never the footer/key-row layout or host height.
enum KeyboardCandidatePanelGeometry {
    static let candidateHeight: CGFloat = 44
    static let preeditHeight: CGFloat = 18
    static func headerHeight(inline: Bool) -> CGFloat { candidateHeight + (inline ? 0 : preeditHeight) }
    static func candidateTop(inline: Bool) -> CGFloat { inline ? 0 : preeditHeight }
    static func trailingReserve(width: CGFloat, deleteFrame: CGRect?) -> CGFloat {
        let minimum = CandidateExpansionButton.touchWidth + 4
        guard let deleteFrame, !deleteFrame.isEmpty, deleteFrame.minX >= 0 else { return minimum }
        return min(max(minimum, width - deleteFrame.minX + 4), max(minimum, width / 2))
    }
    static func apply(expanded: Bool, keyRegions: [UIView], retainedActions: UIView?, delete: UIButton?, footer: UIView) {
        footer.alpha = 1; footer.isUserInteractionEnabled = true; footer.accessibilityElementsHidden = false
        for region in keyRegions {
            if let retainedActions {
                let visible = !expanded || region === retainedActions
                region.alpha = visible ? 1 : 0; region.isUserInteractionEnabled = visible; region.accessibilityElementsHidden = !visible
            } else {
                // The 26-key delete lives inside its third row. Keep its real
                // ancestors laid out and hide only the other native buttons.
                region.alpha = 1; region.isUserInteractionEnabled = true; region.accessibilityElementsHidden = false
                hideButtons(in: region, expanded: expanded, except: delete)
            }
        }
    }
    private static func hideButtons(in view: UIView, expanded: Bool, except retained: UIButton?) {
        if let button = view as? UIButton {
            let visible = !expanded || button === retained
            button.alpha = visible ? 1 : 0; button.isUserInteractionEnabled = visible; button.accessibilityElementsHidden = !visible
            return
        }
        for child in view.subviews { hideButtons(in: child, expanded: expanded, except: retained) }
    }
}
