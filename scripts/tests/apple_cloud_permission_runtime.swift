import Foundation
import PrivateInputKit

// Platform reset source is replaced by a fixed synthetic epoch; all learning,
// rank, coordinator, publication and privacy-fence code under test is real.
enum PersonalDataReset { static let generation = "initial"; static let marker = "privacy-reset-generation-v1.txt" }
struct LearningRefreshSource { let name: String; let url: URL; let maximum: Int; let runtime: Bool }
@main enum Check {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("linghe-cloud-permission-" + UUID().uuidString)
        let suite = "live.linghe.fixture.cloud-permission." + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("Shared"); try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        let group = UUID(uuidString: json["group"] as! String)!, device = UUID(uuidString: json["device"] as! String)!, install = UUID(uuidString: json["installation"] as! String)!
        let policy = try CloudLearningTextPolicy(standardCharacters: Data(contentsOf: URL(fileURLWithPath: "resources/rime/charset/standard-8105.txt")))
        let delta = try JSONDecoder().decode(CloudLearningDelta.self, from: JSONSerialization.data(withJSONObject: (json["pull_initial"] as! [String: Any])["result"]!))
        var model = try CloudLearningReplica(group: group, device: device, installation: install, generation: 1, consentVersion: 1)
        try model.stage(delta, policy: policy)
        let migration = CloudLearningComponentMigration(model: model)
        let now = UInt64(Date().timeIntervalSince1970)
        let state = AppleCloudLearningRankState(version: 2, group: group, membershipEpoch: 1, personalEpoch: "initial", modelVersion: 1,
            expiresAt: now + 600, projection: CloudLearningRankProjection(migration: migration))
        try JSONEncoder().encode(state).write(to: shared.appendingPathComponent(AppleCloudLearningRankState.filename), options: .atomic)
        var assertions = 0
        func check(_ value: Bool) { precondition(value); assertions += 1 }
        prefs.set(true, forKey: "learning-sharing-enabled"); prefs.set(true, forKey: "cloud-learning-enabled")
        prefs.set(group.uuidString, forKey: "cloud-learning-group"); prefs.set(UInt64(1), forKey: "cloud-learning-epoch")
        check(AppleCloudLearningRankState.read(directory: shared, group: group, epoch: 1, preferences: prefs) != nil)
        check(AppleCloudLearningRankState.read(directory: shared, group: UUID(), epoch: 1, preferences: prefs) == nil)
        check(AppleCloudLearningRankState.read(directory: shared, group: group, epoch: 2, preferences: prefs) == nil)
        let bridge = AppleRecencyBridge(directory: shared)
        try bridge.acceptAuthenticated(group: group, epoch: 1, policy: .init(referenceDay: Int(now / 86400), windowDays: 90), unixSeconds: Double(now))
        let coordinator = try LocalLearningCoordinator(base: root, rankingPreferences: prefs)
        _ = try coordinator.checkpoint(exportFile: root.appendingPathComponent("native.tsv"), importFile: root.appendingPathComponent("import.tsv"), publish: nil,
            engineExport: { file in try! Data().write(to: file); return 0 }, engineImport: { _ in preconditionFailure("unexpected native mutation") }, engineReset: { _ in preconditionFailure("unexpected native reset") })
        check(coordinator.scoreSnapshot.isCurrent()); check(!coordinator.scoreSnapshot.scores.isEmpty)
        prefs.set(false, forKey: "cloud-learning-enabled")
        check(!coordinator.scoreSnapshot.isCurrent()) // no checkpoint/network needed to stop cached rank
        check(AppleCloudLearningRankState.read(directory: shared, group: group, epoch: 1, preferences: prefs) == nil)
        prefs.set(true, forKey: "cloud-learning-enabled"); prefs.set(false, forKey: "learning-sharing-enabled")
        check(!coordinator.scoreSnapshot.isCurrent())
        check(AppleCloudLearningRankState.read(directory: shared, group: group, epoch: 1, preferences: prefs) == nil)
        prefs.set(true, forKey: "learning-sharing-enabled"); prefs.set(true, forKey: "cloud-learning-enabled")
        let fresh = try LocalLearningCoordinator(base: root.appendingPathComponent("NoLegacyAnchor"), rankingPreferences: prefs)
        let candidateSnapshot = state.snapshot(producer: UUID(), entries: [], uptime: ProcessInfo.processInfo.systemUptime)
        fresh.stageCloudSnapshot(candidateSnapshot, group: group, epoch: 1, expectedRevision: fresh.rankingRevision)
        check(!fresh.scoreSnapshot.isCurrent()) // staging cannot move visible candidates
        fresh.beginComposition()
        check(fresh.scoreSnapshot.isCurrent()); check(fresh.scoreSnapshot.scores == candidateSnapshot.scores)
        prefs.set(UInt64(2), forKey: "cloud-learning-epoch")
        check(!fresh.scoreSnapshot.isCurrent()) // epoch invalidates cached/frozen source
        fresh.stageCloudSnapshot(candidateSnapshot, group: group, epoch: 1, expectedRevision: fresh.rankingRevision); fresh.beginComposition()
        check(!fresh.scoreSnapshot.isCurrent())
        prefs.set(UInt64(1), forKey: "cloud-learning-epoch")
        prefs.set(false, forKey: "cloud-learning-enabled")
        fresh.stageCloudSnapshot(candidateSnapshot, group: group, epoch: 1, expectedRevision: fresh.rankingRevision); fresh.beginComposition()
        check(!fresh.scoreSnapshot.isCurrent())
        print("{\"assertions\":\(assertions),\"nativeWrites\":0,\"realUserPreferencesTouched\":false}")
    }
}
