import Foundation
import CryptoKit
struct PublicWire:Decodable {let initial:SignedMembership;let paired:SignedMembership}
func hex(_ data:Data)->String{data.map{String(format:"%02x",$0)}.joined()}
let input=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
let wire=try JSONDecoder().decode(PublicWire.self,from:input)
let anchor=MembershipAnchor(group:wire.initial.group,ownerID:wire.initial.ownerID,ownerPublic:wire.initial.ownerPublic)
let initial=try anchor.verify(wire.initial)
_ = try anchor.verify(wire.paired,replacing:initial)
// This is the publicly documented synthetic sender seed, never a real identity.
let signer=try Curve25519.Signing.PrivateKey(rawRepresentation:Data((0..<32).map{UInt8($0)}))
var next=SignedMembership(version:2,group:wire.initial.group,ownerID:wire.initial.ownerID,ownerPublic:wire.initial.ownerPublic,revision:2,epoch:2,members:wire.paired.members,signature:Data(),issuer:wire.initial.members[0].device,parent:initial.digest,history:[wire.initial])
next.signature=try signer.signature(for:next.canonical())
let verified=try anchor.verify(next,replacing:initial)
if CommandLine.arguments.count>2 {
 let text=Array(CommandLine.arguments[2].utf8);guard text.count==128 else{fatalError("Synthetic signature bound")}
 let value=try stride(from:0,to:text.count,by:2).map{index->UInt8 in guard let byte=UInt8(String(decoding:text[index..<(index+2)],as:UTF8.self),radix:16) else{throw MembershipError.malformed};return byte}
 next.signature=Data(value);_ = try anchor.verify(next,replacing:initial);print("PASS portable libsodium v2 signature accepted by current Swift Membership/CryptoKit");exit(0)
}
let result=["initialCanonical":hex(try wire.initial.canonical()),"initialDigest":hex(initial.digest),"pairedCanonical":hex(try wire.paired.canonical()),"v2Canonical":hex(try next.canonical()),"v2Digest":hex(verified.digest),"v2Signature":hex(next.signature)]
let encoded=try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys,.prettyPrinted]);FileHandle.standardOutput.write(encoded);print()
