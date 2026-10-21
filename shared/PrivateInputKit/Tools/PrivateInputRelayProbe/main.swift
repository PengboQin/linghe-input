import Foundation
import PrivateInputKit
import CryptoKit

// Explicit disposable peers only. No clipboard, installed app data or keychain.
final class EphemeralSecrets:IdentitySecretStore {
    var value:Data?
    func read() throws -> Data? { value }
    func insert(_ data:Data) throws { guard value == nil else { throw IdentityStoreError.alreadyExists };value=data }
    func replace(_ data:Data) throws { guard value != nil else { throw IdentityStoreError.absent };value=data }
}
struct Peer {
    let identity:DeviceIdentity
    let vault:DeviceIdentityVault
    let store:SecureReplicaStore
    init(_ path:URL) throws {
        vault=try DeviceIdentityVault(store:EphemeralSecrets(),directory:path.appendingPathComponent("Identity"))
        identity=try vault.create();store=try SecureReplicaStore(directory:path.appendingPathComponent("Database"),vault:vault)
    }
}
func require(_ condition:Bool) throws { if !condition { throw ReplicaStoreError.changedState } }
let quick=CommandLine.arguments.dropFirst()==["--run-synthetic-quick-pair-test"]
guard (quick || CommandLine.arguments.dropFirst() == ["--run-synthetic-public-test"]),
      let text=ProcessInfo.processInfo.environment["PRIVATE_INPUT_ACCEPTANCE_ENDPOINT"],
      let endpoint=URL(string:text),endpoint.scheme=="https" else { throw RelayClientError.invalidEndpoint }
let client=try RelayClient(endpoint:endpoint),root=FileManager.default.temporaryDirectory.appendingPathComponent("PrivateInput-PublicProbe-"+UUID().uuidString)
try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
defer { try? FileManager.default.removeItem(at:root) }
let a=try Peer(root.appendingPathComponent("A")),b=try Peer(root.appendingPathComponent("B"))
let initial=try GroupSetup.create(owner:a.identity),group=initial.membership.anchor.group
try a.store.initializeGroup(initial);try await client.register(initial.membership)
var now:UInt64 { UInt64(Date().timeIntervalSince1970) }
let request=try PairRequest.create(identity:b.identity,now:now)
if quick {
    let invitation=DeviceInvitation(endpoint:endpoint,anchor:initial.membership.anchor)
    let ticket=try await client.createTicket(invitation:invitation,ticket:UUID(),secretHash:Data(SHA256.hash(data:Data(repeating:31,count:32))),expiresAt:now+300,identity:a.identity,now:now)
    let joined=try await client.claimTicket(code:ticket.code,request:request)
    try require(joined.anchor==invitation.anchor)
    let retry=try await client.claimTicket(code:ticket.code,request:request)
    try require(retry.anchor==invitation.anchor)
    let claims=try await client.quickClaims(group:group,owner:a.identity,now:now)
    try require(claims.count==1 && claims[0].request.session==request.session)
} else { try await client.submitPair(request,group:group,identity:b.identity,now:now) }
let pending=try await client.pendingPairs(group:group,owner:a.identity,now:now)
try require(pending.count==1)
let approval=try a.store.beginPairing(pending[0],group:group,permissions:.all,now:now)
try await client.publishChallenge(approval.challenge,session:request.session)
let challenge=try await client.pairChallenge(group:group,session:request.session,identity:b.identity,now:now)
let code=try DevicePairing.authenticationCode(challenge,request:request,recipient:b.identity,now:now)
try require(code==approval.code)
let grant=try a.store.finishPairing(session:request.session,confirmedCode:code,now:now)
try await client.publishMembership(a.store.group(group).membership);try await client.publishKey(grant)
let receivedGrant=try await client.keyPackage(group:group,identity:b.identity,now:now)
try b.store.acceptPairing(receivedGrant,challenge:challenge,request:request,confirmedCode:code,now:now)
@MainActor func sync(_ peer:Peer,_ consent:SyncConsent = .init(learning:true,clipboard:true)) async throws {
    _ = try await RelaySyncPass.run(group:group,store:peer.store,vault:peer.vault,client:client,consent:consent,now:now)
}
let word=PersonalLexicon.Entry(kind:.word,text:"合成公网词条",trigger:"he cheng gong wang ci tiao")
let phrase=PersonalLexicon.Entry(kind:.phrase,text:"合成公网短语\n第二行",trigger:"gwdy")
var left=PersonalLexiconSync(),right=PersonalLexiconSync()
try left.change(word,deleted:false,replica:a.identity.device);try right.change(phrase,deleted:false,replica:b.identity.device)
var ma=LearningModel(),mb=LearningModel();try ma.mergePersonalLexicon(left);try mb.mergePersonalLexicon(right)
try ma.record(reading:"ni hao",text:"你好",device:a.identity.device.uuidString)
let outgoing=try a.store.enqueue(ma.export(),domain:.learning,group:group,sharingEnabled:true,now:now)
_ = try b.store.enqueue(mb.export(),domain:.learning,group:group,sharingEnabled:true,now:now)
try await sync(a);try await sync(b);try await sync(a)
try await client.push(outgoing.encoded());try await sync(b)
var combined=LearningModel();try combined.merge(b.store.learningArchive(group:group))
try require(combined.personalLexicon?.materialized().entries.count==2)
try require(combined.entries.values.first?.frequency==1)
let stale=try unwrap(combined.personalLexicon)
try left.merge(stale);try left.change(word,deleted:true,replica:a.identity.device)
var deletion=LearningModel();try deletion.mergePersonalLexicon(left)
_ = try a.store.enqueue(deletion.export(),domain:.learning,group:group,sharingEnabled:true,now:now)
try await sync(a);try await sync(b)
var final=LearningModel();try final.merge(b.store.learningArchive(group:group))
var explicit=try unwrap(final.personalLexicon);try explicit.merge(stale)
try require(explicit.materialized().entries.map(\.id)==[phrase.id])
_ = try a.store.enqueue(Data("SYNTHETIC-PUBLIC-A-TO-B".utf8),domain:.clipboard,group:group,sharingEnabled:true,now:now)
try await sync(a);try await sync(b,.init(learning:true,clipboard:false))
try require(b.store.clipboard(group:group,now:now).isEmpty)
try await sync(b)
try require(b.store.clipboard(group:group,now:now).contains{$0.text=="SYNTHETIC-PUBLIC-A-TO-B"})
_ = try b.store.enqueue(Data("SYNTHETIC-PUBLIC-B-TO-A".utf8),domain:.clipboard,group:group,sharingEnabled:true,now:now)
try await sync(b);try await sync(a)
try require(a.store.clipboard(group:group,now:now).contains{$0.text=="SYNTHETIC-PUBLIC-B-TO-A"})
if quick {
    let c=try Peer(root.appendingPathComponent("C"))
    let invitation=DeviceInvitation(endpoint:endpoint,anchor:try b.store.group(group).membership.anchor)
    let secret=Data(repeating:49,count:32),id=UUID()
    let ticket=try await client.createTicket(invitation:invitation,ticket:id,secretHash:Data(SHA256.hash(data:secret)),expiresAt:now+300,identity:b.identity,now:now)
    let qr=QuickPairQR(invitation:invitation,ticket:id,secret:secret,expiresAt:ticket.expiresAt)
    let parsed=try QuickPairQR.decode(qr.link(),now:now)
    let pair=try PairRequest.create(identity:c.identity,now:now)
    let joined=try await client.claimTicket(qr:parsed,request:pair)
    try require(joined.anchor==invitation.anchor)
    let claims=try await client.quickClaims(group:group,owner:a.identity,now:now)
    let claim=try unwrap(claims.first{$0.request.session==pair.session})
    try require(claim.sponsor==b.identity.device)
    let approval=try a.store.beginPairing(claim.request,group:group,permissions:.all,now:now)
    try await client.publishChallenge(approval.challenge,session:pair.session)
    let challenge=try await client.pairChallenge(group:group,session:pair.session,identity:c.identity,now:now)
    let code=try DevicePairing.authenticationCode(challenge,request:pair,recipient:c.identity,now:now)
    let key=try a.store.finishPairing(session:pair.session,confirmedCode:code,now:now)
    try await client.publishMembership(a.store.group(group).membership)
    try await client.publishKey(key)
    try await client.publishKey(a.store.rotationPackage(group:group,recipient:b.identity.device,now:now))
    try c.store.acceptPairing(key,challenge:challenge,request:pair,confirmedCode:code,now:now)
    try await sync(b)
    _ = try c.store.enqueue(Data("SYNTHETIC-QUICK-QR-THIRD-DEVICE".utf8),domain:.clipboard,group:group,sharingEnabled:true,now:now)
    try await sync(c);try await sync(a)
    try require(a.store.clipboard(group:group,now:now).contains{$0.text=="SYNTHETIC-QUICK-QR-THIRD-DEVICE"})
    try await client.cancelTicket(ticket.ticket,group:group,identity:b.identity,now:now)
    print("Quick pairing: owner six-digit code, retry, member-issued QR, third-device encrypted text and cancellation passed")
}
try a.store.changeMembers(group:group,members:[GroupMember(identity:a.identity)])
try await client.publishMembership(a.store.group(group).membership)
do { try await sync(b);throw ReplicaStoreError.changedState }
catch RelayClientError.httpStatus(let status) { try require(status==403) }
print("Public TLS: pairing, bidirectional text, offline word/phrase merge, retry deduplication, delete tombstone, paused text and revocation passed")
func unwrap<T>(_ value:T?) throws -> T { guard let value else { throw ReplicaStoreError.corrupt };return value }
