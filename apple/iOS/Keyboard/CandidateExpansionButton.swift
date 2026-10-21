import UIKit

/// The complete visible rectangle belongs to this control, including padding.
final class CandidateExpansionButton:UIButton {
    static let touchWidth: CGFloat = 56
    override func point(inside point:CGPoint,with event:UIEvent?)->Bool {
        bounds.contains(point)
    }
}
