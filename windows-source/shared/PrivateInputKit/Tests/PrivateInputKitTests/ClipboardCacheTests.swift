import XCTest
import CryptoKit
@testable import PrivateInputKit

final class ClipboardCacheTests: XCTestCase {
    func testEncryptedCacheBoundToGroupAndReaderDoesNotWrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PrivateInput-Cache-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = SharedClipboardCache(directory: root), group = UUID(), key = SymmetricKey(size: .bits256)
        let clips = [ReceivedClipboard(id: UUID(), sender: UUID(), text: "SYNTHETIC-CACHE-SECRET", expiresAt: 1100)]
        try cache.publish(clips, group: group, key: key, now: 1000)
        let file = root.appendingPathComponent("clipboard-cache-v1.json"), before = try Data(contentsOf: file)
        XCTAssertNil(before.range(of: Data(clips[0].text.utf8)))
        XCTAssertEqual(try cache.read(group: group, fullAccess: true, sharingEnabled: true, now: 1010, key: { key }), clips)
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertThrowsError(try cache.read(group: UUID(), fullAccess: true, sharingEnabled: true, now: 1010, key: { key }))
        XCTAssertThrowsError(try cache.read(group: group, fullAccess: true, sharingEnabled: true, now: 1010, key: { SymmetricKey(size: .bits256) }))
    }
    func testPermissionAndExpiryFailBeforeKeyLookup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PrivateInput-Cache-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = SharedClipboardCache(directory: root), group = UUID(), key = SymmetricKey(size: .bits256)
        try cache.publish([.init(id: UUID(), sender: UUID(), text: "OWN-TEST", expiresAt: 1100)], group: group, key: key, now: 1000)
        var calls = 0
        let readKey: () throws -> SymmetricKey = { calls += 1; return key }
        XCTAssertThrowsError(try cache.read(group: group, fullAccess: false, sharingEnabled: true, now: 1010, key: readKey))
        XCTAssertThrowsError(try cache.read(group: group, fullAccess: true, sharingEnabled: false, now: 1010, key: readKey))
        XCTAssertEqual(try cache.read(group: group, fullAccess: true, sharingEnabled: true, now: 1100, key: readKey), [])
        XCTAssertEqual(calls, 0)
    }
    func testTamperingInvalidPayloadAndClear() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PrivateInput-Cache-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = SharedClipboardCache(directory: root), group = UUID(), key = SymmetricKey(size: .bits256)
        XCTAssertThrowsError(try cache.publish([.init(id: UUID(), sender: UUID(), text: "bad\0text", expiresAt: 1100)], group: group, key: key, now: 1000))
        try cache.publish([.init(id: UUID(), sender: UUID(), text: "OWN-TEST", expiresAt: 1100)], group: group, key: key, now: 1000)
        let file = root.appendingPathComponent("clipboard-cache-v1.json")
        var wire = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        wire["expiresAt"] = 1200
        try JSONSerialization.data(withJSONObject: wire).write(to: file)
        XCTAssertThrowsError(try cache.read(group: group, fullAccess: true, sharingEnabled: true, now: 1010, key: { key }))
        try cache.clear(); XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
