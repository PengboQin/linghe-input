import Foundation
import CoreFoundation
import PrivateInputKit

/// Cooperative reset barrier shared by App and keyboard; no reset during upgrade.
enum PersonalDataReset {
    private static let observersLock=NSLock()
    private static var observers:[UUID:()->Void]=[:]
    private static var observing=false
    static func observe(_ action:@escaping ()->Void) -> UUID {
        observersLock.lock();defer{observersLock.unlock()}
        if !observing {
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),nil,{_,_,_,_,_ in
                DispatchQueue.main.async {
                    PersonalDataReset.observersLock.lock();let callbacks=Array(PersonalDataReset.observers.values);PersonalDataReset.observersLock.unlock()
                    for callback in callbacks {callback()}
                }
            },notification.rawValue,nil,.deliverImmediately)
            observing=true
        }
        let id=UUID();observers[id]=action;return id
    }
    static func unobserve(_ id:UUID) {observersLock.lock();observers.removeValue(forKey:id);observersLock.unlock()}
    static let marker="privacy-reset-generation-v1.txt"
    static var directory:URL? {PersonalLexiconLocation.directory}
    static var generation:String {
        guard let directory,let value=try? String(contentsOf:directory.appendingPathComponent(marker),encoding:.utf8),UUID(uuidString:value) != nil else {return "initial"}
        return value
    }
    static var notification:CFNotificationName {CFNotificationName("live.linghe.privateinput.personal-reset" as CFString)}
    static func request(reason:String) throws {
        guard let root=directory else {throw InputDataError.invalidRecord}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try Data(UUID().uuidString.utf8).write(to:root.appendingPathComponent(marker),options:.atomic)
        let prefs=UserDefaults(suiteName:LocalLearningCoordinator.groupID)
        prefs?.set(reason,forKey:"privacy-departed-reason")
        prefs?.set(false,forKey:"learning-sharing-enabled");prefs?.set(false,forKey:"clipboard-sharing-enabled")
        prefs?.removeObject(forKey:"clipboard-group-id");prefs?.removeObject(forKey:"mobile-group-expiry")
        try removeSharedData(root)
        var failure:Error?
        let clear={do {try NativeEngine.clearOwnedDataAfterConfirmedReset()} catch {failure=error}}
        if Thread.isMainThread {clear()} else {DispatchQueue.main.sync(execute:clear)}
        if let failure {throw failure}
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),notification,nil,nil,true)
    }
    static func checkLocalDeadline() throws {
        #if os(iOS)
        let prefs=UserDefaults(suiteName:LocalLearningCoordinator.groupID),deadline=prefs?.double(forKey:"mobile-group-expiry") ?? 0
        if deadline>0,Date().timeIntervalSince1970>=deadline {try request(reason:"inactive")}
        #endif
    }
    static func needsApply(base:URL,epoch:String?=nil) -> Bool {
        let current=epoch ?? generation,applied=try? String(contentsOf:base.appendingPathComponent("privacy-applied-v1.txt"),encoding:.utf8)
        return current != "initial" && applied != current
    }
    static func applyLocal(base:URL,epoch:String?=nil,shared:URL?=directory) throws {
        let current=epoch ?? generation
        if current != "initial",needsApply(base:base,epoch:current) {
            let names=["Rime","nine-choice-memory-v1.json","nine-choice-memory-v2.json","nine-choice-memory-v3.json","learning-checkpoint-v1.json","learning-import-pending-v1.json","learning-runtime-v2.json","learning-recency-v2.json","learning-recency-anchor-v2.json","local-replica-id.txt","Shared","personal-lexicon-v1.json","personal-replica-id.txt","symbol-usage-v1.json"]
            for name in names {try remove(base.appendingPathComponent(name))}
            for item in (try? FileManager.default.contentsOfDirectory(at:base,includingPropertiesForKeys:nil)) ?? [] {
                if item.lastPathComponent.hasPrefix("Checkpoint-"),UUID(uuidString:String(item.lastPathComponent.dropFirst(11))) != nil {try remove(item)}
            }
            UserDefaults.standard.removeObject(forKey:"symbol-usage-v1")
            if let shared {try removeSharedData(shared)}
        }
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
        try Data(current.utf8).write(to:base.appendingPathComponent("privacy-applied-v1.txt"),options:.atomic)
    }
    private static func removeSharedData(_ root:URL) throws {
        try ActivityArchiveLocation.purgeForConfirmedDeparture(root:root)
        for name in ["personal-lexicon-v1.json","personal-replica-id.txt","learning-v1.json","learning-recency-v2.json","learning-recency-anchor-v2.json","clipboard-cache-v1.json"] {try remove(root.appendingPathComponent(name))}
    }
    private static func remove(_ url:URL) throws {
        guard !((try? url.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) ?? false) else {throw InputDataError.invalidRecord}
        if FileManager.default.fileExists(atPath:url.path) {
            do {try FileManager.default.removeItem(at:url)}
            catch let error as NSError where error.domain==NSCocoaErrorDomain && error.code==NSFileNoSuchFileError {}
        }
    }
}
