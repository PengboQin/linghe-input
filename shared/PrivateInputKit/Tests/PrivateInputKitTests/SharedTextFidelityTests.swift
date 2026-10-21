import XCTest
import CryptoKit
import PrivateInputKit

final class SharedTextFidelityTests: XCTestCase {
    // UTF8 equality matters: Swift String equality alone normalizes canonically
    // equivalent Unicode and would not prove preservation of the original bytes.
    let samples=["  第一行\r\n\t缩进\r\n\r\n  末行  \r\n",
                 "\n\n    code {\n\treturn 1\n    }\n\n",
                 "# 原文\n**不是富文本** [链接](https://example.invalid) `code` <tag>\n",
                 "NFC:é / NFD:e\u{301}\n👩🏽‍💻 👨‍👩‍👧‍👦 🏳️‍🌈\r\n",
                 " \t \r\n\n"]
    private final class Secret:IdentitySecretStore {
        var data:Data?
        func read()throws->Data?{data}
        func insert(_ data:Data)throws{guard self.data==nil else{throw IdentityStoreError.alreadyExists};self.data=data}
        func replace(_ data:Data)throws{guard self.data != nil else{throw IdentityStoreError.absent};self.data=data}
    }
    func testEncryptedReplicaRestartAndDerivedCacheKeepExactUTF8Layout() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("SharedText-Fidelity-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let av=try DeviceIdentityVault(store:Secret(),directory:root.appendingPathComponent("a-id")),bv=try DeviceIdentityVault(store:Secret(),directory:root.appendingPathComponent("b-id"))
        let ai=try av.create(),bi=try bv.create(),a=try SecureReplicaStore(directory:root.appendingPathComponent("a-store"),vault:av),b=try SecureReplicaStore(directory:root.appendingPathComponent("b-store"),vault:bv)
        let setup=try GroupSetup.create(owner:ai),group=setup.membership.anchor.group;try a.initializeGroup(setup)
        let request=try PairRequest.create(identity:bi,now:1000),approval=try a.beginPairing(request,group:group,permissions:.all,now:1001)
        let code=try DevicePairing.authenticationCode(approval.challenge,request:request,recipient:bi,now:1002)
        let grant=try a.finishPairing(session:request.session,confirmedCode:code,now:1003)
        try b.acceptPairing(grant,challenge:approval.challenge,request:request,confirmedCode:code,now:1004)
        for (i,text) in samples.enumerated() {
            let message=try a.enqueue(Data(text.utf8),domain:.clipboard,group:group,sharingEnabled:true,now:1010+UInt64(i))
            let wire=try message.encoded();XCTAssertNil(wire.range(of:Data(text.utf8)))
            XCTAssertEqual(try b.receive(wire,now:1020,receivingEnabled:true),.applied)
        }
        let reopened=try SecureReplicaStore(directory:root.appendingPathComponent("b-store"),vault:bv),received=try reopened.clipboard(group:group,now:1021)
        XCTAssertEqual(received.count,samples.count)
        for (text,clip) in zip(samples,received){XCTAssertEqual(Data(clip.text.utf8),Data(text.utf8))}
        let key=SymmetricKey(size:.bits256),directory=root.appendingPathComponent("cache")
        try SharedClipboardCache(directory:directory).publish(received,group:group,key:key,now:1021)
        let cache=SharedClipboardCache(directory:directory),decoded=try cache.read(group:group,fullAccess:true,sharingEnabled:true,now:1022,key:{key})
        XCTAssertEqual(decoded.map(\.id),received.map(\.id))
        for (text,clip) in zip(samples,decoded){XCTAssertEqual(Data(clip.text.utf8),Data(text.utf8))}
        // A second relay send after cache restoration is also byte exact.
        for clip in decoded {
            let message=try b.enqueue(Data(clip.text.utf8),domain:.clipboard,group:group,sharingEnabled:true,now:1030)
            XCTAssertEqual(try a.receive(message.encoded(),now:1031,receivingEnabled:true),.applied)
        }
        let returned=try a.clipboard(group:group,now:1032)
        for (text,clip) in zip(samples,returned){XCTAssertEqual(Data(clip.text.utf8),Data(text.utf8))}
        XCTAssertEqual(returned.count,samples.count)
    }
    func testCachePreservesThe64KiBUTF8Boundary() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("SharedText-Boundary-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let text="\r\n"+String(repeating:" ",count:65530)+"\t\n  ";XCTAssertEqual(text.utf8.count,65536)
        let clip=try JSONDecoder().decode(ReceivedClipboard.self,from:JSONSerialization.data(withJSONObject:["id":UUID().uuidString,"sender":UUID().uuidString,"text":text,"expiresAt":1600])),key=SymmetricKey(size:.bits256),group=UUID(),cache=SharedClipboardCache(directory:root)
        try cache.publish([clip],group:group,key:key,now:1000)
        XCTAssertEqual(Data(try XCTUnwrap(cache.read(group:group,fullAccess:true,sharingEnabled:true,now:1001,key:{key}).first).text.utf8),Data(text.utf8))
    }
}
