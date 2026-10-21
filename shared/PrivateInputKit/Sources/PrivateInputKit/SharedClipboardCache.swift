import Foundation
import CryptoKit

public enum ClipboardCacheError: Error { case permissionRequired, invalidCache, oversized }
private struct ClipboardCacheWire: Codable {
    let version: UInt8
    let group: UUID
    let expiresAt: UInt64
    let sealed: Data
}
/// Local derived cache only. Identity/group keys never enter this file.
public struct SharedClipboardCache {
    private let file: URL
    public init(directory: URL) { file = directory.appendingPathComponent("clipboard-cache-v1.json") }
    private func aad(group: UUID, expiresAt: UInt64) -> Data {
        var data = Data("PrivateInput/shared-text-cache/v1\0".utf8)
        data.appendUUID(group); data.appendBE(expiresAt); return data
    }
    private func validate(_ clips: [ReceivedClipboard], now: UInt64) throws {
        guard clips.count <= 32, Set(clips.map(\.id)).count == clips.count else { throw ClipboardCacheError.invalidCache }
        var size = 0
        for clip in clips {
            guard !clip.text.isEmpty, !clip.text.contains("\0"), clip.text.utf8.count <= 65536,
                  clip.expiresAt > now, clip.expiresAt - now <= 600 else { throw ClipboardCacheError.invalidCache }
            size += clip.text.utf8.count
        }
        guard size <= 1024 * 1024 else { throw ClipboardCacheError.oversized }
    }
    public func publish(_ clips: [ReceivedClipboard], group: UUID, key: SymmetricKey, now: UInt64) throws {
        guard key.bitCount == 256 else { throw ClipboardCacheError.invalidCache }
        let valid = clips.filter { $0.expiresAt > now }
        try validate(valid, now: now)
        guard let expiry = valid.map(\.expiresAt).max() else { try clear(); return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(valid)
        guard payload.count <= 2 * 1024 * 1024 else { throw ClipboardCacheError.oversized }
        let box = try ChaChaPoly.seal(payload, using: key, authenticating: aad(group: group, expiresAt: expiry))
        let data = try encoder.encode(ClipboardCacheWire(version: 1, group: group, expiresAt: expiry, sealed: box.combined))
        guard data.count <= 3 * 1024 * 1024 else { throw ClipboardCacheError.oversized }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: file, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public func read(group: UUID, fullAccess: Bool, sharingEnabled: Bool, now: UInt64,
                     key: () throws -> SymmetricKey) throws -> [ReceivedClipboard] {
        guard fullAccess && sharingEnabled else { throw ClipboardCacheError.permissionRequired }
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        let maximum = 3 * 1024 * 1024
        var data = Data()
        while data.count <= maximum {
            let chunk = try handle.read(upToCount: min(65536, maximum + 1 - data.count)) ?? Data()
            if chunk.isEmpty { break }; data.append(chunk)
        }
        guard data.count <= maximum else { throw ClipboardCacheError.oversized }
        let wire = try JSONDecoder().decode(ClipboardCacheWire.self, from: data)
        guard wire.version == 1, wire.group == group, wire.sealed.count >= 28 else { throw ClipboardCacheError.invalidCache }
        guard wire.expiresAt > now else { return [] }
        guard wire.expiresAt - now <= 600 else { throw ClipboardCacheError.invalidCache }
        let material = try key(); guard material.bitCount == 256 else { throw ClipboardCacheError.invalidCache }
        let payload = try ChaChaPoly.open(.init(combined: wire.sealed), using: material,
                                        authenticating: aad(group: group, expiresAt: wire.expiresAt))
        guard payload.count <= 2 * 1024 * 1024 else { throw ClipboardCacheError.oversized }
        let all = try JSONDecoder().decode([ReceivedClipboard].self, from: payload)
        guard all.count <= 32, Set(all.map(\.id)).count == all.count,
              all.map(\.expiresAt).max() == wire.expiresAt else { throw ClipboardCacheError.invalidCache }
        let valid = all.filter { $0.expiresAt > now }
        try validate(valid, now: now); return valid
    }
    public func clear() throws {
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}
