import Foundation
import CryptoKit
import Security
import Darwin
import PrivateInputKit

#if os(iOS)
enum ClipboardCacheCoordinator {
    private static var query: [String: Any] {
        get throws {
            guard let group = Bundle.main.object(forInfoDictionaryKey: "PrivateInputSharedKeychainGroup") as? String,
                  !group.isEmpty, !group.contains("$(") else { throw IdentityStoreError.corrupt }
            return [kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: "live.linghe.privateinput.clipboard-cache",
                    kSecAttrAccount as String: "v1", kSecAttrAccessGroup as String: group,
                    kSecAttrSynchronizable as String: false]
        }
    }
    static func key(create: Bool = false) throws -> SymmetricKey {
        var search = try query; search[kSecReturnData as String] = true; search[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &value)
        if status == errSecSuccess {
            guard let data = value as? Data, data.count == 32 else { throw IdentityStoreError.corrupt }
            return SymmetricKey(data: data)
        }
        guard status == errSecItemNotFound else { throw IdentityStoreError.osStatus(status) }
        guard create else { throw IdentityStoreError.absent }
        let material = SymmetricKey(size: .bits256), data = material.withUnsafeBytes { Data($0) }
        var insert = try query; insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let saved = SecItemAdd(insert as CFDictionary, nil)
        if saved == errSecDuplicateItem { return try key() }
        guard saved == errSecSuccess else { throw IdentityStoreError.osStatus(saved) }
        return material
    }
    static func clearForDeparture() throws {
        try cache().clear()
        clearAutomaticPending()
        let status=SecItemDelete(try query as CFDictionary)
        guard status==errSecSuccess || status==errSecItemNotFound else {throw IdentityStoreError.osStatus(status)}
    }
    static func cache() throws -> SharedClipboardCache {
        guard let folder = LocalLearningCoordinator.sharedDirectory() else { throw ClipboardCacheError.permissionRequired }
        return SharedClipboardCache(directory: folder)
    }
    static func read(fullAccess: Bool, now: UInt64) throws -> [ReceivedClipboard] {
        // Gate before Keychain lookup or decrypting any derived plaintext.
        let prefs = UserDefaults(suiteName: LocalLearningCoordinator.groupID)
        guard fullAccess, prefs?.bool(forKey: "clipboard-sharing-enabled") == true,
              let text = prefs?.string(forKey: "clipboard-group-id"), let group = UUID(uuidString: text) else {
            throw ClipboardCacheError.permissionRequired
        }
        let original=try cache().read(group:group,fullAccess:fullAccess,sharingEnabled:true,now:now,key:{try key()})
        if prefs?.bool(forKey:"automatic-clipboard-enabled")==true,
           let scope=prefs?.string(forKey:"automatic-clipboard-scope"),
           let live=try? AppleClipboardLiveStorage.store().snapshot(scope:scope,now:now),live.configuration.certificate.group==group {
            return ClipboardLiveProjection.merge(live.received,original,group:group,epoch:live.configuration.certificate.epoch,now:now)
        }
        return original
    }
    static func permitted(fullAccess: Bool) -> Bool {
        let prefs = UserDefaults(suiteName: LocalLearningCoordinator.groupID)
        guard fullAccess, prefs?.bool(forKey:"clipboard-sharing-enabled") == true,
              let value=prefs?.string(forKey:"clipboard-group-id"), UUID(uuidString:value) != nil else { return false }
        return true
    }
    private struct AutomaticPendingWire:Codable {let scopeDigest:String,sealed:Data}
    private struct AutomaticPending:Codable {
        let scope:String,text:String,digest:String,version:Int,createdAt:UInt64
    }
    private static var automaticPendingFile:URL? {LocalLearningCoordinator.sharedDirectory()?.appendingPathComponent("automatic-clipboard-pending-v1.json")}
    private static func pendingRead(scope:String,now:UInt64)throws->AutomaticPending? {
        guard let file=automaticPendingFile,FileManager.default.fileExists(atPath:file.path) else{return nil}
        let data=try Data(contentsOf:file);guard data.count<=128*1024 else{throw ClipboardCacheError.oversized}
        let wire=try JSONDecoder().decode(AutomaticPendingWire.self,from:data)
        let scopeDigest=SHA256.hash(data:Data(scope.utf8)).map{String(format:"%02x",$0)}.joined()
        guard wire.scopeDigest==scopeDigest else{return nil}
        let bytes=try ChaChaPoly.open(.init(combined:wire.sealed),using:key(),authenticating:Data(scope.utf8))
        let record=try JSONDecoder().decode(AutomaticPending.self,from:bytes)
        guard record.scope==scope,record.createdAt<=now,now-record.createdAt<=600,
              !record.text.isEmpty,!record.text.contains("\0"),record.text.utf8.count<=65536 else{return nil}
        return record
    }
    static func pendingAutomatic(scope:String,version:Int,now:UInt64)throws->(text:String,digest:String)? {
        guard let record=try pendingRead(scope:scope,now:now),record.version==version else{return nil}
        return (record.text,record.digest)
    }
    private static func withAutomaticLock<T>(_ body:()throws->T)throws->T {
        guard let directory=LocalLearningCoordinator.sharedDirectory() else{throw ClipboardCacheError.permissionRequired}
        let file=directory.appendingPathComponent("automatic-clipboard-pending.lock")
        let descriptor=open(file.path,O_CREAT|O_RDWR,0o600)
        guard descriptor>=0 else{throw ClipboardCacheError.invalidCache}
        defer{close(descriptor)}
        guard flock(descriptor,LOCK_EX)==0 else{throw ClipboardCacheError.invalidCache}
        defer{flock(descriptor,LOCK_UN)}
        return try body()
    }
    static func clearAutomaticPending(scope:String?=nil,digest:String?=nil) {
        try? withAutomaticLock {
            if let scope,let digest {
                guard let current=try pendingRead(scope:scope,now:UInt64(Date().timeIntervalSince1970)),current.digest==digest else{return}
            }
            if let file=automaticPendingFile {try? FileManager.default.removeItem(at:file)}
        }
    }
    private static func stashAutomatic(text:String,digest:String,version:Int,scope:String,now:UInt64)throws {
        guard !text.isEmpty,!text.contains("\0"),text.utf8.count<=65536,let file=automaticPendingFile else{throw ClipboardCacheError.oversized}
        let payload=try JSONEncoder().encode(AutomaticPending(scope:scope,text:text,digest:digest,version:version,createdAt:now))
        let box=try ChaChaPoly.seal(payload,using:key(),authenticating:Data(scope.utf8))
        let scopeDigest=SHA256.hash(data:Data(scope.utf8)).map{String(format:"%02x",$0)}.joined()
        let wire=try JSONEncoder().encode(AutomaticPendingWire(scopeDigest:scopeDigest,sealed:box.combined))
        try withAutomaticLock {
            let prefs=UserDefaults(suiteName:LocalLearningCoordinator.groupID)
            guard prefs?.bool(forKey:"automatic-clipboard-enabled")==true,
                  prefs?.string(forKey:"automatic-clipboard-scope")==scope else{throw ClipboardCacheError.permissionRequired}
            try wire.write(to:file,options:[.atomic,.completeFileProtection])
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        }
    }
    @MainActor private static var automaticKeyboardBridge=AutomaticClipboardBridge()
    @MainActor private static var lastStashed:(scope:String,digest:String)?
    @MainActor private static var automaticTask:Task<Void,Never>?
    @MainActor private static var automaticTaskEpoch=UUID()
    @MainActor private static var automaticPollGate=AutomaticClipboardPollGate()
    /// Unchanged visible ticks touch only preference/change-count metadata.
    /// Keychain, cache decryption and encrypted queue I/O run on utility tasks.
    @MainActor static func automaticKeyboardPass(fullAccess:Bool,sensitive:Bool=false,validating:@escaping @MainActor ()->Bool={true}) {
        let liveOwns=ClipboardLiveCoordinator.shared.tick(fullAccess:fullAccess,sensitive:sensitive,validating:validating)
        if liveOwns {
            automaticTaskEpoch=UUID();automaticTask?.cancel();automaticTask=nil
            automaticKeyboardBridge.pause();automaticPollGate.reset();return
        }
        let prefs=UserDefaults(suiteName:LocalLearningCoordinator.groupID)
        guard !sensitive,permitted(fullAccess:fullAccess),prefs?.bool(forKey:"automatic-clipboard-enabled")==true,
              let scope=prefs?.string(forKey:"automatic-clipboard-scope"),
              let deviceText=prefs?.string(forKey:"automatic-clipboard-device"),let device=UUID(uuidString:deviceText),validating() else {
            automaticTaskEpoch=UUID();automaticTask?.cancel();automaticTask=nil
            automaticKeyboardBridge.suspend();lastStashed=nil;automaticPollGate.reset();return
        }
        let version=NativeAutomaticClipboardBoard().version
        let fingerprint=scope+":"+String(version)+":"+(prefs?.string(forKey:"automatic-clipboard-cache-generation") ?? "")+":"+String(prefs?.bool(forKey:"automatic-clipboard-receive-ready")==true)+":"+String(prefs?.bool(forKey:"automatic-clipboard-outgoing-pending")==true)
        guard automaticTask==nil,automaticPollGate.begin(fingerprint) else{return}
        let epoch=UUID();automaticTaskEpoch=epoch
        automaticTask=Task {
            var succeeded=false
            defer{if automaticTaskEpoch==epoch {automaticTask=nil;automaticPollGate.finish(fingerprint,succeeded:succeeded)}}
            let now=UInt64(Date().timeIntervalSince1970)
            do {
                let loaded=try await Task.detached(priority:.utility) { () throws -> ([ReceivedClipboard],String?) in
                    let clips=try read(fullAccess:fullAccess,now:now)
                    let pending=try pendingRead(scope:scope,now:now)?.digest
                    return (clips,pending)
                }.value
                guard !Task.isCancelled,automaticTaskEpoch==epoch,validating(),
                      permitted(fullAccess:fullAccess),prefs?.bool(forKey:"automatic-clipboard-enabled")==true,
                      prefs?.string(forKey:"automatic-clipboard-scope")==scope,
                      NativeAutomaticClipboardBoard().version==version else {return}
                let snapshot=AutomaticClipboardSession(scope:scope,device:device,clips:loaded.0,outgoingPending:loaded.1 != nil || prefs?.bool(forKey:"automatic-clipboard-outgoing-pending")==true)
                if let upload=automaticKeyboardBridge.prepare(snapshot,importPending:false) {
                    if lastStashed?.scope==scope,lastStashed?.digest==upload.digest {
                        if loaded.1==nil {automaticKeyboardBridge.queued(upload,clearSharedPending:false);lastStashed=nil}
                    } else {
                        try await Task.detached(priority:.utility) {try stashAutomatic(text:upload.text,digest:upload.digest,version:version,scope:scope,now:now)}.value
                        guard !Task.isCancelled,automaticTaskEpoch==epoch,validating(),
                              prefs?.bool(forKey:"automatic-clipboard-enabled")==true,
                              prefs?.string(forKey:"automatic-clipboard-scope")==scope,
                              NativeAutomaticClipboardBoard().version==version else {return}
                        lastStashed=(scope,upload.digest)
                    }
                }
                automaticKeyboardBridge.begin()
                automaticKeyboardBridge.finish(snapshot,received:prefs?.bool(forKey:"automatic-clipboard-receive-ready")==true ? 0:1,now:now)
                succeeded=true
            } catch { /* bounded retry only on next visible tick */ }
        }
    }
    #if DEBUG
    static func privateIdentityAccessibleFromKeyboard() -> Bool {
        guard let shared = Bundle.main.object(forInfoDictionaryKey: "PrivateInputSharedKeychainGroup") as? String,
              shared.hasSuffix(".shared") else { return true }
        let privateGroup = String(shared.dropLast(".shared".count))
        let lookup: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "live.linghe.privateinput.sync",
                                    kSecAttrAccount as String: "primary", kSecAttrAccessGroup as String: privateGroup,
                                    kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var attributes: CFTypeRef?
        // No key bytes are requested or output. A successful shared-cache read
        // separately proves Keychain availability in the same keyboard process.
        return SecItemCopyMatching(lookup as CFDictionary, &attributes) == errSecSuccess
    }
    #endif
}
#endif
