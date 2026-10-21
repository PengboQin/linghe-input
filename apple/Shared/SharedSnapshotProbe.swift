import Foundation

#if DEBUG && os(iOS)
struct SharedSnapshotProbe: Codable {
    let fullAccess: Bool
    let groupAvailable: Bool
    let snapshotRead: Bool
    let writeAllowed: Bool
    let writeErrorCode: Int?
    static let groupID = "group.live.linghe.privateinput"
    private static let marker = Data("private-input-p1-snapshot-v1".utf8)
    static func prepareInContainingApp() throws {
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            throw NSError(domain: "PrivateInputProbe", code: 1)
        }
        try marker.write(to: group.appendingPathComponent("p1-read-snapshot.dat"), options: .atomic)
    }
    static func runInKeyboard(fullAccess: Bool) -> Self {
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            return .init(fullAccess: fullAccess, groupAvailable: false, snapshotRead: false, writeAllowed: false, writeErrorCode: nil)
        }
        let canRead = (try? Data(contentsOf: group.appendingPathComponent("p1-read-snapshot.dat"))) == marker
        // P1-only OS permission experiment. Real product code must never attempt
        // group writes without hasFullAccess; this probe holds no user data.
        let file = group.appendingPathComponent("p1-write-probe-" + UUID().uuidString + ".dat")
        do {
            try Data("p1-write-only-fixture".utf8).write(to: file, options: .atomic)
            try? FileManager.default.removeItem(at: file)
            return .init(fullAccess: fullAccess, groupAvailable: true, snapshotRead: canRead, writeAllowed: true, writeErrorCode: nil)
        } catch {
            return .init(fullAccess: fullAccess, groupAvailable: true, snapshotRead: canRead, writeAllowed: false, writeErrorCode: (error as NSError).code)
        }
    }
    var label: String {
        "权限" + (fullAccess ? "开" : "关") + "·快照" + (snapshotRead ? "可读" : "不可读") + "·写入" + (writeAllowed ? "允许" : "拒绝")
    }
}
#endif
