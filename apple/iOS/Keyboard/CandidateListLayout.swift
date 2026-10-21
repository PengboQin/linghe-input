import UIKit

/// Short words share an aligned row. A phrase owns its row, so wrapping text
/// never creates the uneven multi-column blocks of a flow layout.
final class CandidateListLayout: UICollectionViewLayout {
    static let horizontalMargin: CGFloat = 6
    static func font(at index:Int,traits:UITraitCollection)->UIFont {
        UIFontMetrics(forTextStyle:.body).scaledFont(for:.systemFont(ofSize:20,weight:index==0 ? .medium:.regular),maximumPointSize:26,compatibleWith:traits)
    }
    var controlHeight: CGFloat = 64 {
        didSet {if oldValue != controlHeight {invalidateLayout()}}
    }
    var textAt: ((Int) -> String)?
    private var items: [UICollectionViewLayoutAttributes] = []
    private var size = CGSize.zero
    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let width = max(1, collectionView.bounds.width)
        let margin = min(Self.horizontalMargin, max(0, (width - 1) / 2))
        let contentWidth = max(1, width - margin * 2), slot = contentWidth / 4
        let rowHeight=max(44,ceil(Self.font(at:0,traits:collectionView.traitCollection).lineHeight)+16)
        var y: CGFloat = 0, column = 0
        items = []
        for index in 0..<collectionView.numberOfItems(inSection: 0) {
            let text = textAt?(index) ?? ""
            let font = Self.font(at:index,traits:collectionView.traitCollection)
            let needed = (text as NSString).size(withAttributes: [.font: font]).width + 20
            let span = needed <= slot ? 1:2
            let long = needed > slot * 2 || text.contains("\n")
            let frame: CGRect
            if long {
                if column > 0 { y += rowHeight; column = 0 }
                // Every row intersecting the fixed control height reserves it;
                // lower rows use the full width within the same margins.
                let available = y < controlHeight ? max(1, contentWidth - CandidateExpansionButton.touchWidth - 4) : contentWidth
                let bounds = (text as NSString).boundingRect(with: CGSize(width: max(1, available - 20), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil)
                let height = max(rowHeight, ceil(bounds.height) + 16)
                frame = CGRect(x: margin, y: y, width: available, height: height); y += height
            } else {
                if column + span > (y < controlHeight ? 3 : 4) { y += rowHeight; column = 0 }
                frame = CGRect(x: margin + CGFloat(column) * slot, y: y, width: slot * CGFloat(span), height: rowHeight)
                column += span
                if column == (y < controlHeight ? 3 : 4) { y += rowHeight; column = 0 }
            }
            let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
            attributes.frame = frame; items.append(attributes)
        }
        size = CGSize(width: width, height: y + (column > 0 ? rowHeight : 0))
    }
    override var collectionViewContentSize: CGSize { size }
    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? { items.filter { $0.frame.intersects(rect) } }
    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? { items.indices.contains(indexPath.item) ? items[indexPath.item] : nil }
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { newBounds.width != collectionView?.bounds.width }
}
