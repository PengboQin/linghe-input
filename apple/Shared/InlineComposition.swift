import Foundation

protocol InlineCompositionHost {
    var compositionDocument: UUID? { get }
    var compositionBefore: String? { get }
    var compositionAfter: String? { get }
    var compositionSelection: String? { get }
    func markComposition(_ text: String, selection: NSRange)
    func unmarkComposition()
}

// Own only our marked range. Never delete a guessed number of host characters
// or replay an old draft into another field.
final class InlineComposition {
    private(set) var document: UUID?
    private(set) var draft = ""
    private(set) var applying = false
    private var before:String?,after:String?
    private var originalSelection = "", previousDraft = ""
    var active: Bool { document != nil }
    func forget() { document=nil;draft="";before=nil;after=nil;originalSelection="";previousDraft="" }
    private func contextMatches(_ current:String,_ following:String,_ text:String) -> Bool {
        let prefix=before.map { String(($0+text).suffix(64)) }
        let leading=prefix.map { $0.isEmpty ? current.isEmpty:current.hasSuffix($0) } ?? true
        let trailing=after.map { $0.isEmpty ? following.isEmpty:following.hasPrefix($0) } ?? true
        return leading && trailing
    }
    private func matches(_ host: InlineCompositionHost) -> Bool {
        guard active,document==host.compositionDocument else { return false }
        if let selection=host.compositionSelection,!selection.isEmpty,selection != draft { return false }
        // Hosts may withhold context entirely while still supporting the public
        // marked-text operations. The native range remains bound to this field.
        if let current=host.compositionBefore {
            // UIKit may return committed context excluding its marked range.
            // Nil at the first key is unknown, not proof of an empty prefix.
            if let before {
                let composed=String((before+draft).suffix(64))
                let original=before.isEmpty ? current.isEmpty:current.hasSuffix(before)
                if !original && !current.hasSuffix(composed) { return false }
            }
        }
        if let following=host.compositionAfter,let after,!(after.isEmpty ? following.isEmpty:following.hasPrefix(after)) { return false }
        return true
    }
    func moved(in host:InlineCompositionHost) -> Bool {
        guard active,!applying else { return false }
        guard let currentDocument=host.compositionDocument else { return false }
        if document != currentDocument { return true }
        if matches(host) { return false }
        // Proxy callbacks may briefly expose the context from before our write.
        guard let current=host.compositionBefore,let following=host.compositionAfter else { return false }
        return !contextMatches(current,following,previousDraft) || host.compositionSelection?.isEmpty == false
    }
    @discardableResult func update(_ text:String,host:InlineCompositionHost) -> Bool {
        guard !applying,!text.isEmpty,let id=host.compositionDocument else { return false }
        if active && document != id { forget();return false }
        if !active { document=id;before=host.compositionBefore.map{String($0.suffix(16))};after=host.compositionAfter.map{String($0.prefix(16))};originalSelection=host.compositionSelection ?? "" }
        if draft != text {
            previousDraft=draft;draft=text;applying=true
            host.markComposition(text,selection:NSRange(location:text.utf16.count,length:0))
            applying=false
        }
        return matches(host)
    }
    @discardableResult func finish(_ replacement:String?,host:InlineCompositionHost) -> Bool {
        // A temporarily detached proxy is not a different document. Retain a
        // pending cancellation until a later render can address the real field.
        guard active,!applying,host.compositionDocument != nil else { return false }
        let owned=matches(host),text=replacement ?? originalSelection
        forget()
        guard owned else { return false }
        applying=true
        host.markComposition(text,selection:NSRange(location:text.utf16.count,length:0))
        host.unmarkComposition();applying=false
        return true
    }
    func leave(host:InlineCompositionHost) {
        let same=active && document==host.compositionDocument
        forget()
        if same { applying=true;host.unmarkComposition();applying=false }
    }
}
