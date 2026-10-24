import Foundation

/// IMK has no selection setter. A verified zero-length marked replacement
/// moves the native insertion point without leaving a marked composition.
/// Clients without document access keep both symbols and the caret at the end.
enum MacSymbolInsertion {
    static func context(document:String,selection:NSRange,marked:NSRange,length:Int,read:(NSRange)->String?)->SymbolPairing.EditContext? {
        guard selection.location != NSNotFound,selection.length==0,length>=0,length != NSNotFound,selection.location<=length,
              marked.location==NSNotFound || marked.length==0 else{return nil}
        func value(_ range:NSRange)->String? {
            if range.length==0{return ""}
            guard let text=read(range),text.utf16.count==range.length else{return nil};return text
        }
        let before=NSRange(location:max(0,selection.location-32),length:min(32,selection.location))
        let after=NSRange(location:selection.location,length:min(32,length-selection.location))
        return .init(document:document,position:selection.location,selectionEmpty:true,before:value(before),after:value(after))
    }
    static func delete(_ plan:SymbolPairing.DeletionPlan,context:()->SymbolPairing.EditContext?,replace:(NSRange)->Void)->Bool {
        guard plan.expected.matches(context()),let range=plan.replacementRange else{return false}
        replace(range);return true
    }
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
