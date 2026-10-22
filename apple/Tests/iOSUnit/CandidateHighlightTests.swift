import UIKit
import XCTest

@MainActor final class CandidateHighlightTests: XCTestCase {
    func testNonManageableLongPressCannotCancelASlowCandidateTap() throws {
        let cell=CandidateCell(frame:CGRect(x:0,y:0,width:80,height:44));cell.layoutIfNeeded()
        let button=try XCTUnwrap(cell.hitTest(CGPoint(x:1,y:22),with:nil) as? UIButton)
        let hold=try XCTUnwrap(button.gestureRecognizers?.compactMap{$0 as? UILongPressGestureRecognizer}.first(where:{$0.delegate === cell}))
        XCTAssertFalse(cell.gestureRecognizerShouldBegin(hold))
        cell.contextMenuProvider={nil};XCTAssertFalse(cell.gestureRecognizerShouldBegin(hold))
        cell.contextMenuProvider={UIMenu(children:[UIAction(title:"置顶"){_ in}])}
        XCTAssertTrue(cell.gestureRecognizerShouldBegin(hold))
    }
    func testFirstCandidatePressedSurfaceStaysInsideItsFullTapTarget() {
        for size in [CGSize(width: 48, height: 44), CGSize(width: 336, height: 104)] {
            let cell = CandidateCell(frame: CGRect(origin: .zero, size: size))
            cell.isHighlighted = true
            cell.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: cell.bounds).image { context in
                cell.layer.render(in: context.cgContext)
            }
            XCTAssertEqual(alpha(image, at: CGPoint(x: 0, y: 0)), 0)
            XCTAssertEqual(alpha(image, at: CGPoint(x: 2, y: 2)), 0, "Rounded corners must remain transparent, including the first item at the strip edge")
            XCTAssertGreaterThan(alpha(image, at: CGPoint(x: size.width / 2, y: 5)), 200)
            XCTAssertTrue(cell.hitTest(CGPoint(x: 1, y: 1), with: nil) is UIButton, "The complete candidate edge must hit its native control")
            XCTAssertTrue(cell.clipsToBounds)
            XCTAssertTrue(cell.contentView.clipsToBounds)
        }
    }

    func testWordMenuAnchorsToThePressedCandidateWithoutLiftPreview() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let cell = CandidateCell(frame: CGRect(x: 0, y: 0, width: 80, height: 44))
        host.view.addSubview(cell)
        let rect=cell.candidateMenuSourceRect()
        XCTAssertEqual(rect,CGRect(x:2,y:2,width:76,height:40))
        let button=try XCTUnwrap(cell.hitTest(CGPoint(x:1,y:22),with:nil) as? UIButton)
        XCTAssertEqual(button.interactions.compactMap{$0 as? UIEditMenuInteraction}.count,1)
        XCTAssertTrue(button.interactions.compactMap{$0 as? UIContextMenuInteraction}.isEmpty)
    }

    func testOffscreenLongCandidateMenuAnchorClipsToVisibleScrollViewport() {
        let window=UIWindow(frame:CGRect(x:0,y:0,width:320,height:220)),host=UIViewController()
        window.rootViewController=host;window.makeKeyAndVisible()
        defer {window.isHidden=true;window.rootViewController=nil}
        let strip=UIScrollView(frame:CGRect(x:8,y:40,width:240,height:60));strip.clipsToBounds=true;host.view.addSubview(strip)
        let cell=CandidateCell(frame:CGRect(x:0,y:0,width:800,height:60));strip.addSubview(cell)
        let rect=cell.candidateMenuSourceRect();XCTAssertFalse(rect.isNull)
        XCTAssertLessThanOrEqual(rect.maxX,240);XCTAssertGreaterThanOrEqual(rect.minX,2)
    }
    func testDetachedCandidateSafelyOmitsWordMenuAnchor() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        let cell = CandidateCell(frame: CGRect(x: 0, y: 0, width: 80, height: 44))
        host.addSubview(cell)
        XCTAssertTrue(cell.candidateMenuSourceRect().isNull)
        cell.removeFromSuperview()
        XCTAssertTrue(cell.candidateMenuSourceRect().isNull)
    }

    func testFullCellNativeControlCommitsOnlyOnTouchUpInside() throws {
        let cell = CandidateCell(frame: CGRect(x: 0, y: 0, width: 80, height: 44))
        cell.layoutIfNeeded()
        let button = try XCTUnwrap(cell.hitTest(CGPoint(x: 1, y: 22), with: nil) as? UIButton)
        XCTAssertFalse(button.isAccessibilityElement)
        XCTAssertTrue(cell.isAccessibilityElement)
        var presses = 0, commits = 0
        cell.pressBegan = { presses += 1 }
        cell.activate = { commits += 1 }
        button.sendActions(for: .touchDown)
        XCTAssertEqual(presses, 1)
        XCTAssertEqual(commits, 0)
        button.sendActions(for: .touchCancel)
        XCTAssertEqual(commits, 0)
        button.sendActions(for: .touchDown)
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(presses, 2)
        XCTAssertEqual(commits, 1)
        XCTAssertTrue(cell.isHandlingControlTouch)
        button.isHighlighted = true
        XCTAssertTrue(cell.isHighlighted)
        button.isHighlighted = false
        XCTAssertFalse(cell.isHighlighted)
        cell.prepareForReuse()
        XCTAssertFalse(cell.isHandlingControlTouch)
    }

    func testTouchDownKeepsDisplayedCandidateWhenActionIsReboundBeforeTouchUp() throws {
        let cell = CandidateCell(frame: CGRect(x: 0, y: 0, width: 80, height: 44))
        cell.layoutIfNeeded()
        let button = try XCTUnwrap(cell.hitTest(CGPoint(x: 1, y: 22), with: nil) as? UIButton)
        var selected: [String] = []
        cell.activate = { selected.append("displayed-at-down") }
        button.sendActions(for: .touchDown)
        cell.activate = { selected.append("rebound-after-down") }
        button.sendActions(for: .touchUpInside)
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(selected, ["displayed-at-down"])
    }

    func testReuseCancelsPendingCandidateEvenIfTouchUpArrivesLater() throws {
        let cell = CandidateCell(frame: CGRect(x: 0, y: 0, width: 80, height: 44))
        cell.layoutIfNeeded()
        let button = try XCTUnwrap(cell.hitTest(CGPoint(x: 1, y: 22), with: nil) as? UIButton)
        var commits = 0
        cell.activate = { commits += 1 }
        button.sendActions(for: .touchDown)
        cell.prepareForReuse()
        cell.activate = { commits += 100 }
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(commits, 0)
    }

    func testContextMenuCancellationCannotCommitOnRelease() throws {
        let cell = CandidateCell(frame: CGRect(x: 0, y: 0, width: 80, height: 44))
        cell.layoutIfNeeded()
        let button = try XCTUnwrap(cell.hitTest(CGPoint(x: 1, y: 22), with: nil) as? UIButton)
        var commits = 0
        cell.activate = { commits += 1 }
        button.sendActions(for: .touchDown)
        cell.cancelPendingControlActivation()
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(commits, 0)
        button.sendActions(for: .touchDown)
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(commits, 1, "A later deliberate tap still selects the current candidate")
    }

    func testNativeWordEditMenuCancelsItsPendingCommit() throws {
        let cell = CandidateCell(frame: CGRect(x: 0, y: 0, width: 80, height: 44))
        cell.layoutIfNeeded()
        let button = try XCTUnwrap(cell.hitTest(CGPoint(x: 1, y: 22), with: nil) as? UIButton)
        let interaction = try XCTUnwrap(button.interactions.compactMap { $0 as? UIEditMenuInteraction }.first)
        var commits = 0
        cell.activate = { commits += 1 }
        cell.contextMenuProvider = { UIMenu(children: [UIAction(title: "候选置顶") { _ in }]) }
        button.sendActions(for: .touchDown)
        XCTAssertNotNil(cell.prepareCandidateMenu())
        XCTAssertNil(cell.editMenuInteraction(interaction,menuFor:UIEditMenuConfiguration(identifier:nil,sourcePoint:CGPoint(x:1,y:22)),suggestedActions:[]),"Unbound/old configuration cannot open a new candidate's actions")
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(commits, 0)
        cell.prepareForReuse()
        XCTAssertNil(cell.contextMenuProvider)
        XCTAssertNil(cell.prepareCandidateMenu())
    }

    func testReusedPressedCandidateDoesNotKeepItsColoredSurface() {
        let cell = CandidateCell(frame: CGRect(x: 0, y: 0, width: 80, height: 44))
        cell.isHighlighted = true
        cell.layoutIfNeeded()
        cell.prepareForReuse()
        let image = UIGraphicsImageRenderer(bounds: cell.bounds).image { context in
            cell.layer.render(in: context.cgContext)
        }
        XCTAssertEqual(alpha(image, at: CGPoint(x: 40, y: 5)), 0)
    }

    private func alpha(_ image: UIImage, at point: CGPoint) -> UInt8 {
        guard let cgImage = image.cgImage else { return 255 }
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 255 }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let x = min(width - 1, max(0, Int(point.x * image.scale)))
        let y = min(height - 1, max(0, Int(point.y * image.scale)))
        return pixels[(y * width + x) * 4 + 3]
    }
}
