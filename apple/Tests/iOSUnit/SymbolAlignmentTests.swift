import UIKit
import XCTest

@MainActor final class SymbolAlignmentTests: XCTestCase {
    func testMixedPunctuationInkIsCenteredInFixedSlots() throws {
        for symbol in [",", "，", "。", "、", ":", "：", ".", "@", "(", ")", "（", "）", "……", "?", "！", "+", "÷", "￥", "%", "[", "]", "「", "」", "《", "》"] {
            for size in [CGSize(width: 48, height: 32), CGSize(width: 76, height: 44)] {
                let label = GlyphCenteredLabel(frame: CGRect(origin: .zero, size: size))
                label.centersVisibleGlyphs = true
                label.font = .systemFont(ofSize: 19)
                label.textColor = .black
                label.text = symbol
                let ink = try renderedInkBounds(label)
                XCTAssertEqual(ink.midX, size.width / 2, accuracy: 1, symbol)
                XCTAssertEqual(ink.midY, size.height / 2, accuracy: 1, symbol)
                XCTAssertTrue(label.bounds.contains(ink), symbol)
            }
        }
    }

    func testRailSlotsRemainFixedAcrossPortraitLandscapeAndScrolling() throws {
        let values = ["，", "。", "、", ":", "(", ")", "@", ".", "[", "]", "？", "！"]
        for keyboardWidth: CGFloat in [320, 393] {
            let host = UIView(frame: CGRect(x: 0, y: 0, width: keyboardWidth, height: 240))
            let rail = KeyboardRailView()
            host.addSubview(rail)
            rail.update(values.map { .init(id: $0, title: $0) }, height: 32, font: 19, glyphCentered: true)
            for height: CGFloat in [192, 112, 192] {
                rail.frame = CGRect(x: 0, y: 0, width: 48, height: height)
                rail.layoutIfNeeded()
                for index in values.indices {
                    let attributes = try XCTUnwrap(rail.collectionViewLayout.layoutAttributesForItem(at: IndexPath(item: index, section: 0)))
                    XCTAssertEqual(attributes.frame, CGRect(x: 0, y: CGFloat(index) * 32, width: 48, height: 32))
                }
                rail.contentOffset.y = 64
                rail.layoutIfNeeded()
                for point in [CGPoint(x: 1, y: 65), CGPoint(x: 24, y: 80), CGPoint(x: 47, y: 95)] {
                    XCTAssertNotNil(rail.hitTest(point, with: nil), "Glyphs and gaps must remain inside the scroll surface")
                }
                XCTAssertTrue(rail.panGestureRecognizer.isEnabled)
                XCTAssertTrue(rail.canCancelContentTouches)
            }
        }
    }

    func testPinyinAndCategoryLabelsKeepNormalTypography() throws {
        let rail = KeyboardRailView()
        rail.frame = CGRect(x: 0, y: 0, width: 48, height: 200)
        rail.update([.init(id: "pinyin-d", title: "d"), .init(id: "pinyin-dui", title: "dui")], height: 44, font: 15)
        rail.layoutIfNeeded()
        let first = try XCTUnwrap(rail.cellForItem(at: IndexPath(item: 0, section: 0)))
        let label = try XCTUnwrap(first.contentView.subviews.compactMap { $0 as? GlyphCenteredLabel }.first)
        XCTAssertFalse(label.centersVisibleGlyphs)
        XCTAssertFalse(label.isUserInteractionEnabled)
    }

    func testRailNativeControlOwnsItsEdgesAndScrollCanCancelIt() throws {
        let rail = KeyboardRailView()
        rail.frame = CGRect(x: 0, y: 0, width: 48, height: 160)
        rail.update([.init(id: "symbol-dot", title: ".")], height: 32, font: 19, glyphCentered: true)
        rail.layoutIfNeeded()
        let cell = try XCTUnwrap(rail.cellForItem(at: IndexPath(item: 0, section: 0)))
        let button = try XCTUnwrap(cell.hitTest(CGPoint(x: 1, y: 16), with: nil) as? UIButton)
        XCTAssertTrue(rail.touchesShouldCancel(in: button))
        XCTAssertFalse(rail.delaysContentTouches)
        XCTAssertTrue(rail.canCancelContentTouches)
        XCTAssertFalse(button.isAccessibilityElement)
        var presses = 0, commits = 0
        rail.press = { presses += 1 }
        rail.select = { _ in commits += 1 }
        button.sendActions(for: .touchDown)
        button.sendActions(for: .touchCancel)
        XCTAssertEqual(presses, 1)
        XCTAssertEqual(commits, 0)
        button.sendActions(for: .touchDown)
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(presses, 2)
        XCTAssertEqual(commits, 1)
    }

    func testRailReloadDuringControlSelectionCannotAlsoSelectNewCell() throws {
        let rail = KeyboardRailView()
        defer { rail.select = nil }
        rail.frame = CGRect(x: 0, y: 0, width: 48, height: 160)
        var commits = 0
        rail.select = { _ in
            commits += 1
            rail.update([.init(id: "new", title: "dui")], height: 44, font: 15)
            rail.layoutIfNeeded()
        }
        rail.update([.init(id: "old", title: "d")], height: 44, font: 15)
        rail.layoutIfNeeded()
        let oldCell = try XCTUnwrap(rail.cellForItem(at: IndexPath(item: 0, section: 0)))
        let button = try XCTUnwrap(oldCell.hitTest(CGPoint(x: 1, y: 22), with: nil) as? UIButton)
        button.sendActions(for: .touchDown)
        button.sendActions(for: .touchUpInside)
        rail.collectionView(rail, didSelectItemAt: IndexPath(item: 0, section: 0))
        XCTAssertEqual(commits, 1)
    }

    func testRailActionRefreshDoesNotRewriteAlreadyPressedSnapshot() throws {
        let rail = KeyboardRailView()
        rail.frame = CGRect(x: 0, y: 0, width: 48, height: 160)
        var selected: [String] = []
        rail.select = { _ in selected.append("old") }
        rail.update([.init(id: "same", title: "d")], height: 44, font: 15)
        rail.layoutIfNeeded()
        let cell = try XCTUnwrap(rail.cellForItem(at: IndexPath(item: 0, section: 0)))
        let button = try XCTUnwrap(cell.hitTest(CGPoint(x: 1, y: 22), with: nil) as? UIButton)
        button.sendActions(for: .touchDown)
        rail.select = { _ in selected.append("new") }
        button.sendActions(for: .touchUpInside)
        button.sendActions(for: .touchDown)
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(selected, ["old", "new"])
    }

    private func renderedInkBounds(_ view: UIView) throws -> CGRect {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = false
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { view.layer.render(in: $0.cgContext) }
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            var minX = width, minY = height, maxX = -1, maxY = -1
            for y in 0..<height { for x in 0..<width where bytes[(y * width + x) * 4 + 3] > 8 {
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            }}
            XCTAssertGreaterThanOrEqual(maxX, 0)
            return CGRect(x: CGFloat(minX) / 2, y: CGFloat(minY) / 2, width: CGFloat(maxX - minX + 1) / 2, height: CGFloat(maxY - minY + 1) / 2)
        }
    }
}
