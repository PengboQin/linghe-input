import Foundation
import CryptoKit
import PrivateInputKit

// PUBLIC SYNTHETIC KEYS. Never use these reproducible values in a client.
let seed = Data(0..<32)
let master = Data(32..<64)
let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
let group = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
let sender = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
let event = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
let payload = Data("Private Input synthetic vector / 合成文本".utf8)
let trust = SyncTrust(group: group, epoch: 2, members: [sender: signing.publicKey.rawRepresentation])
if CommandLine.arguments.dropFirst().first == "--relay-fixtures" {
    let owner = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(64..<96))
    let exchange = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(128..<160))
    let peerSigning = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(96..<128))
    let peerExchange = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(160..<192))
    let recipient = UUID(uuidString: "00000000-0000-4000-8000-000000000004")!
    let ownerID = UUID(uuidString: "00000000-0000-4000-8000-000000000006")!
    let first = GroupMember(device: sender, signingPublic: signing.publicKey.rawRepresentation, exchangePublic: exchange.publicKey.rawRepresentation)
    let second = GroupMember(device: recipient, signingPublic: peerSigning.publicKey.rawRepresentation, exchangePublic: peerExchange.publicKey.rawRepresentation)
    let initial = try SignedMembership.sign(group: group, ownerID: ownerID, ownerKey: owner, revision: 1, members: [first])
    let paired = try SignedMembership.sign(group: group, ownerID: ownerID, ownerKey: owner, revision: 2, members: [first, second])
    let pull = try SignedRelayRequest.sign(group: group, sender: recipient, signingKey: peerSigning, operation: .pull,
                                            body: Data("{\"limit\":2}".utf8), now: 1000)
    let fixture: [String: Any] = ["warning": "PUBLIC SYNTHETIC KEYS - test only", "ownerSeed": Data(64..<96).base64EncodedString(), "senderSeed": seed.base64EncodedString(), "recipientSeed": Data(96..<128).base64EncodedString(), "initial": try JSONSerialization.jsonObject(with: initial.encoded()), "paired": try JSONSerialization.jsonObject(with: paired.encoded()), "pullRequest": try JSONSerialization.jsonObject(with: pull.encoded())]
    print(String(decoding: try JSONSerialization.data(withJSONObject: fixture, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    exit(0)
}
if CommandLine.arguments.count == 2 {
    let incoming = try SecureEnvelope.decode(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
    let opened = try SecureMessage.open(incoming, groupKey: SymmetricKey(data: master), trust: trust, ledger: ReplayLedger(), now: 1010)
    precondition(opened.payload == payload)
    print("PASS: CryptoKit verified independent Python Ed25519 signature and decrypted exact synthetic payload")
    exit(0)
}
let envelope = try SecureMessage.seal(payload: payload, domain: .clipboard, groupKey: SymmetricKey(data: master), signingKey: signing, trust: trust, sender: sender, event: event, sequence: 7, issuedAt: 1000, expiresAt: 1600)
let object: [String: Any] = ["warning": "PUBLIC SYNTHETIC KEYS - test only", "masterKey": master.base64EncodedString(), "signingSeed": seed.base64EncodedString(), "signingPublic": signing.publicKey.rawRepresentation.base64EncodedString(), "plaintext": payload.base64EncodedString(), "envelope": try JSONSerialization.jsonObject(with: envelope.encoded())]
let output = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
print(String(decoding: output, as: UTF8.self))
