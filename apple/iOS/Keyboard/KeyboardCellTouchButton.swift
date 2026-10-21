import UIKit

/// A native, transparent hit surface. UIScrollView can cancel its tracking when
/// a drag starts; only touch-up-inside performs the cell's current action.
final class KeyboardCellTouchButton: UIButton {
    var pressBegan: (() -> Void)?
    var activationSnapshot: (() -> (() -> Void)?)?
    var highlightChanged: ((Bool) -> Void)?
    private(set) var isHandlingControlTouch = false
    private var touchGeneration: UInt64 = 0
    private var pendingAction: (() -> Void)?
    override var isHighlighted: Bool { didSet { highlightChanged?(isHighlighted) } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.touchGeneration &+= 1
            self.isHandlingControlTouch = true
            let generation = self.touchGeneration
            self.pressBegan?()
            guard self.touchGeneration == generation else { return }
            self.pendingAction = self.activationSnapshot?()
        }, for: .touchDown)
        addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.isHandlingControlTouch = true
            let generation = self.touchGeneration
            let action = self.pendingAction
            self.pendingAction = nil
            action?()
            self.endControlTouch(generation: generation)
        }, for: .touchUpInside)
        addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.pendingAction = nil
            self.isHighlighted = false
            // UIKit may send touchCancel from cancelTracking itself. Calling
            // cancelTracking again from this action would recurse.
            self.endControlTouch(generation: self.touchGeneration)
        }, for: [.touchCancel, .touchUpOutside])
    }

    private func endControlTouch(generation: UInt64) {
        // UICollectionView's selection callback may follow the control event in
        // the same turn. Keep ownership until that turn is over, without an old
        // event clearing a new touch or a reused cell's state.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.touchGeneration == generation else { return }
            self.isHandlingControlTouch = false
        }
    }

    func resetTouchTracking() {
        touchGeneration &+= 1
        pendingAction = nil
        cancelTracking(with: nil)
        isHandlingControlTouch = false
        isHighlighted = false
    }

    override func cancelTracking(with event: UIEvent?) {
        pendingAction = nil
        super.cancelTracking(with: event)
        isHighlighted = false
    }

    required init?(coder: NSCoder) { fatalError() }
}
