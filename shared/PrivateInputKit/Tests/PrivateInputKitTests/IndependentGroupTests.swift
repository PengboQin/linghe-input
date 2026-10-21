import XCTest
import CryptoKit
@testable import PrivateInputKit

final class IndependentGroupTests:XCTestCase {
    private var paths:[URL]=[]
    private var exportRequests:[UUID:PairRequest]=[:]
    override func tearDownWithError() throws {for path in paths {try FileManager.default.removeItem(at:path)}}
    private func identity() throws -> DeviceIdentity {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("Linghe-independent-"+UUID().uuidString);paths.append(url)
        return try DeviceIdentityVault(store:SyntheticIdentityStore(),directory:url).create()
    }
    private func admit(_ newcomer:DeviceIdentity,to group:GroupSetup,by signer:DeviceIdentity) throws -> (GroupSetup,AdmissionBundle) {
        let request=try PairRequest.create(identity:newcomer,now:1000)
        exportRequests[request.session]=request
        let pending=try DevicePairing.beginApproval(request,current:group,owner:signer,permissions:.all,now:1001)
        let release=try DevicePairing.finishApproval(pending,owner:signer,confirmedCode:pending.confirmationCode,now:1002)
        let received=try DevicePairing.accept(release.package,challenge:pending.challenge,request:request,recipient:newcomer,confirmedCode:pending.confirmationCode,now:1003)
        XCTAssertEqual(received.membership.digest,release.group.membership.digest)
        var packages=[release.package]
        for m in release.group.membership.statement.members where m.device != newcomer.device {
            packages.append(try WrappedGroupKey.seal(setup:release.group,for:m.device,context:Data(repeating:0,count:32),owner:signer,now:1002,expiresAt:2000).package)
        }
        return (release.group,AdmissionBundle(session:request.session,challenge:pending.challenge,membership:release.group.membership.statement,packages:packages))
    }
    func testIndependentSurvivorCanAdmitAfterOriginalDeviceRemovedAndExportWire() throws {
        let a=try identity(),b=try identity(),c=try identity(),d=try identity(),genesis=try GroupSetup.create(owner:a)
        // Existing v1 group migrates without changing the trust anchor or secrets.
        let old=try SignedMembership.sign(group:genesis.membership.anchor.group,ownerID:a.ownerID,ownerKey:a.ownerSigningKey,revision:2,members:[.init(identity:a),.init(identity:b)])
        let prior=GroupSetup(membership:try genesis.membership.anchor.verify(old),key:genesis.key)
        let (second,requestB)=try admit(c,to:prior,by:b)
        let survivor=try second.changingMembers(second.membership.statement.members.filter{$0.device != a.device},owner:c)
        let (last,requestC)=try admit(d,to:survivor,by:c)
        XCTAssertEqual(last.membership.statement.members.count,3)
        XCTAssertFalse(last.membership.statement.members.contains{$0.device==a.device})
        XCTAssertThrowsError(try last.changingMembers(last.membership.statement.members,owner:a))
        XCTAssertEqual(try prior.membership.anchor.verify(last.membership.statement,replacing:prior.membership).digest,last.membership.digest)
        var forged=last.membership.statement;forged.history?[1].members.removeLast()
        XCTAssertThrowsError(try prior.membership.anchor.verify(forged))
        let fork=try second.changingMembers(second.membership.statement.members,owner:b)
        XCTAssertThrowsError(try last.membership.anchor.verify(fork.membership.statement,replacing:survivor.membership))
        let retained=try WrappedGroupKey.seal(setup:survivor,for:b.device,context:Data(repeating:0,count:32),owner:c,now:1002,expiresAt:2000).package
        XCTAssertEqual(try retained.openRotation(recipient:b,current:second.membership,now:1003).membership.digest,survivor.membership.digest)
        if let folder=ProcessInfo.processInfo.environment["LINGHE_SYNTHETIC_EXPORT"] {
            struct Wire:Encodable {let genesis:SignedMembership;let old:SignedMembership;let first:AdmissionBundle;let removed:SignedMembership;let removalKeys:[WrappedGroupKey];let second:AdmissionBundle;let identities:[String:[String:String]]}
            let ids=[a,b,c,d].map{["device":$0.device.uuidString,"signing":$0.signingKey.rawRepresentation.base64EncodedString(),"ownerID":$0.ownerID.uuidString,"owner":$0.ownerSigningKey.rawRepresentation.base64EncodedString()]}
            let ownRotation=try WrappedGroupKey.seal(setup:survivor,for:c.device,context:Data(repeating:0,count:32),owner:c,now:1002,expiresAt:2000).package
            let value=Wire(genesis:genesis.membership.statement,old:old,first:requestB,removed:survivor.membership.statement,removalKeys:[retained,ownRotation],second:requestC,identities:Dictionary(uniqueKeysWithValues:zip(["a","b","c","d"],ids)))
            var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) as! [String:Any]
            for field in ["first","second"] {
                var bundle=object[field] as! [String:Any]
                let member=bundle["membership"] as! [String:Any],challenge=bundle["challenge"] as! [String:Any],template=challenge["template"] as! [String:Any]
                let target=template["recipient"] as! String
                let identity=target==c.device.uuidString ? c:d
                var request=try PairRequest.create(identity:identity,now:1000)
                // The original request must be exported, not regenerated.
                let context=template["context"] as! String
                _ = member;_ = request;_ = context
                bundle["request"]=try JSONSerialization.jsonObject(with:JSONEncoder().encode(exportRequests[UUID(uuidString:bundle["session"] as! String)!]!))
                object[field]=bundle
            }
            try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]).write(to:URL(fileURLWithPath:folder).appendingPathComponent("independent-fixture.json"),options:.atomic)
        }
    }
    func testQRHasNoReadableEndpointAndTamperingFails() throws {
        let a=try identity(),g=try GroupSetup.create(owner:a)
        let qr=QuickPairQR(invitation:DeviceInvitation(endpoint:URL(string:"https://private.example.invalid")!,anchor:g.membership.anchor),ticket:UUID(),secret:Data(repeating:9,count:32),expiresAt:1200)
        let link=try qr.link(),query=URLComponents(url:link,resolvingAgainstBaseURL:false)!.queryItems!.first!.value!
        XCTAssertTrue(query.hasPrefix("v2:"));let raw=Data(base64Encoded:String(query.dropFirst(3)))!
        XCTAssertFalse(String(decoding:raw,as:UTF8.self).contains("private.example.invalid"))
        XCTAssertEqual(try QuickPairQR.decode(link,now:1000).invitation.endpoint,qr.invitation.endpoint)
        if let folder=ProcessInfo.processInfo.environment["LINGHE_SYNTHETIC_EXPORT"] {try Data(link.absoluteString.utf8).write(to:URL(fileURLWithPath:folder).appendingPathComponent("apple-envelope-qr.txt"))}
        var tampered=raw;tampered[tampered.count-1] ^= 1
        var url=URLComponents(url:link,resolvingAgainstBaseURL:false)!;url.queryItems=[.init(name:"data",value:"v2:"+tampered.base64EncodedString())]
        XCTAssertThrowsError(try QuickPairQR.decode(url.url!,now:1000))
    }
}
