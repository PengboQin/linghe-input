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
}
