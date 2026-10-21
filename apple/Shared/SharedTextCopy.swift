import Foundation
import PrivateInputKit

/// A manual shared-text copy is still a received clipboard event. Keep its
/// origin so the automatic bridge cannot turn the same text into a new event.
@MainActor enum SharedTextCopy {
    static func automaticScope(preferences: UserDefaults?, personalEpoch: String) -> String? {
        guard let preferences,
              preferences.bool(forKey: "clipboard-sharing-enabled"),
              preferences.bool(forKey: "automatic-clipboard-enabled"),
              let groupText=preferences.string(forKey:"clipboard-group-id"),let group=UUID(uuidString:groupText),
              let generation=preferences.string(forKey:"automatic-clipboard-consent-generation"),
              let scope=preferences.string(forKey:"automatic-clipboard-scope") else {return nil}
        let parts=scope.split(separator:":",omittingEmptySubsequences:false)
        guard parts.count==4,UUID(uuidString:String(parts[0]))==group,UInt64(parts[1]) != nil,
              String(parts[2])==personalEpoch,String(parts[3])==generation else {return nil}
        return scope
    }
    @discardableResult static func copy(_ clip:ReceivedClipboard,now:UInt64,scope:String?,
                                        board:(any AutomaticClipboardBoard)?=nil,
                                        recordOrigin:(String,Int,String,UUID,UUID)->Void = {AutomaticClipboardOrigin.record(scope:$0,version:$1,digest:$2,event:$3,sender:$4)},
                                        recordArchive:(Int,UUID,UUID)->Void = {ActivityArchiveCapture.shared.noteSyncedClipboardWrite(version:$0,event:$1,sender:$2);ActivityArchiveCapture.shared.observeClipboardIfPermitted()}) -> Bool {
        guard clip.expiresAt>now,AutomaticClipboardBridge.valid(clip.text) else {return false}
        let board=board ?? NativeAutomaticClipboardBoard()
        guard board.writeText(clip.text) else {return false}
        let version=board.version
        if let scope {recordOrigin(scope,version,AutomaticClipboardBridge.digest(clip.text),clip.eventID,clip.sender)}
        recordArchive(version,clip.eventID,clip.sender)
        return true
    }
}

extension DeviceSyncModel {
    /// Re-resolve the live snapshot; a captured row may have expired or been
    /// removed while its reading page is still on screen.
    @discardableResult func copySharedText(id:UUID,now:UInt64=UInt64(Date().timeIntervalSince1970)) -> Bool {
        guard sharedText(id:id,now:now) != nil,let clip=info.clips.first(where:{$0.id==id}) else {return false}
        let scope=SharedTextCopy.automaticScope(preferences:UserDefaults(suiteName:LocalLearningCoordinator.groupID),personalEpoch:PersonalDataReset.generation)
        return SharedTextCopy.copy(clip,now:now,scope:scope)
    }
}
