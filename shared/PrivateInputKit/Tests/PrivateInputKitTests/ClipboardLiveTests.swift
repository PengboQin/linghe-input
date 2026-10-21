import XCTest
import CryptoKit
@testable import PrivateInputKit

final class ClipboardLiveTests:XCTestCase {
    private var fixture:[String:Any] {get throws {
        var p=URL(fileURLWithPath:#filePath);for _ in 0..<5 {p.deleteLastPathComponent()}
        return try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:p.appendingPathComponent("fixtures/protocol/clipboard-live-v1.json"))) as? [String:Any])
    }}
    private func decode<T:Decodable>(_ type:T.Type,_ value:Any)throws->T {try JSONDecoder().decode(type,from:JSONSerialization.data(withJSONObject:value))}
    private func raw(_ x:Any?)throws->Data {try XCTUnwrap(Data(base64Encoded:try XCTUnwrap(x as? String)))}
    private func hex(_ d:Data)->String {d.map{String(format:"%02x",$0)}.joined()}
    private func setup()throws->(ClipboardLiveConfiguration,UInt64) {
        let f=try fixture,c=try decode(ClipboardLiveCertificate.self,f["certificate"]!),now=try XCTUnwrap(f["serverNow"] as? UInt64)
        let k=ClipboardLiveSenderKeys(sender:c.parent,signingPublic:c.signingPublic,legacy:try raw(f["senderDomainKey"]),live:try raw(f["liveKey"]))
        return (.init(scope:"synthetic-live",endpoint:URL(string:"http://127.0.0.1:12345")!,certificate:c,delegatePrivate:try raw(f["delegateSeed"]),senders:[k]),now)
    }
    func testFrozenCrossLanguageVectorsAndOriginalBytes()throws {
        let f=try fixture,(c,now)=try setup(),keys=try XCTUnwrap(c.senders.first)
        XCTAssertEqual(hex(try c.certificate.canonical()),f["certificateCanonicalHex"] as? String)
        XCTAssertEqual(hex(try c.certificate.digest),f["certificateDigestHex"] as? String)
        try c.validate(now:now)
        let event=try decode(ClipboardLiveEnvelope.self,f["event"]!)
        XCTAssertEqual(hex(try event.header()),f["eventHeaderHex"] as? String)
        XCTAssertEqual(Data(try event.open(keys:keys,group:c.certificate.group,epoch:c.certificate.epoch,now:now).text.utf8),try raw(f["plaintextUTF8"]))
        let request=try decode(ClipboardLiveRequest.self,f["request"]!)
        XCTAssertEqual(hex(try request.canonical()),f["requestHeaderHex"] as? String)
        XCTAssertTrue(try Curve25519.Signing.PublicKey(rawRepresentation:c.certificate.delegatePublic).isValidSignature(request.signature,for:request.canonical()))
        let rev=try decode(ClipboardLiveRevocation.self,f["revoke"]!)
        XCTAssertEqual(hex(try rev.canonical()),f["revokeHeaderHex"] as? String)
        let legacy=try XCTUnwrap(f["legacy"] as? [String:Any]),wire=try JSONSerialization.data(withJSONObject:legacy["envelope"]!)
        let oldMessage=try SecureEnvelope.decode(wire)
        let oldKeys=ClipboardLiveSenderKeys(sender:oldMessage.sender,signingPublic:try raw(legacy["signingPublic"]),legacy:try raw(legacy["senderDomainKey"]),live:Data(repeating:0,count:32))
        XCTAssertEqual(Data(try ClipboardLiveEnvelope.openLegacy(wire,keys:oldKeys,group:oldMessage.group,epoch:oldMessage.epoch,now:now).text.utf8),try raw(legacy["plaintextUTF8"]))
    }
    func testDomainTrustAndCipherMutationRejected()throws {
        let f=try fixture,(c,now)=try setup(),e=try decode(ClipboardLiveEnvelope.self,f["event"]!),k=c.senders[0]
        XCTAssertThrowsError(try e.open(keys:k,group:UUID(),epoch:c.certificate.epoch,now:now))
        XCTAssertThrowsError(try e.open(keys:k,group:c.certificate.group,epoch:c.certificate.epoch+1,now:now))
        XCTAssertThrowsError(try e.open(keys:k,group:c.certificate.group,epoch:c.certificate.epoch,now:e.expiresAt))
        var bad=f["event"] as! [String:Any];bad["ciphertext"]=Data(repeating:1,count:e.ciphertext.count).base64EncodedString()
        XCTAssertThrowsError(try decode(ClipboardLiveEnvelope.self,bad).open(keys:k,group:c.certificate.group,epoch:c.certificate.epoch,now:now))
    }
    func testEncryptedStoreSingleLeaseColdCursorAndDurableOutbox()throws {
        let (c,now)=try setup(),directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:directory)}
        let key=SymmetricKey(size:.bits256),store=ClipboardLiveStore(directory:directory,key:key)
        try store.install(c,now:now)
        let first=try XCTUnwrap(store.claim(scope:c.scope,now:now));XCTAssertNil(try store.claim(scope:c.scope,now:now))
        let response=try decode(ClipboardLiveResponse.self,["version":1,"accepted":NSNull(),"head":5,"next":5,"items":[]])
        _ = try store.apply(response,request:first,published:nil,now:now)
        XCTAssertEqual(try store.snapshot(scope:c.scope,now:now)?.cursor,5)
        let text="unique raw\r\n  indented\n\nlast  "
        let id=try store.enqueue(text,scope:c.scope,version:10,now:now)
        XCTAssertEqual(try store.enqueue(text,scope:c.scope,version:10,now:now),id)
        let loaded=try XCTUnwrap(ClipboardLiveStore(directory:directory,key:key).snapshot(scope:c.scope,now:now))
        XCTAssertEqual(loaded.pending.count,1);XCTAssertEqual(loaded.compat.first?.id,id)
        XCTAssertFalse(try Data(contentsOf:directory.appendingPathComponent("clipboard-live-state-v1.enc")).contains(Data(text.utf8)))
        let claim=try XCTUnwrap(store.claim(scope:c.scope,now:now)),oldCursor=claim.cursor
        let invalid=try decode(ClipboardLiveResponse.self,["version":1,"accepted":UUID().uuidString,"head":6,"next":6,"items":[]])
        XCTAssertThrowsError(try store.apply(invalid,request:claim,published:id,now:now))
        XCTAssertEqual(try store.snapshot(scope:c.scope,now:now)?.cursor,oldCursor)
        XCTAssertEqual(try store.snapshot(scope:c.scope,now:now)?.pending.count,1)
        try store.release(try XCTUnwrap(claim.lease),scope:c.scope)
        XCTAssertNotNil(try store.claim(scope:c.scope,now:now))
    }
    func testUTF8BoundaryAndIndependentKeyDomain()throws {
        let (c,now)=try setup(),key=c.senders[0],d=try Curve25519.Signing.PrivateKey(rawRepresentation:c.delegatePrivate)
        XCTAssertNotEqual(key.legacy,key.live)
        let text=String(repeating:" ",count:65536),e=try ClipboardLiveEnvelope.seal(text:text,keys:key,certificate:c.certificate,delegate:d,now:now)
        XCTAssertEqual(Data(try e.open(keys:key,group:c.certificate.group,epoch:c.certificate.epoch,now:now).text.utf8),Data(text.utf8))
        XCTAssertThrowsError(try ClipboardLiveEnvelope.seal(text:text+"x",keys:key,certificate:c.certificate,delegate:d,now:now))
        XCTAssertThrowsError(try ClipboardLiveEnvelope.seal(text:"x\0y",keys:key,certificate:c.certificate,delegate:d,now:now))
    }

    func testPeerCopiesAdvanceWithoutReopeningAndCrossKindStayDeduplicated()throws {
        let (peer,now)=try setup(),signer=Curve25519.Signing.PrivateKey(),delegate=Curve25519.Signing.PrivateKey(),own=UUID()
        let ownCertificate=try ClipboardLiveCertificate.issue(group:peer.certificate.group,parent:own,epoch:peer.certificate.epoch,generation:UUID(),delegate:delegate,signer:signer,now:now)
        let ownKeys=ClipboardLiveSenderKeys(sender:own,signingPublic:signer.publicKey.rawRepresentation,legacy:Data(repeating:8,count:32),live:Data(repeating:9,count:32))
        let config=ClipboardLiveConfiguration(scope:"receiver",endpoint:peer.endpoint,certificate:ownCertificate,delegatePrivate:delegate.rawRepresentation,senders:[ownKeys,peer.senders[0]])
        let path=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:path)}
        let store=ClipboardLiveStore(directory:path,key:SymmetricKey(size:.bits256));try store.install(config,now:now)
        let first=try XCTUnwrap(store.claim(scope:config.scope,now:now))
        _ = try store.apply(decode(ClipboardLiveResponse.self,["version":1,"accepted":NSNull(),"head":0,"next":0,"items":[]]),request:first,published:nil,now:now)
        var last:ClipboardLiveEnvelope?
        for (i,text) in ["A\r\n  one  ","B\n\n two","C"].enumerated() {
            let event=try ClipboardLiveEnvelope.seal(text:text,keys:peer.senders[0],certificate:peer.certificate,delegate:Curve25519.Signing.PrivateKey(rawRepresentation:peer.delegatePrivate),now:now)
            let wire=try JSONEncoder().encode(event),claim=try XCTUnwrap(store.claim(scope:config.scope,now:now))
            let result=try decode(ClipboardLiveResponse.self,["version":1,"accepted":NSNull(),"head":i+1,"next":i+1,"items":[["cursor":i+1,"kind":"live","wire":wire.base64EncodedString()]]])
            _ = try store.apply(result,request:claim,published:nil,now:now);last=event
            XCTAssertEqual(try store.snapshot(scope:config.scope,now:now)?.received.last?.text,text)
        }
        XCTAssertEqual(try store.snapshot(scope:config.scope,now:now)?.received.count,3)
        let prior=try XCTUnwrap(last),claim=try XCTUnwrap(store.claim(scope:config.scope,now:now))
        let conflict=try ClipboardLiveEnvelope.seal(text:"changed same event",keys:peer.senders[0],certificate:peer.certificate,delegate:Curve25519.Signing.PrivateKey(rawRepresentation:peer.delegatePrivate),event:prior.event,now:now)
        let bad=try decode(ClipboardLiveResponse.self,["version":1,"accepted":NSNull(),"head":4,"next":4,"items":[["cursor":4,"kind":"live","wire":JSONEncoder().encode(conflict).base64EncodedString()]]])
        XCTAssertThrowsError(try store.apply(bad,request:claim,published:nil,now:now))
        XCTAssertEqual(try store.snapshot(scope:config.scope,now:now)?.cursor,3)
        try store.release(try XCTUnwrap(claim.lease),scope:config.scope)
        let f=try fixture,sign=try Curve25519.Signing.PrivateKey(rawRepresentation:raw(f["primarySeed"]))
        var old=SecureEnvelope(group:peer.certificate.group,sender:peer.certificate.parent,event:prior.event,epoch:peer.certificate.epoch,sequence:91,domain:.clipboard,issuedAt:now,expiresAt:now+500,ciphertext:Data(),signature:Data())
        let box=try ChaChaPoly.seal(Data("C".utf8),using:SymmetricKey(data:peer.senders[0].legacy),nonce:old.nonce(),authenticating:old.header())
        old.ciphertext=box.ciphertext+box.tag;old.signature=try sign.signature(for:old.header()+old.ciphertext)
        let legacy=try decode(ClipboardLiveResponse.self,["version":1,"accepted":NSNull(),"head":4,"next":4,"items":[["cursor":4,"kind":"legacy","wire":old.encoded().base64EncodedString()]]])
        let next=try XCTUnwrap(store.claim(scope:config.scope,now:now));_ = try store.apply(legacy,request:next,published:nil,now:now)
        XCTAssertEqual(try store.snapshot(scope:config.scope,now:now)?.received.count,3)
    }
    func testLegacyProjectionCannotBlockTwentySixCopies()throws {
        let (c,now)=try setup(),path=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:path)}
        let store=ClipboardLiveStore(directory:path,key:SymmetricKey(size:.bits256));try store.install(c,now:now)
        for i in 0..<26 {
            let event=try store.enqueue("copy \(i)",scope:c.scope,version:i,now:now)
            let claimed=try XCTUnwrap(store.claim(scope:c.scope,now:now)),response=try decode(ClipboardLiveResponse.self,["version":1,"accepted":event.uuidString,"head":0,"next":0,"items":[]])
            _ = try store.apply(response,request:claimed,published:event,now:now)
        }
        let state=try XCTUnwrap(store.snapshot(scope:c.scope,now:now))
        XCTAssertEqual(state.pending.count,0);XCTAssertEqual(state.compat.count,26)
    }
    func testExpiredPendingDoesNotPreventGrantRenewal()throws {
        let (c,now)=try setup(),f=try fixture,sign=try Curve25519.Signing.PrivateKey(rawRepresentation:raw(f["primarySeed"])),delegate=try Curve25519.Signing.PrivateKey(rawRepresentation:c.delegatePrivate)
        let cert=try ClipboardLiveCertificate.issue(group:c.certificate.group,parent:c.certificate.parent,epoch:c.certificate.epoch,generation:UUID(),delegate:delegate,signer:sign,now:now,lease:5)
        let old=ClipboardLiveConfiguration(scope:c.scope,endpoint:c.endpoint,certificate:cert,delegatePrivate:c.delegatePrivate,senders:c.senders)
        let path=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:path)}
        let store=ClipboardLiveStore(directory:path,key:SymmetricKey(size:.bits256));try store.install(old,now:now)
        _ = try store.enqueue("near expiry",scope:c.scope,version:1,now:now+3)
        XCTAssertEqual(try store.snapshot(scope:c.scope,now:now+3)?.pending.first?.envelope.expiresAt,now+5)
        XCTAssertThrowsError(try store.snapshot(scope:c.scope,now:now+6))
        XCTAssertNotNil(try store.managementSnapshot())
        let renewed=try ClipboardLiveCertificate.issue(group:cert.group,parent:cert.parent,epoch:cert.epoch,generation:UUID(),delegate:delegate,signer:sign,now:now+6)
        try store.install(.init(scope:c.scope,endpoint:c.endpoint,certificate:renewed,delegatePrivate:c.delegatePrivate,senders:c.senders),now:now+6)
        XCTAssertEqual(try store.snapshot(scope:c.scope,now:now+6)?.pending.count,0)
        XCTAssertNotNil(try store.claim(scope:c.scope,now:now+6))
    }
    func testCompositePresentationPreservesBothSendersAndWireProvenance()throws {
        let id=UUID(),a=ReceivedClipboard(id:id,sender:UUID(),text:"first",expiresAt:500),b=ReceivedClipboard(id:id,sender:UUID(),text:"second",expiresAt:500)
        let group=UUID(),result=ClipboardLiveProjection.merge([a,b],[a],group:group,epoch:1,now:100)
        XCTAssertEqual(result.count,2);XCTAssertNotEqual(result[0].id,result[1].id)
        XCTAssertTrue(result.allSatisfy{$0.eventID==id})
        XCTAssertEqual(ClipboardLiveProjection.merge(result,[a,b],group:group,epoch:1,now:100),result)
    }
}
