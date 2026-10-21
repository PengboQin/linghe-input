import Foundation
import CryptoKit
import Darwin
import PrivateInputKit

/// Main-app provisioning shares clipboard-only derivatives. It never copies a
/// device signing seed, owner key, group root or legacy database to the keyboard.
private actor AppleClipboardLiveRevocationGate {
    static let shared=AppleClipboardLiveRevocationGate()
    private var running=false
    func begin()->Bool {guard !running else{return false};running=true;return true}
    func finish() {running=false}
}
enum AppleClipboardLiveStorage {
    static func store(createKey:Bool=false)throws->ClipboardLiveStore {
        guard let folder=LocalLearningCoordinator.sharedDirectory() else {throw ClipboardLiveError.unavailable}
        #if os(iOS)
        let key=try ClipboardCacheCoordinator.key(create:createKey)
        #else
        let key=try secret(account:"clipboard-live-cache",create:createKey)
        #endif
        return ClipboardLiveStore(directory:folder,key:key)
    }
    private static func secret(account:String,create:Bool)throws->SymmetricKey {
        #if os(iOS)
        guard let group=Bundle.main.object(forInfoDictionaryKey:"PrivateInputIdentityKeychainGroup") as? String,!group.isEmpty,!group.contains("$(") else {throw IdentityStoreError.corrupt}
        let secrets=try KeychainIdentityStore(account:account,accessGroup:group)
        #else
        let secrets=try KeychainIdentityStore(account:account)
        #endif
        if let data=try secrets.read() {guard data.count==32 else {throw IdentityStoreError.corrupt};return SymmetricKey(data:data)}
        guard create else {throw IdentityStoreError.absent}
        let key=SymmetricKey(size:.bits256),data=key.withUnsafeBytes{Data($0)}
        do {try secrets.insert(data)}catch IdentityStoreError.alreadyExists {return try secret(account:account,create:false)}
        return key
    }
    private static func management(needsStore:Bool=true)throws->AppleClipboardLiveManagement {
        guard Bundle.main.bundleIdentifier?.hasSuffix(".keyboard") != true,
              let folder=LocalLearningCoordinator.sharedDirectory() else {throw ClipboardLiveError.unavailable}
        let support=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        return AppleClipboardLiveManagement(store:needsStore ? try store(createKey:true):nil,directory:folder,
            journalDirectory:support.appendingPathComponent("PrivateInput/ClipboardLiveMain"),
            journalKey:try secret(account:"clipboard-live-revocations",create:true),
            preferences:UserDefaults(suiteName:LocalLearningCoordinator.groupID))
    }
    static func provision(scope:String,endpoint:URL,identity:DeviceIdentity,setup:GroupSetup,now:UInt64)throws {
        try management().provision(scope:scope,endpoint:endpoint,identity:identity,setup:setup,now:now)
    }
    static func revokeAndClear(identity:DeviceIdentity?,now:UInt64)throws {
        fence()
        try management().revokeAndClear(identity:identity,now:now)
    }
    static func fence() {
        let prefs=UserDefaults(suiteName:LocalLearningCoordinator.groupID)
        prefs?.removeObject(forKey:"clipboard-live-ready-scope")
        prefs?.removeObject(forKey:"clipboard-live-grant-generation")
        prefs?.removeObject(forKey:"clipboard-live-authority-blocked-generation")
        prefs?.removeObject(forKey:"clipboard-live-needs-refresh")
        prefs?.set(UUID().uuidString,forKey:"clipboard-live-cache-generation")
    }
    static func refreshPendingRevocations(identity:DeviceIdentity,now:UInt64)throws {
        try management(needsStore:false).refreshPendingRevocations(identity:identity,now:now)
    }
    static func sendPendingRevocations()async {
        // Journal snapshot/ack hold only short local locks, never across await.
        guard await AppleClipboardLiveRevocationGate.shared.begin() else {return}
        defer {Task {await AppleClipboardLiveRevocationGate.shared.finish()}}
        guard let manager=try? management(needsStore:false) else {return}
        let now=UInt64(Date().timeIntervalSince1970)
        guard let rows=try? manager.pendingRevocations(now:now) else {return}
        for row in rows.prefix(2) {
            guard row.request.issuedAt<=now,now-row.request.issuedAt<290 else {continue}
            do {
                try await ClipboardLiveClient(endpoint:row.endpoint).revoke(row.request)
                try manager.acknowledgeRevocation(row)
            } catch {continue} // Remains durable for a later authenticated retry.
        }
    }
}

/// Injectable local-only management for deterministic tests; no identity is
/// persisted. The main-only journal contains signed revokes, not private keys.
struct AppleClipboardLiveManagement {
    struct Pending:Codable,Equatable {
        let endpoint:URL,certificate:ClipboardLiveCertificate
        var request:ClipboardLiveRevocation
        static func ==(a:Self,b:Self)->Bool {a.endpoint==b.endpoint && a.certificate==b.certificate && a.request.nonce==b.request.nonce}
    }
    private struct Journal:Codable {var pending:[Pending]=[];var lastIssued:[String:UInt64]=[:]}
    let store:ClipboardLiveStore?,directory:URL,journalDirectory:URL,journalKey:SymmetricKey,preferences:UserDefaults?
    private func transaction<T>(_ body:(inout Journal)throws->T)throws->T {
        try FileManager.default.createDirectory(at:journalDirectory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let fd=open(journalDirectory.appendingPathComponent("journal.lock").path,O_CREAT|O_RDWR|O_NOFOLLOW,0o600)
        guard fd>=0 else {throw ClipboardLiveError.busy};defer{close(fd)}
        guard flock(fd,LOCK_EX|LOCK_NB)==0 else {throw ClipboardLiveError.busy};defer{flock(fd,LOCK_UN)}
        let file=journalDirectory.appendingPathComponent("revocations-v1.enc"),aad=Data("PrivateInput/clipboard-live-management/v1\0".utf8)
        var journal=Journal()
        if FileManager.default.fileExists(atPath:file.path) {
            let raw=try Data(contentsOf:file);guard raw.count<=1024*1024 else {throw ClipboardLiveError.quota}
            journal=try JSONDecoder().decode(Journal.self,from:ChaChaPoly.open(.init(combined:raw),using:journalKey,authenticating:aad))
        }
        let before=try JSONEncoder().encode(journal),result=try body(&journal),after=try JSONEncoder().encode(journal)
        if after != before {
            guard after.count<=1024*1024 else {throw ClipboardLiveError.quota}
            let sealed=try ChaChaPoly.seal(after,using:journalKey,authenticating:aad).combined
            #if os(iOS)
            try sealed.write(to:file,options:[.atomic,.completeFileProtection])
            #else
            try sealed.write(to:file,options:.atomic)
            #endif
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        }
        return result
    }
    private func key(_ certificate:ClipboardLiveCertificate)->String {certificate.group.uuidString+":"+certificate.parent.uuidString}
    private func queue(_ configuration:ClipboardLiveConfiguration,identity:DeviceIdentity?,now:UInt64)throws {
        guard let identity,identity.device==configuration.certificate.parent,
              identity.signingKey.publicKey.rawRepresentation==configuration.certificate.signingPublic else {throw ClipboardLiveError.invalid}
        let request=try ClipboardLiveRevocation.sign(certificate:configuration.certificate,signer:identity.signingKey,now:now)
        try transaction {journal in
            journal.lastIssued[key(configuration.certificate)]=max(journal.lastIssued[key(configuration.certificate)] ?? 0,configuration.certificate.issuedAt)
            journal.pending.removeAll{$0.certificate.expiresAt<=now}
            if !journal.pending.contains(where:{$0.certificate.generation==configuration.certificate.generation}) {
                guard journal.pending.count<128 else {throw ClipboardLiveError.quota}
                journal.pending.append(.init(endpoint:configuration.endpoint,certificate:configuration.certificate,request:request))
            }
        }
    }
    func provision(scope:String,endpoint:URL,identity:DeviceIdentity,setup:GroupSetup,now:UInt64)throws {
        guard let store else {throw ClipboardLiveError.unavailable}
        let member=try setup.membership.member(identity.device)
        guard member.permissions.contains(.clipboard),member.signingPublic==identity.signingKey.publicKey.rawRepresentation else {throw MembershipError.notMember}
        let group=setup.membership.statement.group,epoch=setup.membership.statement.epoch
        let prior=try store.managementSnapshot()
        let rejected=prior.map {prior in
            prior.configuration.scope==scope && preferences?.bool(forKey:"clipboard-live-needs-refresh")==true &&
            preferences?.string(forKey:"clipboard-live-authority-blocked-generation")==prior.configuration.certificate.generation.uuidString
        } ?? false
        if let prior,prior.configuration.scope==scope,prior.configuration.endpoint==endpoint,
           prior.configuration.certificate.group==group,prior.configuration.certificate.epoch==epoch,
           prior.configuration.certificate.parent==identity.device,
           prior.configuration.certificate.signingPublic==member.signingPublic {
            let certificate=prior.configuration.certificate
            if certificate.expiresAt>now {
                try prior.configuration.validate(now:now)
                let active=prior.pending.contains{$0.envelope.expiresAt>now}
                if !rejected && (certificate.expiresAt-now>86400 || active) {
                    preferences?.set(certificate.generation.uuidString,forKey:"clipboard-live-grant-generation")
                    preferences?.set(scope,forKey:"clipboard-live-ready-scope");return
                }
            }
        }
        // Prevent a keyboard from using the old grant while it is replaced.
        preferences?.removeObject(forKey:"clipboard-live-ready-scope")
        if rejected,let prior {
            // Do not reseal a rejected event with the same ID. The original
            // compatibility row retains its exact identity/TTL for the old FIFO.
            try store.quarantineRejectedPending(scope:scope,generation:prior.configuration.certificate.generation)
        }
        if let prior {try queue(prior.configuration,identity:identity,now:now)}
        if let prior,prior.configuration.scope != scope || prior.configuration.certificate.expiresAt<=now {try store.clear()}
        let issued=try transaction {journal -> UInt64 in
            let identifier=group.uuidString+":"+identity.device.uuidString
            let previous=max(journal.lastIssued[identifier] ?? 0,prior?.configuration.certificate.issuedAt ?? 0)
            guard previous<UInt64.max else {throw ClipboardLiveError.invalid}
            let issued=max(now,previous+1);guard issued<=now || issued-now<=300 else {throw ClipboardLiveError.invalid}
            journal.lastIssued[identifier]=issued;return issued
        }
        let delegate=Curve25519.Signing.PrivateKey()
        let certificate=try ClipboardLiveCertificate.issue(group:group,parent:identity.device,epoch:epoch,generation:UUID(),delegate:delegate,signer:identity.signingKey,now:issued)
        let senders=try setup.membership.statement.members.filter{$0.permissions.contains(.clipboard)}.map {try ClipboardLiveSenderKeys.derive(groupKey:setup.key,group:group,epoch:epoch,member:$0)}
        let configuration=ClipboardLiveConfiguration(scope:scope,endpoint:endpoint,certificate:certificate,delegatePrivate:delegate.rawRepresentation,senders:senders)
        try store.install(configuration,now:now)
        preferences?.set(UUID().uuidString,forKey:"clipboard-live-cache-generation")
        preferences?.set(certificate.generation.uuidString,forKey:"clipboard-live-grant-generation")
        preferences?.removeObject(forKey:"clipboard-live-needs-refresh")
        preferences?.removeObject(forKey:"clipboard-live-authority-blocked-generation")
        preferences?.set(scope,forKey:"clipboard-live-ready-scope")
        try refreshPendingRevocations(identity:identity,now:now)
    }
    func revokeAndClear(identity:DeviceIdentity?,now:UInt64)throws {
        preferences?.removeObject(forKey:"clipboard-live-ready-scope")
        preferences?.removeObject(forKey:"clipboard-live-grant-generation")
        preferences?.removeObject(forKey:"clipboard-live-needs-refresh")
        preferences?.removeObject(forKey:"clipboard-live-authority-blocked-generation")
        preferences?.set(UUID().uuidString,forKey:"clipboard-live-cache-generation")
        guard let store else {throw ClipboardLiveError.unavailable}
        var failure:Error?
        do {if let prior=try store.managementSnapshot() {try queue(prior.configuration,identity:identity,now:now)}}catch{failure=error}
        do {try store.clear()}catch{if failure==nil {failure=error}}
        if let failure {throw failure}
    }
    func refreshPendingRevocations(identity:DeviceIdentity,now:UInt64)throws {
        try transaction {journal in
            journal.pending.removeAll{$0.certificate.expiresAt<=now}
            for i in journal.pending.indices {
                let row=journal.pending[i]
                guard row.certificate.parent==identity.device,row.certificate.signingPublic==identity.signingKey.publicKey.rawRepresentation else {continue}
                if row.request.issuedAt>now || now-row.request.issuedAt>=290 {
                    journal.pending[i].request=try ClipboardLiveRevocation.sign(certificate:row.certificate,signer:identity.signingKey,now:now)
                }
            }
        }
    }
    func pendingRevocations(now:UInt64)throws->[Pending] {
        try transaction {journal in journal.pending.removeAll{$0.certificate.expiresAt<=now};return journal.pending}
    }
    func acknowledgeRevocation(_ value:Pending)throws {
        try transaction {journal in journal.pending.removeAll{$0.certificate.generation==value.certificate.generation && $0.request.nonce==value.request.nonce}}
    }
}
