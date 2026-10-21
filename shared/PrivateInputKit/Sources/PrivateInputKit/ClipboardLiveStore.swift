import Foundation
import CryptoKit
import Darwin

public struct ClipboardLiveConfiguration: Codable, Equatable {
    public let scope:String,endpoint:URL,certificate:ClipboardLiveCertificate,delegatePrivate:Data,senders:[ClipboardLiveSenderKeys]
    public init(scope:String,endpoint:URL,certificate:ClipboardLiveCertificate,delegatePrivate:Data,senders:[ClipboardLiveSenderKeys]) {
        self.scope=scope;self.endpoint=endpoint;self.certificate=certificate;self.delegatePrivate=delegatePrivate;self.senders=senders
    }
    public func validate(now:UInt64)throws {
        _ = try RelayClient(endpoint:endpoint,allowLoopbackHTTP:true)
        guard !scope.isEmpty,scope.utf8.count<=512,delegatePrivate.count==32,!senders.isEmpty,senders.count<=64,
              Set(senders.map(\.sender)).count==senders.count,
              senders.allSatisfy({$0.signingPublic.count==32 && $0.legacy.count==32 && $0.live.count==32}),
              let own=senders.first(where:{$0.sender==certificate.parent}),
              try Curve25519.Signing.PrivateKey(rawRepresentation:delegatePrivate).publicKey.rawRepresentation==certificate.delegatePublic else {throw ClipboardLiveError.invalid}
        try certificate.verify(publicKey:own.signingPublic,group:certificate.group,epoch:certificate.epoch,now:now)
    }
}
public struct ClipboardLivePending: Codable, Equatable {
    public let envelope:ClipboardLiveEnvelope
    public var id:UUID {envelope.event}
}
public struct ClipboardLiveSnapshot: Codable {
    public var configuration:ClipboardLiveConfiguration
    public var cursor:UInt64?
    public var pending:[ClipboardLivePending]=[]
    public var received:[ReceivedClipboard]=[]
    public var compat:[ReceivedClipboard]=[]
    public var failed:[ClipboardLivePending]=[]
    public var seen:[String:UInt64]=[:]
    public var receipts:[String:Data]=[:]
    public var revision:UInt64=0
    public var lease:UUID?
    public var leaseUntil:UInt64?
    public var lastLocalVersion:Int?
    public var lastLocalDigest:Data?
    public var lastLocalEvent:UUID?
    public init(configuration:ClipboardLiveConfiguration) {self.configuration=configuration}
}
/// Independent encrypted transactions. No old relay database, sequence or ACK.
/// All callers run on utility workers. The short lock is never held over await.
public struct ClipboardLiveStore {
    private let folder:URL,key:SymmetricKey
    public init(directory:URL,key:SymmetricKey) {folder=directory;self.key=key}
    private var file:URL {folder.appendingPathComponent("clipboard-live-state-v1.enc")}
    private static let aad=Data("PrivateInput/clipboard-live-local-state/v1\0".utf8)
    private func transaction<T>(_ body:(inout ClipboardLiveSnapshot? )throws->T)throws->T {
        guard key.bitCount==256 else {throw ClipboardLiveError.invalid}
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let lock=folder.appendingPathComponent("clipboard-live-state-v1.lock")
        let fd=open(lock.path,O_CREAT|O_RDWR|O_NOFOLLOW,0o600);guard fd>=0 else {throw ClipboardLiveError.busy}
        defer{close(fd)};guard flock(fd,LOCK_EX|LOCK_NB)==0 else {throw ClipboardLiveError.busy};defer{flock(fd,LOCK_UN)}
        var state:ClipboardLiveSnapshot?
        if FileManager.default.fileExists(atPath:file.path) {
            let bytes=try Data(contentsOf:file);guard bytes.count<=4*1024*1024 else {throw ClipboardLiveError.quota}
            let raw=try ChaChaPoly.open(ChaChaPoly.SealedBox(combined:bytes),using:key,authenticating:Self.aad)
            state=try JSONDecoder().decode(ClipboardLiveSnapshot.self,from:raw)
        }
        let before=try state.map{try JSONEncoder().encode($0)}
        let result=try body(&state)
        if let state {
            let raw=try JSONEncoder().encode(state);guard raw.count<=4*1024*1024 else {throw ClipboardLiveError.quota}
            if before != raw {
                let sealed=try ChaChaPoly.seal(raw,using:key,authenticating:Self.aad).combined
                #if os(iOS)
                try sealed.write(to:file,options:[.atomic,.completeFileProtection])
                #else
                try sealed.write(to:file,options:.atomic)
                #endif
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
            }
        } else if FileManager.default.fileExists(atPath:file.path) {try FileManager.default.removeItem(at:file)}
        return result
    }
    /// Main-app management only: inspect an expired grant to revoke or replace it.
    /// Daily workers continue to use the strict snapshot/claim APIs.
    public func managementSnapshot()throws->ClipboardLiveSnapshot? {try transaction{$0}}
    public func snapshot(scope:String?=nil,now:UInt64)throws->ClipboardLiveSnapshot? {
        try transaction { state in
            guard let s=state else{return nil}
            guard scope==nil || s.configuration.scope==scope else {throw ClipboardLiveError.stale}
            try s.configuration.validate(now:now);return s
        }
    }
    public func install(_ configuration:ClipboardLiveConfiguration,now:UInt64)throws {
        try configuration.validate(now:now)
        try transaction {state in
            if state?.configuration.scope != configuration.scope {state=ClipboardLiveSnapshot(configuration:configuration)}
            else if var prior=state {
                prior.pending.removeAll{$0.envelope.expiresAt<=now};prior.compat.removeAll{$0.expiresAt<=now};state=prior
                guard prior.configuration.certificate.parent==configuration.certificate.parent,
                      prior.configuration.certificate.group==configuration.certificate.group,
                      prior.configuration.certificate.epoch==configuration.certificate.epoch else {throw ClipboardLiveError.stale}
                // Keep a nonexpired grant stable across app/keyboard processes.
                // Rotation is only allowed once its short-lived outbox is empty.
                if prior.configuration.certificate != configuration.certificate,!prior.pending.isEmpty {throw ClipboardLiveError.busy}
                state?.configuration=configuration
            }
        }
    }
    public func enqueue(_ text:String,scope:String,version:Int,now:UInt64)throws->UUID {
        try transaction {state in
            guard var s=state,s.configuration.scope==scope else {throw ClipboardLiveError.stale}
            try s.configuration.validate(now:now)
            let digest=Data(SHA256.hash(data:Data(text.utf8)))
            if s.lastLocalVersion==version,s.lastLocalDigest==digest,let id=s.lastLocalEvent {return id}
            s.pending.removeAll{$0.envelope.expiresAt<=now};s.compat.removeAll{$0.expiresAt<=now}
            guard s.pending.count<16,
                  let own=s.configuration.senders.first(where:{$0.sender==s.configuration.certificate.parent}) else {throw ClipboardLiveError.quota}
            let delegate=try Curve25519.Signing.PrivateKey(rawRepresentation:s.configuration.delegatePrivate)
            let envelope=try ClipboardLiveEnvelope.seal(text:text,keys:own,certificate:s.configuration.certificate,delegate:delegate,now:now)
            s.lastLocalVersion=version;s.lastLocalDigest=digest;s.lastLocalEvent=envelope.event
            s.pending.append(.init(envelope:envelope))
            s.compat.append(.init(id:envelope.event,sender:envelope.sender,text:text,expiresAt:envelope.expiresAt))
            // This bounded legacy projection must never block the new feed.
            // Activity archival is a separate durable pipeline.
            while s.compat.count>64 {s.compat.removeFirst()}
            while (try JSONEncoder().encode(s.compat).count)>512*1024 {s.compat.removeFirst()}
            s.revision &+= 1;state=s;return envelope.event
        }
    }
    /// The request's exact cursor/configuration fences an older async response.
    /// Authenticate every item before advancing; failures leave all state intact.
    public func apply(_ response:ClipboardLiveResponse,request:ClipboardLiveSnapshot,published:UUID?,now:UInt64)throws->Int {
        let after=request.cursor ?? 0;try response.validate(after:after)
        guard response.accepted==published else {throw ClipboardLiveError.invalid}
        let config=request.configuration
        var opened:[ReceivedClipboard]=[]
        var fingerprints:[String:Data]=[:]
        for item in response.items {
            let sender:UUID
            if item.kind=="legacy" {sender=try SecureEnvelope.decode(item.wire).sender}
            else {sender=try JSONDecoder().decode(ClipboardLiveEnvelope.self,from:item.wire).sender}
            guard let keys=config.senders.first(where:{$0.sender==sender}) else {throw ClipboardLiveError.invalid}
            let clip:ReceivedClipboard
            if item.kind=="legacy" {clip=try ClipboardLiveEnvelope.openLegacy(item.wire,keys:keys,group:config.certificate.group,epoch:config.certificate.epoch,now:now)}
            else {clip=try JSONDecoder().decode(ClipboardLiveEnvelope.self,from:item.wire).open(keys:keys,group:config.certificate.group,epoch:config.certificate.epoch,now:now)}
            let identity=item.kind+"/"+clip.sender.uuidString+"/"+clip.eventID.uuidString
            let canonical:Data
            if item.kind=="legacy" {let m=try SecureEnvelope.decode(item.wire);canonical=try m.header()+m.ciphertext}
            else {let m=try JSONDecoder().decode(ClipboardLiveEnvelope.self,from:item.wire);canonical=try m.header()+m.ciphertext}
            let digest=Data(SHA256.hash(data:canonical))
            if let prior=fingerprints[identity],prior != digest {throw ClipboardLiveError.invalid}
            fingerprints[identity]=digest;opened.append(clip)
        }
        return try transaction {state in
            guard var s=state,s.configuration==config,s.cursor==request.cursor,s.lease==request.lease,request.lease != nil,(s.leaseUntil ?? 0)>now else {throw ClipboardLiveError.stale}
            for (identity,digest) in fingerprints {
                if let prior=s.receipts[identity],prior != digest {throw ClipboardLiveError.invalid}
                s.receipts[identity]=digest
            }
            if let published {s.pending.removeAll{$0.id==published}}
            s.pending.removeAll{$0.envelope.expiresAt<=now};s.received.removeAll{$0.expiresAt<=now};s.compat.removeAll{$0.expiresAt<=now};s.seen=s.seen.filter{$0.value>now}
            // First successful pass establishes the head, without overwriting
            // the local board with preexisting history on a cold activation.
            if request.cursor==nil {
                for clip in opened {s.seen[clip.sender.uuidString+"/"+clip.eventID.uuidString]=clip.expiresAt}
                s.cursor=response.head
            }
            else {
                for clip in opened where clip.sender != config.certificate.parent {
                    let identity=clip.sender.uuidString+"/"+clip.eventID.uuidString
                    if s.seen[identity]==nil {s.seen[identity]=clip.expiresAt;s.received.append(clip)}
                }
                s.cursor=response.next
            }
            s.received=Array(s.received.suffix(32))
            while (try JSONEncoder().encode(s.received).count)>512*1024 {s.received.removeFirst()}
            s.seen=Dictionary(uniqueKeysWithValues:s.seen.sorted{$0.value>$1.value}.prefix(512).map{($0.key,$0.value)})
            s.lease=nil;s.leaseUntil=nil;s.receipts=s.receipts.filter { key,_ in
                let parts=key.split(separator:"/",maxSplits:1).map(String.init)
                return parts.count==2 && s.seen[parts[1]] != nil
            }
            s.revision &+= 1;state=s;return opened.count
        }
    }
    /// A rejected delegation cannot drain its old signed events. Preserve a
    /// bounded diagnostic projection and the original legacy compatibility rows.
    public func quarantineRejectedPending(scope:String,generation:UUID)throws {
        try transaction {s in
            guard var current=s,current.configuration.scope==scope,current.configuration.certificate.generation==generation else {throw ClipboardLiveError.stale}
            current.failed=Array((current.failed+current.pending).suffix(16));current.pending=[]
            current.lease=nil;current.leaseUntil=nil;current.revision &+= 1;s=current
        }
    }
    public func claim(scope:String,now:UInt64)throws->ClipboardLiveSnapshot? {
        try transaction {state in
            guard var s=state,s.configuration.scope==scope else {throw ClipboardLiveError.stale}
            try s.configuration.validate(now:now)
            guard s.lease==nil || (s.leaseUntil ?? 0)<=now else {return nil}
            s.pending.removeAll{$0.envelope.expiresAt<=now};s.lease=UUID();s.leaseUntil=now+30;state=s;return s
        }
    }
    public func release(_ lease:UUID,scope:String)throws {
        try transaction {s in
            guard s?.configuration.scope==scope,s?.lease==lease else {return}
            s?.lease=nil;s?.leaseUntil=nil
        }
    }
    public func acknowledgeCompatibility(_ event:UUID,scope:String)throws {
        try transaction {s in guard s?.configuration.scope==scope else {throw ClipboardLiveError.stale};s?.compat.removeAll{$0.id==event}}
    }
    public func clear()throws {try transaction{$0=nil}}
}
