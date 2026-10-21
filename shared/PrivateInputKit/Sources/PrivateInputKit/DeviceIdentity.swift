import Foundation
import CryptoKit
import Security
import Darwin

public enum IdentityStoreError: Error { case absent, alreadyExists, corrupt, busy, exhausted, osStatus(OSStatus) }

public protocol IdentitySecretStore: AnyObject {
    func read() throws -> Data?
    func insert(_ data: Data) throws
    func replace(_ data: Data) throws
}

/// This app's exact service/account only. No shared access group or iCloud sync.
public final class KeychainIdentityStore: IdentitySecretStore {
    private let service: String
    private let account: String
    private let accessGroup: String?
    public init(account: String, testing: Bool = false, accessGroup: String? = nil) throws {
        guard !account.isEmpty, account.utf8.count <= 128 else { throw IdentityStoreError.corrupt }
        service = testing ? "live.linghe.privateinput.sync.tests" : "live.linghe.privateinput.sync"
        self.account = account
        if let accessGroup, accessGroup.isEmpty { throw IdentityStoreError.corrupt }
        self.accessGroup = accessGroup
    }
    private var query: [String: Any] {
        var result: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
        if let accessGroup { result[kSecAttrAccessGroup as String] = accessGroup }
        return result
    }
    public func read() throws -> Data? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw IdentityStoreError.osStatus(status) }
        return data
    }
    public func insert(_ data: Data) throws {
        var q = query; q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        if status == errSecDuplicateItem { throw IdentityStoreError.alreadyExists }
        guard status == errSecSuccess else { throw IdentityStoreError.osStatus(status) }
    }
    public func replace(_ data: Data) throws {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecSuccess else { throw IdentityStoreError.osStatus(status) }
    }
    public func removeForConfirmedDeparture() throws {
        let status=SecItemDelete(query as CFDictionary)
        guard status==errSecSuccess || status==errSecItemNotFound else {throw IdentityStoreError.osStatus(status)}
    }
    // Deliberately no production reset/delete API. Test cleanup matches only a
    // unique account in the separate test service created by this process.
    public func removeTestRecord() throws {
        guard service.hasSuffix(".tests") else { throw IdentityStoreError.corrupt }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw IdentityStoreError.osStatus(status) }
    }
}

struct StoredDeviceIdentity: Codable {
    var version: UInt8 = 1
    var device: UUID
    var signingSeed: Data
    var ownerID: UUID
    var ownerSigningSeed: Data
    var exchangeSecret: Data
    var storageKey: Data
    var reservedSequence: UInt64
    func validate() throws {
        guard version == 1, signingSeed.count == 32, ownerSigningSeed.count == 32, exchangeSecret.count == 32, storageKey.count == 32 else { throw IdentityStoreError.corrupt }
    }
}

public struct DeviceIdentity {
    public let device: UUID
    public let signingKey: Curve25519.Signing.PrivateKey
    public let ownerID: UUID
    public let ownerSigningKey: Curve25519.Signing.PrivateKey
    public let exchangeKey: Curve25519.KeyAgreement.PrivateKey
    public let storageKey: SymmetricKey
    init(_ record: StoredDeviceIdentity) throws {
        try record.validate(); device = record.device
        signingKey = try .init(rawRepresentation: record.signingSeed)
        ownerID = record.ownerID; ownerSigningKey = try .init(rawRepresentation: record.ownerSigningSeed)
        exchangeKey = try .init(rawRepresentation: record.exchangeSecret)
        storageKey = SymmetricKey(data: record.storageKey)
    }
}

/// Every operation rereads the OS secret record while holding the same app-owned
/// cross-process lock. No cached counter, no unlocked read/modify/write race.
public final class DeviceIdentityVault {
    private let store: IdentitySecretStore
    private let lockFile: URL
    private let gate = NSLock()
    public init(store: IdentitySecretStore, directory: URL) throws {
        self.store = store
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        lockFile = directory.appendingPathComponent("identity.lock")
    }
    private func locked<T>(_ action: () throws -> T) throws -> T {
        gate.lock(); defer { gate.unlock() }
        let fd = Darwin.open(lockFile.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw IdentityStoreError.busy }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw IdentityStoreError.busy }
        defer { flock(fd, LOCK_UN) }
        return try action()
    }
    private func record() throws -> StoredDeviceIdentity {
        guard let data = try store.read() else { throw IdentityStoreError.absent }
        guard data.count <= 4096 else { throw IdentityStoreError.corrupt }
        let value = try JSONDecoder().decode(StoredDeviceIdentity.self, from: data)
        try value.validate(); return value
    }
    /// Called by explicit setup; absence during ordinary load never regenerates.
    public func create() throws -> DeviceIdentity {
        try locked {
            guard try store.read() == nil else { throw IdentityStoreError.alreadyExists }
            let signing = Curve25519.Signing.PrivateKey(), owner = Curve25519.Signing.PrivateKey(), exchange = Curve25519.KeyAgreement.PrivateKey()
            let storage = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            let value = StoredDeviceIdentity(device: UUID(), signingSeed: signing.rawRepresentation,
                                             ownerID: UUID(), ownerSigningSeed: owner.rawRepresentation,
                                             exchangeSecret: exchange.rawRepresentation, storageKey: storage, reservedSequence: 0)
            try store.insert(JSONEncoder().encode(value))
            return try DeviceIdentity(value)
        }
    }
    public func load() throws -> DeviceIdentity { try locked { try DeviceIdentity(record()) } }
    /// Persist first, return second. A crash or failed outbox transaction may
    /// skip a sequence, but cannot reuse an already reserved value on restart.
    public func reserveSequence() throws -> (identity: DeviceIdentity, sequence: UInt64) {
        try locked {
            var value = try record()
            guard value.reservedSequence < UInt64.max else { throw IdentityStoreError.exhausted }
            value.reservedSequence += 1
            try store.replace(JSONEncoder().encode(value))
            return (try DeviceIdentity(value), value.reservedSequence)
        }
    }
}
