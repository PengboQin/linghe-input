import UIKit

// No nested controls: the native collection view owns the whole rail, including
// the glyphs, spacing and edges. A pan cancels cell selection automatically.
final class KeyboardRailView: UICollectionView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    struct Item: Equatable {
        let id: String
        let title: String
        var selected = false
    }
    private var items: [Item] = []
    private var rowHeight: CGFloat = 44
    private var fontSize: CGFloat = 20
    private var glyphCentered = false
    private var layoutWidth: CGFloat = 0
    var select: ((Int) -> Void)? {
        didSet {
            for case let cell as RailCell in visibleCells {
                if let index = indexPath(for: cell)?.item { bindActivation(cell, index: index) }
            }
        }
    }
    var press: (() -> Void)?
    private var controlSelectionInFlight = false
    private var controlSelectionGeneration: UInt64 = 0
    private func bindActivation(_ cell: RailCell, index: Int) {
        let selection = select
        cell.activate = { [weak self] in
            guard let self else { return }
            self.markControlSelectionEvent()
            selection?(index)
        }
    }
    private func markControlSelectionEvent() {
        controlSelectionGeneration &+= 1
        let generation = controlSelectionGeneration
        controlSelectionInFlight = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.controlSelectionGeneration == generation else { return }
            self.controlSelectionInFlight = false
        }
    }
    #if targetEnvironment(simulator)
    private var debugBegins = 0
    private var debugEnds = 0
    private var debugPoint = CGPoint.zero
    func recordHit(_ point: CGPoint) { debugPoint = point; reportScroll() }
    private func reportScroll() {
        let value: [String: Any] = ["offset": Int(contentOffset.y), "begins": debugBegins, "ends": debugEnds, "hitX": debugPoint.x, "hitY": debugPoint.y, "dragging": isDragging, "decelerating": isDecelerating]
        if let data = try? JSONSerialization.data(withJSONObject:value), let text = String(data:data,encoding:.utf8) { accessibilityValue=text }
    }
    #endif
    init() {
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 0; layout.minimumInteritemSpacing = 0
        super.init(frame: .zero, collectionViewLayout: layout)
        backgroundColor = InputThemeColors.rail; clipsToBounds = true
        dataSource = self; delegate = self
        delaysContentTouches = false; canCancelContentTouches = true
        alwaysBounceVertical = true; alwaysBounceHorizontal = false
        // The narrow rail is the drag surface, including its rightmost pixels;
        // don't let a scroll-indicator scrub gesture take that edge over.
        showsVerticalScrollIndicator = false; showsHorizontalScrollIndicator = false
        decelerationRate = .fast
        contentInsetAdjustmentBehavior = .never
        isDirectionalLockEnabled = true
        register(RailCell.self, forCellWithReuseIdentifier: "rail")
        if #available(iOS 26.0, *) { topEdgeEffect.isHidden = true; bottomEdgeEffect.isHidden = true }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func touchesShouldCancel(in view: UIView) -> Bool { view is UIControl || super.touchesShouldCancel(in: view) }
    func update(_ values: [Item], height: CGFloat, font: CGFloat, reset: Bool = true, glyphCentered: Bool = false) {
        guard values != items || height != rowHeight || font != fontSize || glyphCentered != self.glyphCentered else { return }
        items = values; rowHeight = height; fontSize = font; self.glyphCentered = glyphCentered
        reloadData(); collectionViewLayout.invalidateLayout()
        if reset { setContentOffset(.zero, animated: false) }
    }
    func applyTheme() {
        backgroundColor = InputThemeColors.rail
        for (index, cell) in visibleCells.compactMap({ $0 as? RailCell }).map({ (indexPath(for: $0)?.item, $0) }) {
            cell.label.textColor = InputThemeColors.text
            cell.selectedBackground = index.flatMap { items.indices.contains($0) ? items[$0].selected : nil } == true ? InputThemeColors.selection : .clear
            cell.updateBackground()
        }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if abs(layoutWidth - bounds.width) > 0.5 { layoutWidth = bounds.width; collectionViewLayout.invalidateLayout() }
    }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { items.count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = dequeueReusableCell(withReuseIdentifier: "rail", for: indexPath) as! RailCell
        let item = items[indexPath.item]
        cell.label.text = item.title; cell.label.textColor = InputThemeColors.text; cell.label.font = .systemFont(ofSize: fontSize)
        cell.label.centersVisibleGlyphs = glyphCentered
        cell.accessibilityIdentifier = item.id; cell.accessibilityLabel = item.title
        cell.accessibilityTraits = item.selected ? [.button, .selected] : .button
        cell.selectedBackground = item.selected ? InputThemeColors.selection : .clear
        bindActivation(cell, index: indexPath.item)
        cell.pressBegan = { [weak self] in
            guard let self else { return }
            self.markControlSelectionEvent()
            self.press?()
        }
        cell.updateBackground()
        return cell
    }
    func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        CGSize(width: max(1, bounds.width), height: rowHeight)
    }
    func collectionView(_ collectionView: UICollectionView, didHighlightItemAt indexPath: IndexPath) { press?() }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        deselectItem(at: indexPath, animated: false)
        guard !controlSelectionInFlight else { return }
        guard let cell = cellForItem(at: indexPath) as? RailCell, !cell.isHandlingControlTouch else { return }
        cell.activate?()
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        #if targetEnvironment(simulator)
        reportScroll()
        #endif
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        #if targetEnvironment(simulator)
        debugBegins += 1; reportScroll()
        #endif
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        #if targetEnvironment(simulator)
        debugEnds += 1; reportScroll()
        DispatchQueue.main.async { [weak self] in self?.reportScroll() }
        #endif
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        #if targetEnvironment(simulator)
        reportScroll()
        #endif
    }
}

private final class RailCell: UICollectionViewCell {
    let label = GlyphCenteredLabel()
    private let selectionSurface = UIView()
    var activate: (() -> Void)?
    var pressBegan: (() -> Void)?
    private let touchButton = KeyboardCellTouchButton(frame: .zero)
    var isHandlingControlTouch: Bool { touchButton.isHandlingControlTouch }
    var selectedBackground: UIColor = .clear
    override var isHighlighted: Bool { didSet { updateBackground() } }
    override func accessibilityActivate() -> Bool { pressBegan?(); activate?(); return true }
    func updateBackground() {
        selectionSurface.backgroundColor = isHighlighted ? InputThemeColors.selection : selectedBackground
        label.textColor = isHighlighted ? InputThemeColors.selectedText : InputThemeColors.text
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true; accessibilityTraits = .button
        backgroundColor = .clear; contentView.backgroundColor = .clear
        clipsToBounds = true; contentView.clipsToBounds = true
        selectionSurface.layer.cornerRadius = 6; selectionSurface.layer.cornerCurve = .continuous
        selectionSurface.clipsToBounds = true; selectionSurface.isUserInteractionEnabled = false
        contentView.addSubview(selectionSurface)
        label.textColor = InputThemeColors.text; label.textAlignment = .center
        label.isUserInteractionEnabled = false
        label.adjustsFontSizeToFitWidth = true; label.minimumScaleFactor = 0.75
        label.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -2),
            label.topAnchor.constraint(equalTo: contentView.topAnchor),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        touchButton.translatesAutoresizingMaskIntoConstraints = false
        touchButton.pressBegan = { [weak self] in self?.pressBegan?() }
        touchButton.activationSnapshot = { [weak self] in self?.activate }
        touchButton.highlightChanged = { [weak self] in self?.isHighlighted = $0 }
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
        selectionSurface.frame = contentView.bounds.insetBy(dx: 2, dy: 2)
    }
    override func prepareForReuse() {
        super.prepareForReuse()
        activate = nil; isHighlighted = false; selectedBackground = .clear
        pressBegan = nil; touchButton.resetTouchTracking()
        label.centersVisibleGlyphs = false
        updateBackground()
    }
    required init?(coder: NSCoder) { fatalError() }
}
