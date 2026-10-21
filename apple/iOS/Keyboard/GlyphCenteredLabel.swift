import UIKit
import CoreText

/// Full-width punctuation carries asymmetric font side bearings and baseline
/// space. Center its visible ink inside the existing fixed symbol slot.
final class GlyphCenteredLabel: UILabel {
    var centersVisibleGlyphs = false { didSet { if oldValue != centersVisibleGlyphs { setNeedsDisplay() } } }

    override func drawText(in rect: CGRect) {
        guard centersVisibleGlyphs, let context = UIGraphicsGetCurrentContext() else {
            super.drawText(in: rect)
            return
        }
        let value: NSAttributedString
        if let attributedText, attributedText.length > 0 {
            value = attributedText
        } else {
            let color = isHighlighted ? (highlightedTextColor ?? textColor ?? .label) : (textColor ?? .label)
            value = NSAttributedString(string: text ?? "", attributes: [.font: font ?? UIFont.systemFont(ofSize: 17), .foregroundColor: color])
        }
        let line = CTLineCreateWithAttributedString(value)
        let ink = CTLineGetImageBounds(line, nil)
        guard !ink.isNull, !ink.isEmpty, ink.width.isFinite, ink.height.isFinite else {
            super.drawText(in: rect)
            return
        }
        let scale = min(1, max(0, rect.width) / ink.width, max(0, rect.height) / ink.height)
        context.saveGState()
        context.translateBy(x: rect.midX, y: rect.midY)
        context.scaleBy(x: scale, y: -scale)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: -ink.midX, y: -ink.midY)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
