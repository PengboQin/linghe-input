import CoreGraphics

/// Candidate-row geometry only. Native permission UI keeps its natural compact
/// width; it never becomes a screen-wide filled paste control.
enum ClipboardCandidateInlineLayout {
    static let horizontalInset:CGFloat=8
    static let nativeMaximumWidth:CGFloat=160
    static let nativeMaximumHeight:CGFloat=44
    static func nativeFrame(in bounds:CGRect,fitting:CGSize)->CGRect {
        let available=max(0,bounds.width-horizontalInset*2)
        let width=min(available,nativeMaximumWidth,max(44,fitting.width))
        let height=min(max(0,bounds.height),nativeMaximumHeight)
        return .init(x:bounds.minX+min(horizontalInset,bounds.width/2),y:bounds.midY-height/2,width:width,height:height)
    }
    static func textFrame(in bounds:CGRect)->CGRect {bounds}
    static func titleContentFrame(in bounds:CGRect)->CGRect {
        bounds.insetBy(dx:min(10,max(0,bounds.width/2)),dy:0)
    }
    static func highlightFrame(in bounds:CGRect)->CGRect {
        bounds.insetBy(dx:min(2,max(0,bounds.width/2)),dy:min(2,max(0,bounds.height/2)))
    }
}
