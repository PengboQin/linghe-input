import UIKit
import XCTest

@MainActor final class ClipboardPasteCandidateViewTests:XCTestCase {
    func testUnknownNativePasteStaysCompactInsideCandidateRow() throws {
        let view=ClipboardPasteCandidateView(frame:.init(x:0,y:0,width:393,height:60))
        view.layoutIfNeeded()
        let native=try XCTUnwrap(view.subviews.first(where:{$0 is UIPasteControl}))
        XCTAssertLessThanOrEqual(native.frame.width,160)
        XCTAssertLessThanOrEqual(native.frame.height,44)
        XCTAssertLessThan(native.frame.width,view.bounds.width)
        XCTAssertTrue(view.bounds.contains(native.frame))
        XCTAssertEqual(native.frame.midY,view.bounds.midY)
        XCTAssertTrue(view.backgroundColor?.isEqual(UIColor.clear)==true)
        XCTAssertFalse(view.isOpaque)
    }
    func testKnownPreviewHasNoOpaquePlateAndInsertsOriginalText() throws {
        let view=ClipboardPasteCandidateView(frame:.init(x:0,y:0,width:393,height:60))
        let request=ClipboardCandidateState.Request(version:1,document:UUID(),presentation:1,deletion:0,scope:"synthetic-test")
        let original="one\r\n  indented\n\nemoji鹤🪶  "
        var inserted:String?
        view.insertKnown={inserted=$0.text}
        view.show(snapshot:.init(request:request,text:original))
        view.layoutIfNeeded()
        let button=try XCTUnwrap(view.subviews.compactMap{$0 as? UIButton}.first(where:{$0.accessibilityIdentifier=="clipboard-text-candidate"}))
        XCTAssertFalse(button.isHidden)
        XCTAssertEqual(button.titleLabel?.numberOfLines,1)
        XCTAssertEqual(button.titleLabel?.frame.minX,10)
        button.isHighlighted=true;button.layoutIfNeeded()
        let image=UIGraphicsImageRenderer(bounds:view.bounds).image{view.layer.render(in:$0.cgContext)}
        XCTAssertEqual(alpha(image,x:0,y:0),0)
        XCTAssertEqual(alpha(image,x:2,y:2),0,"Rounded feedback must not paint the candidate-row corner")
        button.sendActions(for:.touchUpInside)
        XCTAssertEqual(inserted,original)
    }
    private func alpha(_ image:UIImage,x:Int,y:Int)->UInt8 {
        guard let cg=image.cgImage else{return 255}
        let width=cg.width,height=cg.height
        var bytes=[UInt8](repeating:0,count:width*height*4)
        let ok=bytes.withUnsafeMutableBytes {raw->Bool in
            guard let context=CGContext(data:raw.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{return false}
            context.draw(cg,in:.init(x:0,y:0,width:width,height:height));return true
        }
        guard ok else{return 255}
        let column=min(width-1,max(0,Int(CGFloat(x)*image.scale)))
        let row=min(height-1,max(0,Int(CGFloat(y)*image.scale)))
        return bytes[(row*width+column)*4+3]
    }
}
