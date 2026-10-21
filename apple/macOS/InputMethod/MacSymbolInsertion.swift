import Foundation

/// IMK has no selection setter. A verified zero-length marked replacement
/// moves the native insertion point without leaving a marked composition.
/// Clients without document access keep both symbols and the caret at the end.
enum MacSymbolInsertion {
    static func insert(_ text:String,caretBack:Int,
                       insert:(String)->Void,selection:()->NSRange,
                       read:(NSRange)->String?,placeCaret:(NSRange)->Void) {
        insert(text)
        let length=text.utf16.count
        guard caretBack>0,caretBack<length else{return}
        let after=selection()
        guard after.location != NSNotFound,after.length==0,after.location>=length else{return}
        let inserted=NSRange(location:after.location-length,length:length)
        guard read(inserted)==text else{return}
        placeCaret(NSRange(location:after.location-caretBack,length:0))
    }
}
