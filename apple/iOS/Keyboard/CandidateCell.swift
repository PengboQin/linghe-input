import UIKit

/// Full-sized tap target, rounded pressed surface and a compact native edit
/// menu for word management; no context-menu lift or full-keyboard dark preview.
final class CandidateCell: UICollectionViewCell, UIEditMenuInteractionDelegate {
    let label = GlyphCenteredLabel()
    var activate: (() -> Void)?
    var pressBegan: (() -> Void)?
    var contextMenuProvider: (() -> UIMenu?)?
    private let touchButton = KeyboardCellTouchButton(frame: .zero)
    private lazy var editMenu=UIEditMenuInteraction(delegate:self)
    private var menuSnapshot: UIMenu?
    private var menuGeneration: UInt64 = 0
    var isHandlingControlTouch: Bool { touchButton.isHandlingControlTouch }
    func cancelPendingControlActivation() { touchButton.resetTouchTracking() }
    var normalBackground: UIColor = .clear
    var emphasizes = false
    private let selectionSurface = UIView()
    private let surfaceInset: CGFloat = 2
    private let surfaceRadius: CGFloat = 8

    override var isHighlighted: Bool { didSet { applyTheme() } }

    func applyTheme() {
        label.textColor = isHighlighted ? InputThemeColors.selectedText : (emphasizes ? InputThemeColors.accent : InputThemeColors.text)
        selectionSurface.backgroundColor = isHighlighted ? InputThemeColors.selection : normalBackground
    }

    override func accessibilityActivate() -> Bool { pressBegan?(); activate?(); return true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .button
        backgroundColor = .clear
        clipsToBounds = true
        contentView.backgroundColor = .clear
        contentView.clipsToBounds = true
        selectionSurface.isUserInteractionEnabled = false
        selectionSurface.layer.cornerRadius = surfaceRadius
        selectionSurface.layer.cornerCurve = .continuous
        selectionSurface.clipsToBounds = true
        contentView.addSubview(selectionSurface)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = InputThemeColors.text
        label.textAlignment = .center
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: contentView.topAnchor),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        touchButton.translatesAutoresizingMaskIntoConstraints = false
        touchButton.pressBegan = { [weak self] in self?.pressBegan?() }
        touchButton.activationSnapshot = { [weak self] in self?.activate }
        touchButton.highlightChanged = { [weak self] in self?.isHighlighted = $0 }
        touchButton.addInteraction(editMenu)
        let hold=UILongPressGestureRecognizer(target:self,action:#selector(showCandidateMenu(_:)))
        hold.minimumPressDuration=0.45;hold.allowableMovement=12;hold.cancelsTouchesInView=true
        touchButton.addGestureRecognizer(hold)
        contentView.addSubview(touchButton)
        NSLayoutConstraint.activate([
            touchButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            touchButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            touchButton.topAnchor.constraint(equalTo: contentView.topAnchor),
            touchButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        selectionSurface.frame = contentView.bounds.insetBy(dx: surfaceInset, dy: surfaceInset)
    }

    /// Anchor only the visible portion of this cell, never a lifted snapshot of
    /// the full, potentially 800pt-wide transparent candidate content.
    func candidateMenuSourceRect() -> CGRect {
        guard window != nil,contentView.window != nil else{return .null}
        layoutIfNeeded();var visible=selectionSurface.frame
        var ancestor=contentView.superview
        while let container=ancestor {
            if container.clipsToBounds {visible=visible.intersection(contentView.convert(container.bounds,from:container))}
            ancestor=container.superview
        }
        return visible.isNull || visible.isEmpty ? .null:visible
    }
    func prepareCandidateMenu() -> UIMenu? {
        guard let menu=contextMenuProvider?() else{return nil}
        pressBegan?();cancelPendingControlActivation();isHighlighted=false
        menuGeneration &+= 1;menuSnapshot=menu
        return menu
    }
    @objc private func showCandidateMenu(_ hold: UILongPressGestureRecognizer) {
        guard hold.state == .began,!candidateMenuSourceRect().isNull,let menu=prepareCandidateMenu() else{return}
        _=menu
        let rect=candidateMenuSourceRect()
        let configuration=UIEditMenuConfiguration(identifier:NSNumber(value:menuGeneration),sourcePoint:CGPoint(x:rect.midX,y:rect.midY))
        editMenu.presentEditMenu(with:configuration)
    }
    func dismissCandidateMenu() {
        menuGeneration &+= 1;menuSnapshot=nil;editMenu.dismissMenu()
        cancelPendingControlActivation();isHighlighted=false
    }
    func editMenuInteraction(_ interaction:UIEditMenuInteraction,menuFor configuration:UIEditMenuConfiguration,suggestedActions:[UIMenuElement])->UIMenu? {
        guard (configuration.identifier as? NSNumber)?.uint64Value==menuGeneration else{return nil}
        return menuSnapshot
    }
    func editMenuInteraction(_ interaction:UIEditMenuInteraction,targetRectFor configuration:UIEditMenuConfiguration)->CGRect {candidateMenuSourceRect()}
    func editMenuInteraction(_ interaction:UIEditMenuInteraction,willDismissMenuFor configuration:UIEditMenuConfiguration,animator:UIEditMenuInteractionAnimating) {
        let generation=(configuration.identifier as? NSNumber)?.uint64Value
        animator.addCompletion { [weak self] in
            guard let self,generation==self.menuGeneration else{return}
            self.menuSnapshot=nil;self.cancelPendingControlActivation();self.isHighlighted=false
        }
    }
    override func didMoveToWindow() {
        super.didMoveToWindow();if window == nil {dismissCandidateMenu()}
    }

    override func prepareForReuse() {
        super.prepareForReuse();dismissCandidateMenu()
        activate = nil
        pressBegan = nil
        contextMenuProvider = nil
        touchButton.resetTouchTracking()
        isHighlighted = false
        normalBackground = .clear
        emphasizes = false
        label.centersVisibleGlyphs = false
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }
}

