import UIKit
import XCTest

@MainActor final class CandidatePresentationTests:XCTestCase,UICollectionViewDataSource {
    private let texts=["是","时候","什么","这是一条用来验证完整长句不会遮住其它候选文字的合成句子。","你好","第一行\n第二行"]
    func collectionView(_ collectionView:UICollectionView,numberOfItemsInSection section:Int)->Int {texts.count}
    func collectionView(_ collectionView:UICollectionView,cellForItemAt indexPath:IndexPath)->UICollectionViewCell {collectionView.dequeueReusableCell(withReuseIdentifier:"cell",for:indexPath)}
    func testExpansionControlOwnsWhole56By44AreaIncludingRootEdge() {
        let host=UIView(frame:CGRect(x:0,y:0,width:CandidateExpansionButton.touchWidth,height:44))
        let button=CandidateExpansionButton(type:.custom);button.frame=host.bounds
        button.setImage(UIImage(systemName:"chevron.down"),for:.normal)
        var style=UIButton.Configuration.plain();style.contentInsets = .zero;button.configuration=style
        host.addSubview(button)
        for x:CGFloat in [1,28,55] {for y:CGFloat in [1,22,43] {
            XCTAssertTrue(host.hitTest(CGPoint(x:x,y:y),with:nil) === button)
        }}
        button.isHidden=true;XCTAssertFalse(host.hitTest(CGPoint(x:28,y:22),with:nil) === button)
    }
    func testBudgetYieldKeepsToggleUsableWithoutChangingItsFrame() {
        let button=CandidateExpansionButton(type:.custom)
        button.frame=CGRect(x:337,y:0,width:56,height:44)
        let frame=button.frame
        button.isEnabled=CandidateExpansionButton.canToggle(expanded:false,choicesAvailable:false,hasComposition:true,deferred:true,english:false)
        XCTAssertTrue(button.isEnabled)
        XCTAssertTrue(button.point(inside:CGPoint(x:55,y:43),with:nil))
        XCTAssertTrue(CandidateExpansionButton.canToggle(expanded:true,choicesAvailable:false,hasComposition:false,deferred:false,english:false),"An empty final page must still allow collapse")
        XCTAssertFalse(CandidateExpansionButton.canToggle(expanded:false,choicesAvailable:false,hasComposition:false,deferred:true,english:false))
        XCTAssertFalse(CandidateExpansionButton.canToggle(expanded:false,choicesAvailable:false,hasComposition:true,deferred:true,english:true))
        button.isEnabled=CandidateExpansionButton.canToggle(expanded:true,choicesAvailable:true,hasComposition:true,deferred:false,english:false)
        XCTAssertEqual(button.frame,frame)
    }
    func testExpansionOwnsRightGutterWithoutStealingCandidateScroll() {
        let host=KeyboardInputView(frame:CGRect(x:0,y:0,width:393,height:100),inputViewStyle:.keyboard)
        let strip=UIScrollView(frame:CGRect(x:4,y:20,width:329,height:60))
        let expand=CandidateExpansionButton(type:.custom);expand.frame=CGRect(x:337,y:20,width:56,height:60)
        host.addSubview(strip);host.addSubview(expand)
        host.scrollHitTest={point,event in KeyboardScrollSurfaceRouting.hit(in:strip,point:point,root:host,excluding:[expand],event:event)}
        for point in [CGPoint(x:338,y:21),CGPoint(x:365,y:50),CGPoint(x:392,y:79)] {
            XCTAssertTrue(host.hitTest(point,with:nil) === expand)
        }
        XCTAssertTrue(host.hitTest(CGPoint(x:332,y:50),with:nil) === strip)
        expand.isHidden=true
        XCTAssertFalse(host.hitTest(CGPoint(x:365,y:50),with:nil) === expand)
    }
    func testReadableLongCandidatesAndCollapseAreaInNarrowAndLargeTextLayouts() throws {
        for width:CGFloat in [320,393,720] {
            for category:UIContentSizeCategory in [.large,.accessibilityExtraExtraExtraLarge] {
                let parent=UIViewController(),host=UIViewController();parent.loadViewIfNeeded();parent.addChild(host)
                parent.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory:category),forChild:host)
                let layout=CandidateListLayout();layout.textAt={self.texts[$0]}
                let list=UICollectionView(frame:CGRect(x:0,y:0,width:width,height:280),collectionViewLayout:layout)
                list.register(UICollectionViewCell.self,forCellWithReuseIdentifier:"cell");list.dataSource=self;host.view.addSubview(list)
                list.reloadData();list.layoutIfNeeded();layout.prepare()
                let frames=try texts.indices.map{try XCTUnwrap(layout.layoutAttributesForItem(at:IndexPath(item:$0,section:0))).frame}
                let collapse=CGRect(x:width-CandidateExpansionButton.touchWidth,y:0,width:CandidateExpansionButton.touchWidth,height:layout.controlHeight)
                XCTAssertEqual(frames[0].minX,6)
                XCTAssertEqual(frames[0].width,(width-12)/4,accuracy:0.001)
                for (i,frame) in frames.enumerated() {
                    XCTAssertGreaterThanOrEqual(frame.height,44);XCTAssertGreaterThanOrEqual(frame.minX,6);XCTAssertLessThanOrEqual(frame.maxX,width-6)
                    XCTAssertFalse(frame.intersects(collapse),"A visible candidate must not sit under the collapse control")
                    for other in frames.dropFirst(i+1) {XCTAssertFalse(frame.intersects(other))}
                }
                let phrase=frames[3],font=CandidateListLayout.font(at:3,traits:list.traitCollection)
                let needed=(texts[3] as NSString).boundingRect(with:CGSize(width:phrase.width-20,height:.greatestFiniteMagnitude),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:font],context:nil)
                XCTAssertGreaterThanOrEqual(phrase.height,ceil(needed.height)+16)
                XCTAssertLessThanOrEqual(font.pointSize,26)
            }
        }
    }
    func testExpandedPanelKeepsNativeActionsAndFooterInsteadOfDisablingTheirAncestor() {
        let host=UIView(frame:CGRect(x:0,y:0,width:393,height:300))
        let letters=UIView(frame:CGRect(x:52,y:44,width:281,height:200)),rail=UIView(frame:CGRect(x:337,y:44,width:48,height:200)),footer=UIView(frame:CGRect(x:4,y:248,width:381,height:48))
        let delete=UIButton(type:.system);delete.frame=CGRect(x:0,y:0,width:48,height:64);rail.addSubview(delete)
        [letters,rail,footer].forEach(host.addSubview)
        let original=delete.convert(delete.bounds,to:host),footerFrame=footer.frame
        KeyboardCandidatePanelGeometry.apply(expanded:true,keyRegions:[letters,rail],retainedActions:rail,delete:delete,footer:footer)
        XCTAssertEqual(letters.alpha,0);XCTAssertFalse(letters.isUserInteractionEnabled)
        XCTAssertEqual(rail.alpha,1);XCTAssertTrue(rail.isUserInteractionEnabled)
        XCTAssertEqual(footer.alpha,1);XCTAssertTrue(footer.isUserInteractionEnabled)
        XCTAssertEqual(delete.convert(delete.bounds,to:host),original);XCTAssertEqual(footer.frame,footerFrame)
        XCTAssertTrue(host.hitTest(CGPoint(x:original.midX,y:original.midY),with:nil) === delete)
        KeyboardCandidatePanelGeometry.apply(expanded:false,keyRegions:[letters,rail],retainedActions:rail,delete:delete,footer:footer)
        XCTAssertEqual(letters.alpha,1);XCTAssertTrue(letters.isUserInteractionEnabled)
    }
    func testExpandedLettersKeepTheirOriginalThirdRowDeleteAndStableHeaderHeight() {
        let region=UIView(frame:CGRect(x:0,y:44,width:393,height:190)),row=UIStackView(frame:CGRect(x:0,y:132,width:393,height:58))
        let letter=UIButton(type:.system),delete=UIButton(type:.system);row.addArrangedSubview(letter);row.addArrangedSubview(delete);region.addSubview(row)
        row.distribution = .fillEqually;row.layoutIfNeeded()
        let footer=UIView(frame:CGRect(x:0,y:238,width:393,height:44)),original=delete.convert(delete.bounds,to:region)
        for _ in 0..<20 {
            KeyboardCandidatePanelGeometry.apply(expanded:true,keyRegions:[region],retainedActions:nil,delete:delete,footer:footer)
            XCTAssertEqual(letter.alpha,0);XCTAssertEqual(delete.alpha,1);XCTAssertTrue(delete.isUserInteractionEnabled)
            XCTAssertEqual(delete.convert(delete.bounds,to:region),original)
            KeyboardCandidatePanelGeometry.apply(expanded:false,keyRegions:[region],retainedActions:nil,delete:delete,footer:footer)
            XCTAssertEqual(letter.alpha,1)
        }
        XCTAssertEqual(KeyboardCandidatePanelGeometry.headerHeight(inline:true),44)
        XCTAssertEqual(KeyboardCandidatePanelGeometry.headerHeight(inline:false),62)
        XCTAssertEqual(KeyboardCandidatePanelGeometry.candidateTop(inline:true),0)
        XCTAssertEqual(KeyboardCandidatePanelGeometry.candidateTop(inline:false),18)
        for width:CGFloat in [320,393,720,1024] {
            let frame=CGRect(x:width-92,y:180,width:88,height:48)
            let reserve=KeyboardCandidatePanelGeometry.trailingReserve(width:width,deleteFrame:frame)
            XCTAssertGreaterThanOrEqual(reserve,60);XCTAssertLessThanOrEqual(width-reserve,frame.minX-4)
        }
    }
}
