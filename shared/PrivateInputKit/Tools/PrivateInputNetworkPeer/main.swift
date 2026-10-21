import Foundation
import PrivateInputKit

// Synthetic counterpart only. No system clipboard, production profiles or
// actual device installation. Secrets stay in this process and encrypted DB.
final class FixtureSecrets: IdentitySecretStore {
    private var value: Data?
    func read() throws -> Data? { value }
    func insert(_ data: Data) throws { guard value == nil else { throw IdentityStoreError.alreadyExists }; value = data }
    func replace(_ data: Data) throws { guard value != nil else { throw IdentityStoreError.absent }; value = data }
}
guard (CommandLine.arguments.count == 4 || (CommandLine.arguments.count == 5 && CommandLine.arguments[4] == "--shared-text-ui")), CommandLine.arguments[3] == "--confirm-synthetic-peer",
      let endpoint = URL(string: CommandLine.arguments[1]), endpoint.host == "127.0.0.1" else { throw PairingError.malformed }
let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard !FileManager.default.fileExists(atPath: root.path) else { throw ReplicaStoreError.changedState }
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
let vault = try DeviceIdentityVault(store: FixtureSecrets(), directory: root.appendingPathComponent("Identity"))
let identity = try vault.create(), store = try SecureReplicaStore(directory: root.appendingPathComponent("Database"), vault: vault)
let initial = try GroupSetup.create(owner: identity), group = initial.membership.anchor.group
try store.initializeGroup(initial)
let client = try RelayClient(endpoint: endpoint, allowLoopbackHTTP: true)
try await client.register(initial.membership)
let invitation = try DeviceInvitation(endpoint: endpoint, anchor: initial.membership.anchor).link(allowLoopbackHTTP: true)
var status: [String: Any] = ["invitation": invitation.absoluteString, "phase": "waiting", "received_from_ios": false]
func saveStatus() throws { try JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]).write(to: root.appendingPathComponent("status.json"), options: .atomic) }
try saveStatus()
let sharedUI = CommandLine.arguments.count == 5
let deadline = Date().addingTimeInterval(sharedUI ? 900 : 240)
var paired = false
while Date() < deadline {
    let now = UInt64(Date().timeIntervalSince1970)
    if !paired {
        let requests = try await client.pendingPairs(group: group, owner: identity, now: now)
        if let request = requests.first {
            let pending = try store.beginPairing(request, group: group, permissions: .all, now: now)
            try await client.publishChallenge(pending.challenge, session: request.session)
            status["code"] = pending.code; status["phase"] = "confirming"; try saveStatus()
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let grant = try store.finishPairing(session: request.session, confirmedCode: pending.code, now: UInt64(Date().timeIntervalSince1970))
            try await client.publishMembership(store.group(group).membership); try await client.publishKey(grant)
            var learning = LearningModel(); try learning.setDeviceCount(reading: "ni hao", text: "拟好", device: identity.device.uuidString, count: 24)
            _ = try store.enqueue(learning.export(), domain: .learning, group: group, sharingEnabled: true, now: now)
            if sharedUI {
                for index in 1...12 {
                    _ = try store.enqueue(Data("合成共享文本第\(index)项，用于验证列表滚动与直接插入。".utf8),domain:.clipboard,group:group,sharingEnabled:true,now:now)
                }
                let long = "共享长文本：" + String(repeating:"这是用于原生页面验收的合成段落，支持连续阅读和按需插入。",count:30) + "全文尾部标记"
                _ = try store.enqueue(Data(long.utf8),domain:.clipboard,group:group,sharingEnabled:true,now:now)
            }
            _ = try store.enqueue(Data("SYNTHETIC-REMOTE-TEXT".utf8), domain: .clipboard, group: group, sharingEnabled: true, now: now)
            paired = true; status["phase"] = "paired"; try saveStatus()
        }
    } else {
        _ = try await RelaySyncPass.run(group: group, store: store, vault: vault, client: client, consent: .init(learning: true, clipboard: true), now: now)
        if try store.clipboard(group: group, now: now).contains(where: { $0.text == (sharedUI ? "syntheticiosmessage" : "SYNTHETIC-IOS-TEXT") }) {
            status["received_from_ios"] = true; try saveStatus()
        }
    }
    try await Task.sleep(nanoseconds: 1_000_000_000)
}
