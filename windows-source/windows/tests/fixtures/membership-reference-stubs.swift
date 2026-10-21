// Compile-only adapters for running the current public Membership.swift in a
// standalone local fixture. They do not create a product identity or group.
import Foundation
import CryptoKit
public struct DeviceIdentity {
 public let device:UUID
 public let ownerID:UUID
 public let signingKey:Curve25519.Signing.PrivateKey
 public let ownerSigningKey:Curve25519.Signing.PrivateKey
 public let exchangeKey:Curve25519.KeyAgreement.PrivateKey
}
public enum SyncDomain {case learning,clipboard}
public struct SyncTrust {
 public let group:UUID
 public let epoch:UInt64
 public let members:[UUID:Data]
}
extension Data {
 mutating func appendBE(_ value:UInt64){var big=value.bigEndian;Swift.withUnsafeBytes(of:&big){append(contentsOf:$0)}}
 mutating func appendUUID(_ value:UUID){var bytes=value.uuid;Swift.withUnsafeBytes(of:&bytes){append(contentsOf:$0)}}
}
