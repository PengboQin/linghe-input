import Foundation
import CryptoKit

public enum ClipboardLiveError: Error { case invalid, unavailable, stale, busy, quota }

public struct ClipboardLiveCertificate: Codable, Equatable {
    public var version: UInt8 = 1
    public let group: UUID, parent: UUID, epoch: UInt64, generation: UUID
    public let signingPublic: Data, delegatePublic: Data
    public let issuedAt: UInt64, expiresAt: UInt64
    public var signature: Data
    public func canonical() throws -> Data {
        guard version == 1, epoch > 0, signingPublic.count == 32, delegatePublic.count == 32,
              expiresAt > issuedAt, expiresAt-issuedAt <= 2_592_000 else { throw ClipboardLiveError.invalid }
        var d=Data("PrivateInput/clipboard-live-certificate/v1\0".utf8)
        d.append(version);d.appendUUID(group);d.appendUUID(parent);d.appendBE(epoch);d.appendUUID(generation)
        d.append(signingPublic);d.append(delegatePublic);d.appendBE(issuedAt);d.appendBE(expiresAt);return d
    }
    public var digest: Data { get throws { Data(SHA256.hash(data:try canonical()+signature)) } }
    public static func issue(group:UUID,parent:UUID,epoch:UInt64,generation:UUID,delegate:Curve25519.Signing.PrivateKey,signer:Curve25519.Signing.PrivateKey,now:UInt64,lease:UInt64=2_592_000)throws->Self {
        guard lease>0,lease<=2_592_000,now<=UInt64.max-lease else {throw ClipboardLiveError.invalid}
        var c=Self(group:group,parent:parent,epoch:epoch,generation:generation,signingPublic:signer.publicKey.rawRepresentation,delegatePublic:delegate.publicKey.rawRepresentation,issuedAt:now,expiresAt:now+lease,signature:Data())
        c.signature=try signer.signature(for:c.canonical());return c
    }
    public func verify(publicKey:Data,group:UUID,epoch:UInt64,now:UInt64)throws {
        guard self.group==group,self.epoch==epoch,signingPublic==publicKey,signature.count==64,
              issuedAt<=now || issuedAt-now<=300,now<expiresAt,
              try Curve25519.Signing.PublicKey(rawRepresentation:publicKey).isValidSignature(signature,for:canonical()) else {throw ClipboardLiveError.invalid}
    }
}

/// Only clipboard-domain derivatives cross the app/keyboard boundary.
public struct ClipboardLiveSenderKeys: Codable, Equatable {
    public let sender: UUID, signingPublic: Data, legacy: Data, live: Data
    public static func derive(groupKey:SymmetricKey,group:UUID,epoch:UInt64,member:GroupMember)throws->Self {
        guard member.permissions.contains(.clipboard),epoch>0 else {throw ClipboardLiveError.invalid}
        let m=SecureEnvelope(group:group,sender:member.device,event:UUID(),epoch:epoch,sequence:1,domain:.clipboard,issuedAt:1,expiresAt:2,ciphertext:Data(),signature:Data())
        let old=try SecureMessage.domainKey(groupKey:groupKey,message:m,publicKey:member.signingPublic)
        var salt=Data();salt.appendUUID(group);salt.appendBE(epoch)
        var info=Data("PrivateInput/clipboard-live-key/v1\0".utf8);info.appendUUID(member.device);info.append(member.signingPublic)
        let next=HKDF<SHA256>.deriveKey(inputKeyMaterial:old,salt:salt,info:info,outputByteCount:32)
        return Self(sender:member.device,signingPublic:member.signingPublic,legacy:old.withUnsafeBytes{Data($0)},live:next.withUnsafeBytes{Data($0)})
    }
}

public struct ClipboardLiveEnvelope: Codable, Equatable {
    public var version: UInt8 = 1
    public let group:UUID,sender:UUID,event:UUID,epoch:UInt64,issuedAt:UInt64,expiresAt:UInt64
    public let nonce:Data,ciphertext:Data,certificate:ClipboardLiveCertificate
    public var signature:Data
    public func header()throws->Data {
        guard version==1,epoch>0,nonce.count==12,ciphertext.count<=65552,
              expiresAt>issuedAt,expiresAt-issuedAt<=600,
              certificate.group==group,certificate.parent==sender,certificate.epoch==epoch else {throw ClipboardLiveError.invalid}
        var d=Data("PrivateInput/clipboard-live-event/v1\0".utf8)
        d.append(version);d.appendUUID(group);d.appendUUID(sender);d.appendUUID(event);d.appendBE(epoch);d.appendBE(issuedAt);d.appendBE(expiresAt);d.append(nonce);d.append(try certificate.digest);return d
    }
    public static func seal(text:String,keys:ClipboardLiveSenderKeys,certificate:ClipboardLiveCertificate,delegate:Curve25519.Signing.PrivateKey,event:UUID=UUID(),now:UInt64,expiresAt:UInt64?=nil)throws->Self {
        let bytes=Data(text.utf8);try SecureMessage.validatePayload(bytes,domain:.clipboard)
        guard keys.sender==certificate.parent,keys.signingPublic==certificate.signingPublic,keys.live.count==32,
              delegate.publicKey.rawRepresentation==certificate.delegatePublic,now<=UInt64.max-600 else {throw ClipboardLiveError.invalid}
        let nonce=ChaChaPoly.Nonce();let n=nonce.withUnsafeBytes{Data($0)}
        let empty=Self(group:certificate.group,sender:certificate.parent,event:event,epoch:certificate.epoch,issuedAt:now,expiresAt:min(expiresAt ?? now+600,certificate.expiresAt),nonce:n,ciphertext:Data(),certificate:certificate,signature:Data())
        let box=try ChaChaPoly.seal(bytes,using:SymmetricKey(data:keys.live),nonce:nonce,authenticating:empty.header())
        var message=Self(group:empty.group,sender:empty.sender,event:event,epoch:empty.epoch,issuedAt:now,expiresAt:empty.expiresAt,nonce:n,ciphertext:box.ciphertext+box.tag,certificate:certificate,signature:Data())
        message.signature=try delegate.signature(for:message.header()+message.ciphertext);return message
    }
    public func open(keys:ClipboardLiveSenderKeys,group:UUID,epoch:UInt64,now:UInt64)throws->ReceivedClipboard {
        guard self.group==group,self.epoch==epoch,keys.sender==sender,keys.live.count==32,
              now<expiresAt,issuedAt<=now || issuedAt-now<=300,ciphertext.count>=16,signature.count==64 else {throw ClipboardLiveError.invalid}
        try certificate.verify(publicKey:keys.signingPublic,group:group,epoch:epoch,now:now)
        let h=try header(),pub=try Curve25519.Signing.PublicKey(rawRepresentation:certificate.delegatePublic)
        guard pub.isValidSignature(signature,for:h+ciphertext) else {throw ClipboardLiveError.invalid}
        let box=try ChaChaPoly.SealedBox(nonce:ChaChaPoly.Nonce(data:nonce),ciphertext:ciphertext.dropLast(16),tag:ciphertext.suffix(16))
        let raw=try ChaChaPoly.open(box,using:SymmetricKey(data:keys.live),authenticating:h)
        try SecureMessage.validatePayload(raw,domain:.clipboard)
        guard let text=String(data:raw,encoding:.utf8) else {throw ClipboardLiveError.invalid}
        return ReceivedClipboard(id:event,sender:sender,text:text,expiresAt:expiresAt)
    }
    public static func openLegacy(_ wire:Data,keys:ClipboardLiveSenderKeys,group:UUID,epoch:UInt64,now:UInt64)throws->ReceivedClipboard {
        let m=try SecureEnvelope.decode(wire)
        guard m.domain == .clipboard,m.group==group,m.epoch==epoch,m.sender==keys.sender,keys.legacy.count==32,
              now<m.expiresAt,m.issuedAt<=now || m.issuedAt-now<=300 else {throw ClipboardLiveError.invalid}
        let h=try m.header(),pub=try Curve25519.Signing.PublicKey(rawRepresentation:keys.signingPublic)
        guard pub.isValidSignature(m.signature,for:h+m.ciphertext) else {throw ClipboardLiveError.invalid}
        let box=try ChaChaPoly.SealedBox(nonce:m.nonce(),ciphertext:m.ciphertext.dropLast(16),tag:m.ciphertext.suffix(16))
        let raw=try ChaChaPoly.open(box,using:SymmetricKey(data:keys.legacy),authenticating:h)
        try SecureMessage.validatePayload(raw,domain:.clipboard)
        guard let text=String(data:raw,encoding:.utf8) else {throw ClipboardLiveError.invalid}
        return ReceivedClipboard(id:m.event,sender:m.sender,text:text,expiresAt:m.expiresAt)
    }
}

public struct ClipboardLiveRequest: Codable {
    public var version:UInt8=1
    public let group:UUID,sender:UUID,epoch:UInt64,nonce:UUID,issuedAt:UInt64,certificate:ClipboardLiveCertificate,body:Data
    public var signature:Data
    public func canonical()throws->Data {
        guard version==1,epoch>0,body.count<=131072,certificate.group==group,certificate.parent==sender,certificate.epoch==epoch else {throw ClipboardLiveError.invalid}
        var d=Data("PrivateInput/clipboard-live-request/v1\0".utf8);d.append(version);d.appendUUID(group);d.appendUUID(sender);d.appendBE(epoch);d.appendUUID(nonce);d.appendBE(issuedAt);d.append(try certificate.digest);d.append(Data(SHA256.hash(data:body)));return d
    }
    public static func signed(certificate:ClipboardLiveCertificate,delegate:Curve25519.Signing.PrivateKey,body:Data,now:UInt64)throws->Self {
        guard delegate.publicKey.rawRepresentation==certificate.delegatePublic else {throw ClipboardLiveError.invalid}
        var r=Self(group:certificate.group,sender:certificate.parent,epoch:certificate.epoch,nonce:UUID(),issuedAt:now,certificate:certificate,body:body,signature:Data())
        r.signature=try delegate.signature(for:r.canonical());return r
    }
}
public struct ClipboardLiveBatch: Codable {
    public let after:UInt64,limit:Int,publish:ClipboardLiveEnvelope?
    public init(after:UInt64,limit:Int=32,publish:ClipboardLiveEnvelope?=nil) {self.after=after;self.limit=limit;self.publish=publish}
    private enum CodingKeys:String,CodingKey {case after,limit,publish}
    public func encode(to encoder:Encoder)throws {
        guard after<=UInt64(Int64.max),(1...32).contains(limit) else {throw ClipboardLiveError.invalid}
        var c=encoder.container(keyedBy:CodingKeys.self);try c.encode(after,forKey:.after);try c.encode(limit,forKey:.limit)
        if let publish {try c.encode(publish,forKey:.publish)} else {try c.encodeNil(forKey:.publish)}
    }
}
public struct ClipboardLiveResponse: Codable {
    public struct Item: Codable {public let cursor:UInt64,kind:String,wire:Data}
    public let version:UInt8,accepted:UUID?,head:UInt64,next:UInt64,items:[Item]
    public func validate(after:UInt64)throws {
        guard version==1,head<=UInt64(Int64.max),next>=after,next<=head,items.count<=32,
              items.allSatisfy({$0.cursor>after && $0.cursor<=next && ["legacy","live"].contains($0.kind) && $0.wire.count<=131072}),
              zip(items,items.dropFirst()).allSatisfy({$0.0.cursor<$0.1.cursor}) else {throw ClipboardLiveError.invalid}
    }
}
public struct ClipboardLiveRevocation: Codable {
    public var version:UInt8=1
    public let group:UUID,parent:UUID,epoch:UInt64,generation:UUID,issuedAt:UInt64,nonce:UUID
    public var signature:Data
    public func canonical()throws->Data {
        guard version==1,epoch>0 else {throw ClipboardLiveError.invalid}
        var d=Data("PrivateInput/clipboard-live-revoke/v1\0".utf8);d.append(version);d.appendUUID(group);d.appendUUID(parent);d.appendBE(epoch);d.appendUUID(generation);d.appendBE(issuedAt);d.appendUUID(nonce);return d
    }
    public static func sign(certificate:ClipboardLiveCertificate,signer:Curve25519.Signing.PrivateKey,now:UInt64)throws->Self {
        guard signer.publicKey.rawRepresentation==certificate.signingPublic else {throw ClipboardLiveError.invalid}
        var r=Self(group:certificate.group,parent:certificate.parent,epoch:certificate.epoch,generation:certificate.generation,issuedAt:now,nonce:UUID(),signature:Data());r.signature=try signer.signature(for:r.canonical());return r
    }
}

public enum ClipboardLiveProjection {
    /// Stable IDs include sender and wire event; wire provenance stays explicit.
    public static func merge(_ primary:[ReceivedClipboard],_ secondary:[ReceivedClipboard],group:UUID,epoch:UInt64,now:UInt64)->[ReceivedClipboard] {
        var seen=Set<String>(),result:[ReceivedClipboard]=[]
        for clip in primary+secondary where clip.expiresAt>now {
            let identity=clip.sender.uuidString+"/"+clip.eventID.uuidString
            guard seen.insert(identity).inserted else {continue}
            var context=Data("PrivateInput/clipboard-presentation/v1\0".utf8)
            context.appendUUID(group);context.appendBE(epoch);context.appendUUID(clip.sender);context.appendUUID(clip.eventID)
            var b=Array(SHA256.hash(data:context).prefix(16));b[6]=(b[6]&15)|80;b[8]=(b[8]&63)|128
            let id=UUID(uuid:(b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
            result.append(.init(id:id,sender:clip.sender,text:clip.text,expiresAt:clip.expiresAt,wireEvent:clip.eventID))
        }
        return Array(result.sorted {a,b in a.expiresAt==b.expiresAt ? a.id.uuidString<b.id.uuidString:a.expiresAt<b.expiresAt}.suffix(32))
    }
}
