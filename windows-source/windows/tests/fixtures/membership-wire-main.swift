import Foundation
import CryptoKit
struct PublicWire:Decodable {let initial:SignedMembership;let paired:SignedMembership}
let args=CommandLine.arguments
func save(_ value:SignedMembership,_ name:String) throws {try value.encoded().write(to:URL(fileURLWithPath:args[2]+"/"+name+".json"))}
if args[1]=="generate" {
 let input=try JSONDecoder().decode(PublicWire.self,from:Data(contentsOf:URL(fileURLWithPath:args[3])))
 let initial=input.initial,anchor=MembershipAnchor(group:initial.group,ownerID:initial.ownerID,ownerPublic:initial.ownerPublic)
 let verified=try anchor.verify(initial)
 let signer=try Curve25519.Signing.PrivateKey(rawRepresentation:Data((0..<32).map{UInt8($0)}))
 var next=SignedMembership(version:2,group:initial.group,ownerID:initial.ownerID,ownerPublic:initial.ownerPublic,revision:2,epoch:2,members:input.paired.members,signature:Data(),issuer:initial.members[0].device,parent:verified.digest,history:[initial])
 next.signature=try signer.signature(for:next.canonical());_ = try anchor.verify(next,replacing:verified)
 try save(initial,"swift-v1");try save(input.paired,"swift-paired");try save(next,"swift-v2")
 print("PASS current Swift JSONEncoder generated public v1/v2 statements")
} else {
 let root=try SignedMembership.decode(Data(contentsOf:URL(fileURLWithPath:args[2]+"/cpp-swift-v1.json")))
 let anchor=MembershipAnchor(group:root.group,ownerID:root.ownerID,ownerPublic:root.ownerPublic),initial=try anchor.verify(root)
 for name in ["swift-v1","swift-paired","swift-v2"] {
  let value=try SignedMembership.decode(Data(contentsOf:URL(fileURLWithPath:args[2]+"/cpp-"+name+".json")))
  _ = try anchor.verify(value,replacing:initial);try save(value,"swift-roundtrip-"+name)
 }
 print("PASS C++ JSON output decoded and verified by current Swift/CryptoKit; reencoded v1/v2")
}
