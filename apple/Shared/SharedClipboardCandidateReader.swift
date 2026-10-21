import Foundation
import PrivateInputKit

#if os(iOS)
/// Read only previously consented encrypted local caches on a utility queue.
/// System pasteboard access stays in the native explicit-paste control.
enum SharedClipboardCandidateReader {
    static func read(scope:String,version:Int,now:UInt64)->String? {
        func permitted()->Bool {
            let p=UserDefaults(suiteName:LocalLearningCoordinator.groupID)
            return ClipboardCacheCoordinator.permitted(fullAccess:true) &&
                p?.bool(forKey:"automatic-clipboard-enabled")==true &&
                p?.bool(forKey:"automatic-clipboard-read-paused") != true &&
                p?.string(forKey:"automatic-clipboard-scope")==scope
        }
        guard permitted() else{return nil}
        var text=(try? ClipboardCacheCoordinator.pendingAutomatic(scope:scope,version:version,now:now))?.text
        if text==nil,let clips=try? ClipboardCacheCoordinator.read(fullAccess:true,now:now) {
            text=clips.first {clip in
                guard let origin=AutomaticClipboardOrigin.receivedOrigin(version:version,text:clip.text) else{return false}
                return origin.event==clip.eventID && origin.sender==clip.sender
            }?.text
        }
        return permitted() ? text:nil
    }
}
#endif
