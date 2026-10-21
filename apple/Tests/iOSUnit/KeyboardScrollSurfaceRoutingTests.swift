import UIKit
import XCTest

@MainActor final class KeyboardScrollSurfaceRoutingTests: XCTestCase {
    private func fixture() -> (UIView, UIScrollView) {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        let scroll = UIScrollView(frame: CGRect(x: 50, y: 50, width: 280, height: 180))
        scroll.contentSize = CGSize(width: 280, height: 900)
        root.addSubview(scroll)
        return (root, scroll)
    }
    func testVisibleWholeSurfaceAndContentOffsetUseNativeCoordinates() {
        let (root, scroll) = fixture()
        scroll.contentOffset = CGPoint(x: 0, y: 200)
        for point in [CGPoint(x: 50, y: 50), CGPoint(x: 190, y: 130), CGPoint(x: 329, y: 229)] {
            XCTAssertNotNil(KeyboardScrollSurfaceRouting.hit(in: scroll, point: point, root: root))
        }
        let content = UIButton(frame: CGRect(x: 40, y: 240, width: 70, height: 44))
        scroll.addSubview(content)
        let point = content.convert(CGPoint(x: 20, y: 20), to: root)
        XCTAssertTrue(KeyboardScrollSurfaceRouting.hit(in: scroll, point: point, root: root) === content)
        XCTAssertNil(KeyboardScrollSurfaceRouting.hit(in: scroll, point: CGPoint(x: 30, y: 100), root: root))
        XCTAssertNil(KeyboardScrollSurfaceRouting.hit(in: scroll, point: CGPoint(x: 190, y: 231), root: root))
    }
    func testHiddenDisabledOrTransparentSurfaceAndAncestorCannotTakeTouches() {
        let (root, scroll) = fixture(), point = CGPoint(x: 100, y: 100)
        scroll.isHidden = true
        XCTAssertNil(KeyboardScrollSurfaceRouting.hit(in: scroll, point: point, root: root))
        scroll.isHidden = false; scroll.alpha = 0.01
        XCTAssertNil(KeyboardScrollSurfaceRouting.hit(in: scroll, point: point, root: root))
        scroll.alpha = 1; scroll.isUserInteractionEnabled = false
        XCTAssertNil(KeyboardScrollSurfaceRouting.hit(in: scroll, point: point, root: root))
        scroll.isUserInteractionEnabled = true; root.isHidden = true
        XCTAssertNil(KeyboardScrollSurfaceRouting.hit(in: scroll, point: point, root: root))
        root.isHidden = false
        let wrapper = UIView(frame: root.bounds); root.addSubview(wrapper); wrapper.addSubview(scroll)
        for variant in 0..<3 {
            wrapper.isHidden = variant == 0; wrapper.alpha = variant == 1 ? 0 : 1; wrapper.isUserInteractionEnabled = variant != 2
            XCTAssertNil(KeyboardScrollSurfaceRouting.hit(in: scroll, point: point, root: root))
        }
    }
    func testAncestorClipAndUnrelatedHierarchyRejectOverflow() {
        let (root, scroll) = fixture()
        let wrapper = UIView(frame: CGRect(x: 0, y: 0, width: 180, height: 180))
        root.addSubview(wrapper); wrapper.addSubview(scroll)
        wrapper.clipsToBounds = true
        XCTAssertNil(KeyboardScrollSurfaceRouting.hit(in: scroll, point: CGPoint(x: 210, y: 100), root: root))
        XCTAssertNotNil(KeyboardScrollSurfaceRouting.hit(in: scroll, point: CGPoint(x: 100, y: 100), root: root))
        wrapper.clipsToBounds = false
        XCTAssertNotNil(KeyboardScrollSurfaceRouting.hit(in: scroll, point: CGPoint(x: 210, y: 100), root: root))
        scroll.removeFromSuperview()
        XCTAssertNil(KeyboardScrollSurfaceRouting.hit(in: scroll, point: CGPoint(x: 100, y: 100), root: root))
    }
    func testFooterAndExpandedButtonKeepNativeHitAreaWithoutStealingScroll() {
        final class SlopButton: UIButton {
            override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { bounds.insetBy(dx: -12, dy: -12).contains(point) }
        }
        let (root, scroll) = fixture()
        let footer = UIButton(frame: CGRect(x: 40, y: 220, width: 300, height: 44)); root.addSubview(footer)
        XCTAssertNil(KeyboardScrollSurfaceRouting.hit(in: scroll, point: CGPoint(x: 100, y: 225), root: root, excluding: [footer]))
        XCTAssertNotNil(KeyboardScrollSurfaceRouting.hit(in: scroll, point: CGPoint(x: 100, y: 200), root: root, excluding: [footer]))
        let expand = SlopButton(frame: CGRect(x: 280, y: 50, width: 44, height: 44)); root.addSubview(expand)
        let inSlop = CGPoint(x: 274, y: 70)
        XCTAssertNil(KeyboardScrollSurfaceRouting.hit(in: scroll, point: inSlop, root: root, excluding: [expand]))
        expand.isHidden = true
        XCTAssertNotNil(KeyboardScrollSurfaceRouting.hit(in: scroll, point: inSlop, root: root, excluding: [expand]))
        footer.alpha = 0
        XCTAssertNotNil(KeyboardScrollSurfaceRouting.hit(in: scroll, point: CGPoint(x: 100, y: 225), root: root, excluding: [footer]))
    }
}
