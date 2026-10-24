import AppKit
import Carbon
import PrivateInputKit

/// A derived, bounded preview. Dismissal follows the system clipboard version,
/// so deleting or changing input fields cannot resurrect the same copy.
final class MacClipboardSuggestion {
    static let shared = MacClipboardSuggestion()
    struct Item: Equatable { let version: Int; let text: String; var deferred=false
        var preview: String { deferred ? "粘贴剪贴板":"剪贴板：" + String(text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(80)) }
    }
    private var observed: Int?, dismissed: Int?, item: Item?
    private var receiptItem:Item?,receiptApproved=false,receiptEpoch=UUID(),receiptGeneration:String?
    func update(version: Int, allowed: Bool, secure: Bool, read: () -> String?) -> Item? {
        guard allowed, !secure else { item=nil; observed=nil; return nil }
        guard dismissed != version else { return nil }
        if observed != version || item?.deferred == true {
            observed=version; item=nil
            if let text=read(), !text.isEmpty, !text.contains("\0"), text.utf8.count<=65536,
               text.contains(where: { !$0.isWhitespace }) { item=Item(version:version,text:text) }
        }
        return item
    }
    func dismiss(version: Int) { dismissed=version; item=nil }
    func discardPending() {
        guard receiptItem != nil,!receiptApproved else{return}
        receiptEpoch=UUID()
        if let item {dismiss(version:item.version)}
    }
    func leavePresentation() {
        receiptEpoch=UUID()
        if let item {dismiss(version:item.version)}
    }
    func deferred(version:Int,allowed:Bool,secure:Bool) -> Item? {
        guard allowed,!secure,dismissed != version else {item=nil;observed=nil;return nil}
        observed=version;let value=Item(version:version,text:"",deferred:true);item=value;return value
    }
    func take(_ expected: Item, version: Int, allowed: Bool, secure: Bool) -> String? {
        guard allowed, !secure, version==expected.version, item==expected, dismissed != version else { return nil }
        dismiss(version:version); return expected.text
    }
    static var permitted: Bool { UserDefaults(suiteName:LocalLearningCoordinator.groupID)?.bool(forKey:"clipboard-sharing-enabled") == true }
    func current() -> Item? {
        let board=NSPasteboard.general, version=board.changeCount
        if #available(macOS 15.4, *),board.accessBehavior != .alwaysAllow {
            // Reading the body here could put a system permission alert in the
            // typing path. An explicit paste click can request that access.
            return deferred(version:version,allowed:Self.permitted && board.availableType(from:[.string]) != nil,secure:IsSecureEventInputEnabled())
        }
        guard let value=update(version:version,allowed:Self.permitted,secure:IsSecureEventInputEnabled(),read:{
            let text=board.string(forType:.string)
            return board.changeCount==version ? text:nil
        }) else {return nil}
        let generation=AppleClipboardOnce.generation
        if receiptItem==value,receiptGeneration==generation {return receiptApproved ? value:nil}
        receiptItem=value;receiptApproved=false;receiptGeneration=generation
        let epoch=UUID();receiptEpoch=epoch
        // Disk/SQLite is never entered by the input-controller render path.
        DispatchQueue.global(qos:.utility).async { [weak self] in
            let fresh=(try? AppleClipboardOnce.claim(.candidate,texts:[value.text],generation:generation))?.first==true
            DispatchQueue.main.async { [weak self] in
                guard let self,self.receiptEpoch==epoch,self.item==value,self.dismissed != version,
                      NSPasteboard.general.changeCount==version,Self.permitted,!IsSecureEventInputEnabled(),AppleClipboardOnce.generation==generation else{return}
                if fresh {self.receiptApproved=true}else{self.dismiss(version:version)}
            }
        }
        return nil
    }
    func paste(_ expected:Item) -> String? {
        let board=NSPasteboard.general
        guard let text=take(expected,version:board.changeCount,allowed:Self.permitted,secure:IsSecureEventInputEnabled()) else{return nil}
        guard expected.deferred else{return text}
        guard let raw=board.string(forType:.string),board.changeCount==expected.version,
              !IsSecureEventInputEnabled(),Self.permitted,!raw.isEmpty,!raw.contains("\0"),raw.utf8.count<=65536,
              raw.contains(where:{!$0.isWhitespace}) else{return nil}
        return raw
    }
}
