import XCTest
import CryptoKit
@testable import PrivateInputKit

final class RecentLearningSyncTests: XCTestCase {
    private let now: UInt64 = 1_800_000_000
    private func identity(_ n: UInt8 = 17) throws -> DeviceIdentity {
        try DeviceIdentity(.init(device: UUID(uuidString: String(format:"00000000-0000-0000-0000-%012d", Int(n)))!,
                                 signingSeed: Data(repeating:n,count:32), ownerID: UUID(uuidString:String(format:"00000000-0000-0000-0000-%012d",Int(n)))!,
                                 ownerSigningSeed: Data(repeating:n,count:32), exchangeSecret: Data(repeating:n+2,count:32),
                                 storageKey: Data(repeating:n+3,count:32), reservedSequence:0))
    }
    private func payload() throws -> Data {
        var model = RecentLearningModel()
        try model.recordLocalDelta(reading:"dou xian",text:"都先",replica:"synthetic",amount:16,
                                   trustedDay:Int(now/86400),policy:.init(referenceDay:Int(now/86400)))
        return try model.export(policy:.init(referenceDay:Int(now/86400)))
    }
    func testEncryptedRoundTripAndIndependentRandomNonce() throws {
        let id = try identity(), setup = try GroupSetup.create(owner:id), policy = try RecentLearningPolicy(referenceDay:Int(now/86400))
        let body = try payload()
        let a = try RecentLearningEnvelope.seal(body,group:setup,identity:id,now:now,policy:policy)
        let b = try RecentLearningEnvelope.seal(body,group:setup,identity:id,now:now,policy:policy)
        XCTAssertEqual(try a.open(group:setup,now:now,policy:policy),body)
        XCTAssertNotEqual(a.sealed.prefix(12),b.sealed.prefix(12))
        XCTAssertFalse(String(decoding:try JSONEncoder().encode(a),as:UTF8.self).contains("都先"))
        for key in ["group","sender","event","epoch","issuedAt","expiresAt"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(a)) as? [String:Any])
            if ["group","sender","event"].contains(key) {object[key]=UUID().uuidString}
            else {object[key]=(object[key] as! NSNumber).uint64Value+1}
            let bad = try JSONDecoder().decode(RecentLearningEnvelope.self,from:JSONSerialization.data(withJSONObject:object))
            XCTAssertThrowsError(try bad.open(group:setup,now:now,policy:policy),key)
        }
        var corrupt = a; corrupt.sealed[12] ^= 1
        XCTAssertThrowsError(try corrupt.open(group:setup,now:now,policy:policy))
        corrupt = a; corrupt.signature[0] ^= 1
        XCTAssertThrowsError(try corrupt.open(group:setup,now:now,policy:policy))
        XCTAssertThrowsError(try a.open(group:setup,now:a.expiresAt,policy:policy))
    }
    func testNewSignatureDomainCannotBeReusedAsLegacyRPC() throws {
        let id = try identity(), setup = try GroupSetup.create(owner:id)
        let request = try SignedRecencyRequest.sign(group:setup.membership.statement.group,identity:id,operation:1,body:Data("{}".utf8),now:now)
        XCTAssertTrue(id.signingKey.publicKey.isValidSignature(request.signature,for:try request.canonical()))
        var legacy = SignedRelayRequest(group:request.group,sender:request.sender,nonce:request.nonce,issuedAt:request.issuedAt,
                                       operation:.membership,body:request.body,signature:request.signature)
        XCTAssertFalse(id.signingKey.publicKey.isValidSignature(legacy.signature,for:try legacy.canonical()))
        legacy.body=Data()
        XCTAssertFalse(id.signingKey.publicKey.isValidSignature(legacy.signature,for:try legacy.canonical()))
    }
    func testStatusRejectsWrongNonceEpochPolicyAndContradictoryReadiness() throws {
        let id=try identity(),setup=try GroupSetup.create(owner:id)
        let request=try SignedRecencyRequest.sign(group:setup.membership.statement.group,identity:id,operation:1,body:Data(),now:now)
        let valid:[String:Any] = ["version":1,"group":request.group.uuidString,"sender":id.device.uuidString,"nonce":request.nonce.uuidString,
            "epoch":setup.membership.statement.epoch,"membershipRevision":setup.membership.statement.revision,
            "serverTime":now,"referenceDay":Int(now/86400),"ready":true,"missing":[String](),"publishedEvent":""]
        func decode(_ value:[String:Any]) throws -> RecentLearningServerStatus {
            try JSONDecoder().decode(RecentLearningServerStatus.self,from:JSONSerialization.data(withJSONObject:value))
        }
        XCTAssertNoThrow(try decode(valid).validate(request:request,setup:setup))
        for key in ["nonce","epoch","referenceDay","ready"] {
            var invalid=valid
            switch key {
            case "nonce":invalid[key]=UUID().uuidString
            case "ready":invalid[key]=false
            default:invalid[key]=(invalid[key] as! NSNumber).uint64Value+1
            }
            XCTAssertThrowsError(try decode(invalid).validate(request:request,setup:setup),key)
        }
    }
    func testExportSyntheticCrossPlatformVector() throws {
        guard let path = ProcessInfo.processInfo.environment["RECENCY_VECTOR_PATH"] else { return }
        let id = try identity(), setup = try GroupSetup.create(owner:id), policy = try RecentLearningPolicy(referenceDay:Int(now/86400))
        let data = try payload(), envelope = try RecentLearningEnvelope.seal(data,group:setup,identity:id,now:now,policy:policy)
        let request = try SignedRecencyRequest.sign(group:setup.membership.statement.group,identity:id,operation:2,
            body:JSONSerialization.data(withJSONObject:["epoch":setup.membership.statement.epoch,"membershipRevision":setup.membership.statement.revision,"expectedEvent":"",
                 "envelope":JSONSerialization.jsonObject(with:JSONEncoder().encode(envelope))]),now:now)
        let object:[String:Any] = try ["warning":"Synthetic keys only; never a user identity", "serverTime":now,
             "referenceDay":Int(now/86400),"membership":JSONSerialization.jsonObject(with:setup.membership.statement.encoded()),
             "groupKey":setup.key.withUnsafeBytes{Data($0)}.base64EncodedString(),"signingPublic":id.signingKey.publicKey.rawRepresentation.base64EncodedString(),
             "signingSeed":id.signingKey.rawRepresentation.base64EncodedString(),"payload":data.base64EncodedString(),
             "envelope":JSONSerialization.jsonObject(with:JSONEncoder().encode(envelope)),"header":envelope.header().base64EncodedString(),
             "request":JSONSerialization.jsonObject(with:request.encoded()),"requestCanonical":request.canonical().base64EncodedString()]
        try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]).write(to:URL(fileURLWithPath:path),options:.atomic)
    }
    func testCppProducerDecryptsInSwift() throws {
        guard let path=ProcessInfo.processInfo.environment["RECENCY_CPP_VECTOR_PATH"],
              let originalPath=ProcessInfo.processInfo.environment["RECENCY_ORIGINAL_VECTOR_PATH"] else { return }
        let original=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:originalPath))) as? [String:Any])
        let producer=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:path))) as? [String:Any])
        let statement=try SignedMembership.decode(JSONSerialization.data(withJSONObject:original["membership"]!))
        let anchor=MembershipAnchor(group:statement.group,ownerID:statement.ownerID,ownerPublic:statement.ownerPublic)
        let setup=GroupSetup(membership:try anchor.verify(statement),key:SymmetricKey(data:Data(base64Encoded:original["groupKey"] as! String)!))
        let envelope=try JSONDecoder().decode(RecentLearningEnvelope.self,from:JSONSerialization.data(withJSONObject:producer["envelope"]!))
        let now=(original["serverTime"] as! NSNumber).uint64Value
        let policy=try RecentLearningPolicy(referenceDay:Int(now/86400))
        let opened=try envelope.open(group:setup,now:now,policy:policy)
        let expected=try XCTUnwrap(Data(base64Encoded:producer["payload"] as! String))
        XCTAssertEqual(opened,expected)
    }
    func testActualLoopbackServiceNewProtocolAndOldRelayTogether() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["RECENCY_RELAY_URL"].flatMap(URL.init(string:)) else { return }
        let owner = try identity(), peer = try identity(27)
        let initial = try GroupSetup.create(owner:owner)
        // This fixture exercises an existing v1 group. New v2 admissions have
        // their own atomic admission tests and cannot use PUT /membership.
        let statement = try SignedMembership.sign(group:initial.membership.statement.group,ownerID:owner.ownerID,
             ownerKey:owner.ownerSigningKey,revision:2,members:[GroupMember(identity:owner),GroupMember(identity:peer)])
        let paired = GroupSetup(membership:try initial.membership.anchor.verify(statement,replacing:initial.membership),key:SymmetricKey(size:.bits256))
        let legacy = try RelayClient(endpoint:endpoint,allowLoopbackHTTP:true)
        try await legacy.register(initial.membership); try await legacy.publishMembership(paired.membership)
        let client = RecentLearningClient(transport:try RecentLearningHTTPTransport(endpoint:endpoint,allowLoopbackHTTP:true))
        let wall = UInt64(Date().timeIntervalSince1970)
        let first = try await client.hello(setup:paired,identity:owner,roles:["desktop","ime"],now:wall)
        XCTAssertFalse(first.status.ready)
        let second = try await client.hello(setup:paired,identity:peer,roles:["app","keyboard"],now:wall)
        XCTAssertTrue(second.status.ready)
        var model = RecentLearningModel();let policy = try second.status.policy
        try model.recordLocalDelta(reading:"ni hao",text:"你好",replica:"synthetic",amount:3,trustedDay:policy.referenceDay,policy:policy)
        let data = try model.export(policy:policy), envelope = try RecentLearningEnvelope.seal(data,group:paired,identity:owner,now:wall,policy:policy)
        let pushed = try await client.push(envelope,expectedEvent:"",setup:paired,identity:owner,now:wall)
        XCTAssertEqual(pushed.status.event,envelope.event)
        let own = try await client.hello(setup:paired,identity:owner,roles:["desktop","ime"],now:wall)
        XCTAssertEqual(own.status.publishedEvent,envelope.event.uuidString)
        XCTAssertEqual(own.status.envelope?.event,envelope.event)
        let page = try await client.pull(after:"",setup:paired,identity:peer,now:wall)
        XCTAssertEqual(try XCTUnwrap(page.status.envelope).open(group:paired,now:wall,policy:policy),data)
        let end = try await client.pull(after:try XCTUnwrap(page.status.next),setup:paired,identity:peer,now:wall)
        XCTAssertNil(end.status.envelope)
        // Exercise the real double-base64 request above the old 3MiB proxy
        // boundary, not just a tiny snapshot that hides transport limits.
        let text = String(repeating:"x",count:600)
        let largeEntries = (0..<2400).map { RecentLearningEntry(word:.init(reading:"ni hao",text:text+String($0),counts:["synthetic":1])) }
        let large = try JSONEncoder().encode(RecentLearningArchive(entries:largeEntries))
        XCTAssertLessThan(large.count,RecentLearningModel.byteLimit)
        let largeEnvelope = try RecentLearningEnvelope.seal(large,group:paired,identity:owner,now:wall,policy:policy)
        var staleRejected = false
        do { _ = try await client.push(largeEnvelope,expectedEvent:"",setup:paired,identity:owner,now:wall) }
        catch RecentLearningSyncError.httpStatus(let status) { XCTAssertEqual(status,409);staleRejected=true }
        XCTAssertTrue(staleRejected)
        _ = try await client.push(largeEnvelope,expectedEvent:envelope.event.uuidString,setup:paired,identity:owner,now:wall)
        let largePage = try await client.pull(after:"",setup:paired,identity:peer,now:wall)
        XCTAssertEqual(try XCTUnwrap(largePage.status.envelope).open(group:paired,now:wall,policy:policy),large)
        // Existing membership/pull RPC remains usable after new tables/routes.
        let current = try await legacy.membership(group:paired.membership.statement.group,identity:owner,now:wall)
        XCTAssertEqual(current.epoch,paired.membership.statement.epoch)
    }
}
