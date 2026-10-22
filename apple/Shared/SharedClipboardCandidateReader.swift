import Foundation
import PrivateInputKit

#if os(iOS)
/// Read only previously consented encrypted local caches on a utility queue.
/// Pasteboard bodies are supplied only by the already-authorized automatic
/// bridge or an explicit paste action; candidate rendering never reads them.
enum SharedClipboardCandidateReader {
    enum Result {case unavailable,consumed,text(String,source:ClipboardPreviewCache.Source)}
    static func read(scope:String,version:Int,now:UInt64,generation:String)->Result {
        func permitted()->Bool {
            let p=UserDefaults(suiteName:LocalLearningCoordinator.groupID)
            return ClipboardCacheCoordinator.permitted(fullAccess:true) &&
                p?.bool(forKey:"automatic-clipboard-enabled")==true &&
                p?.string(forKey:"automatic-clipboard-scope")==scope
        }
        guard permitted(),AppleClipboardOnce.generation==generation else{return .unavailable}
        let preview=try? ClipboardCacheCoordinator.currentPreview(scope:scope,version:version,generation:generation,now:now)
        var text=preview?.text
        let source=preview?.source ?? .localRead
        let localReadAllowed=UserDefaults(suiteName:LocalLearningCoordinator.groupID)?.bool(forKey:"automatic-clipboard-read-paused") != true
        if text==nil,localReadAllowed {text=(try? ClipboardCacheCoordinator.pendingAutomatic(scope:scope,version:version,now:now))?.text}
        if text==nil,localReadAllowed,let clips=try? ClipboardCacheCoordinator.read(fullAccess:true,now:now) {
            text=clips.first {clip in
                guard let origin=AutomaticClipboardOrigin.receivedOrigin(version:version,text:clip.text) else{return false}
                return origin.event==clip.eventID && origin.sender==clip.sender
            }?.text
        }
        guard let text,permitted(),AppleClipboardOnce.generation==generation,
              source == .receivedWrite || UserDefaults(suiteName:LocalLearningCoordinator.groupID)?.bool(forKey:"automatic-clipboard-read-paused") != true else{return .unavailable}
        // Claim before publication, even if a new edit makes the completion
        // stale. An unused automatic suggestion is not a retry instruction.
        guard let fresh=try? AppleClipboardOnce.claim(.candidate,texts:[text],generation:generation),permitted(),AppleClipboardOnce.generation==generation else{return .consumed}
        return fresh.first==true ? .text(text,source:source):.consumed
    }
}
#endif
