import AppKit

/// Pure screen-coordinate policy. Geometry comes from the current IMK client;
/// a missing caret never means a made-up panel at (0,0) or screen centre.
enum MacCandidatePlacement {
    static func frame(caret:NSRect,size:NSSize,referenceHeight:CGFloat,screens:[NSRect])->NSRect? {
        let values=[caret.minX,caret.minY,caret.width,caret.height,size.width,size.height]
        guard values.allSatisfy(\.isFinite),caret.height>=1,caret.height<=512,size.width>0,size.height>0,
              !(caret.minX==0 && caret.minY==0),let screen=screens.first(where:{$0.intersects(caret)}) else{return nil}
        let bounds=screen.insetBy(dx:6,dy:6),gap:CGFloat=4
        let below=caret.minY-gap-bounds.minY,above=bounds.maxY-caret.maxY-gap
        let down=below>=referenceHeight || below>=above
        let width=min(size.width,bounds.width),height=min(size.height,max(1,down ? below:above))
        guard height>=1,width>=1 else{return nil}
        let x=max(bounds.minX,min(caret.minX,bounds.maxX-width))
        let y=down ? caret.minY-gap-height:caret.maxY+gap
        return NSRect(x:x,y:max(bounds.minY,min(y,bounds.maxY-height)),width:width,height:height)
    }
}
