import Foundation
import CryptoKit

/// Call only for a deliberate symbol keystroke/tap. Committed candidates,
/// clipboard/shared text and pasted strings must use their existing raw path.
enum SymbolPairing {
    struct Plan: Equatable {
        let insertedText: String
        /// UTF-16 units after the desired caret; the supported closers are BMP.
        let caretBack: Int
    }
    static let pairs: [String: String] = [
        "(": ")", "（": "）", "[": "]", "【": "】", "{": "}",
        "《": "》", "〈": "〉", "「": "」", "『": "』",
        "“": "”", "‘": "’", "\"": "\""
    ]
    static func plan(for symbol: String, autoPair: Bool = true, caretInside: Bool = true) -> Plan {
        // Exact lookup also keeps multi-character strings and apostrophes raw.
        guard autoPair, let closing = pairs[symbol] else { return .init(insertedText: symbol, caretBack: 0) }
        return .init(insertedText: symbol + closing, caretBack: caretInside ? closing.utf16.count : 0)
    }

    /// Only a bounded, ephemeral host window. Unknown context or a nonempty
    /// selection cannot establish ownership of an automatically inserted pair.
    struct EditContext {
        let document: String
        let position: Int?
        let before: String
        let after: String
        init?(document: String?, position: Int? = nil, selectionEmpty: Bool, before: String?, after: String?) {
            guard let document, !document.isEmpty, selectionEmpty, let before, let after,
                  position.map({$0 >= 0 && $0 != NSNotFound}) ?? true else { return nil }
            self.document=document;self.position=position;self.before=String(before.suffix(16));self.after=String(after.prefix(16))
        }
    }
    struct ContextProof: Equatable {
        let document: String, position: Int?
        private let beforeDigest: Data, afterDigest: Data
        fileprivate let beforeEmpty: Bool, afterEmpty: Bool
        init(_ context: EditContext) {
            document=context.document;position=context.position
            beforeEmpty=context.before.isEmpty;afterEmpty=context.after.isEmpty
            beforeDigest=Data(SHA256.hash(data:Data(context.before.utf8)));afterDigest=Data(SHA256.hash(data:Data(context.after.utf8)))
        }
        func matches(_ context: EditContext?) -> Bool { context.map { Self($0)==self } ?? false }
    }
    struct DeletionPlan {
        let expected: ContextProof, atEnd: ContextProof, afterCloser: ContextProof, restored: ContextProof
        let moveForwardCharacters: Int
        let pairUTF16Length: Int
        var replacementRange: NSRange? {
            guard let position=atEnd.position,position>=pairUTF16Length else{return nil}
            return NSRange(location:position-pairUTF16Length,length:pairUTF16Length)
        }
    }
    /// UIKit returns nil at an empty document edge. Preserve that distinction
    /// until this explicit insertion (or its current deletion step) proves the
    /// edge is empty; a missing nonempty side must never become an empty one.
    struct ProxyContext {
        let document: String
        let before: String?, after: String?
        let hasText: Bool
        init?(document:String?,selectionEmpty:Bool,before:String?,after:String?,hasText:Bool) {
            guard let document,!document.isEmpty,selectionEmpty else{return nil}
            self.document=document;self.before=before.map{String($0.suffix(16))}
            self.after=after.map{String($0.prefix(16))};self.hasText=hasText
        }
        fileprivate func resolving(_ proof:ContextProof)->EditContext? {
            guard document==proof.document else{return nil}
            return .init(document:document,selectionEmpty:true,
                         before:before ?? (proof.beforeEmpty ? "":nil),
                         after:after ?? (proof.afterEmpty ? "":nil))
        }
    }
    /// Serialized by the platform input owner. No disk, network or timer; a
    /// restart starts empty. Own synchronous callbacks are ignored only during
    /// the actual proxy call stack, while delayed callbacks must match proof.
    final class EmptyPairDeletion {
        private var plan: DeletionPlan?
        private var generation: UInt64 = 0
        private var mutationDepth = 0
        var isArmed: Bool {plan != nil}
        var isPerformingOwnMutation: Bool {mutationDepth>0}
        func invalidate() {generation &+= 1;plan=nil}
        func unrelatedEdit() {if mutationDepth==0 {invalidate()}}
        @discardableResult func performOwnMutation(_ body:()->Void) -> UInt64 {
            let token=generation;mutationDepth+=1;defer{mutationDepth-=1};body();return token
        }
        @discardableResult func arm(opening:String, insertion:Plan, before:EditContext?, token:UInt64) -> Bool {
            guard token==generation,let before,let closing=SymbolPairing.pairs[opening],
                  opening.utf16.count==1,closing.utf16.count==1,insertion.insertedText==opening+closing,
                  before.position.map({$0 <= Int.max-2}) ?? true,
                  insertion.caretBack==0 || insertion.caretBack==1 else {plan=nil;return false}
            let end=EditContext(document:before.document,position:before.position.map{$0+2},selectionEmpty:true,before:before.before+opening+closing,after:before.after)!
            let inside=EditContext(document:before.document,position:before.position.map{$0+1},selectionEmpty:true,before:before.before+opening,after:closing+before.after)!
            let afterCloser=EditContext(document:before.document,position:before.position.map{$0+1},selectionEmpty:true,before:before.before+opening,after:before.after)!
            plan=DeletionPlan(expected:ContextProof(insertion.caretBack>0 ? inside:end),atEnd:ContextProof(end),afterCloser:ContextProof(afterCloser),restored:ContextProof(before),moveForwardCharacters:insertion.caretBack>0 ? 1:0,pairUTF16Length:2)
            return true
        }
        /// Missing-edge fallback is restricted to our own just-finished insert.
        /// Existing adjacent brackets, inaccessible nonempty fields and stale
        /// readbacks cannot establish ownership merely by looking like a pair.
        @discardableResult func armVerifiedProxyInsertion(opening:String,insertion:Plan,before:ProxyContext?,after:ProxyContext?,token:UInt64)->Bool {
            guard token==generation,let before,let after,before.document==after.document,
                  !before.hasText || before.before != nil || before.after != nil,
                  after.hasText,let closing=SymbolPairing.pairs[opening],
                  insertion.insertedText==opening+closing,
                  let actualLeft=after.before else {plan=nil;return false}
            let inside=insertion.caretBack==1
            guard insertion.caretBack==0 || inside,
                  actualLeft.hasSuffix(inside ? opening:opening+closing),
                  !inside || after.after?.hasPrefix(closing)==true else {plan=nil;return false}
            // A missing baseline side can only be inferred empty when the
            // post-insert readback contains exactly our symbol on that side.
            // Keep known baseline windows intact: the proxy truncates its
            // window, so deriving them by stripping post-text loses a byte.
            let left=before.before ?? (actualLeft==(inside ? opening:opening+closing) ? "":nil)
            let right=before.after ?? ((inside ? after.after==closing:after.after?.isEmpty != false) ? "":nil)
            guard let baseline=EditContext(document:before.document,selectionEmpty:true,before:left,after:right),
                  arm(opening:opening,insertion:insertion,before:baseline,token:token),
                  let plan,plan.expected.matches(after.resolving(plan.expected)) else {self.plan=nil;return false}
            return true
        }
        func observeProxy(_ context:ProxyContext?) {
            guard mutationDepth==0,let plan else{return}
            if !plan.expected.matches(context?.resolving(plan.expected)) {invalidate()}
        }
        func consumeProxy(_ context:ProxyContext?)->DeletionPlan? {
            defer{invalidate()}
            guard let plan,plan.expected.matches(context?.resolving(plan.expected)) else{return nil}
            return plan
        }
        func observe(_ context:EditContext?) {
            guard mutationDepth==0,let plan else{return}
            if !plan.expected.matches(context) {invalidate()}
        }
        func consume(_ context:EditContext?) -> DeletionPlan? {
            defer{invalidate()}
            guard let plan,plan.expected.matches(context) else{return nil};return plan
        }
    }
    /// Public keyboard proxies do not have atomic range replacement. Confirm
    /// each step before requesting another delete. Once any mutation was sent,
    /// return true even if a host withholds confirmation: native fallback would
    /// risk deleting outside the pair. No later asynchronous continuation runs.
    static func deleteSequentially(_ plan:DeletionPlan,context:()->EditContext?,moveForward:(Int)->Void,deleteBackward:()->Void)->Bool {
        guard plan.expected.matches(context()) else{return false}
        if plan.moveForwardCharacters>0 {
            moveForward(plan.moveForwardCharacters)
            guard plan.atEnd.matches(context()) else{return true}
        }
        deleteBackward()
        if plan.restored.matches(context()) {return true} // Host already removed the whole empty pair.
        guard plan.afterCloser.matches(context()) else{return true}
        deleteBackward();return true
    }
    static func deleteProxySequentially(_ plan:DeletionPlan,context:()->ProxyContext?,moveForward:(Int)->Void,deleteBackward:()->Void)->Bool {
        func matches(_ proof:ContextProof)->Bool {proof.matches(context()?.resolving(proof))}
        guard matches(plan.expected) else{return false}
        if plan.moveForwardCharacters>0 {
            moveForward(plan.moveForwardCharacters)
            guard matches(plan.atEnd) else{return true}
        }
        deleteBackward()
        if matches(plan.restored) {return true}
        guard matches(plan.afterCloser) else{return true}
        deleteBackward();return true
    }
}
