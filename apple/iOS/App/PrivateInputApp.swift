import SwiftUI
import PrivateInputKit
import CryptoKit
@main struct PrivateInputApp: App {
    init() {ClipboardCacheCoordinator.configureMarkerProbe(arguments:ProcessInfo.processInfo.arguments)}
    var body: some Scene { WindowGroup { SetupView().modifier(InputThemeModifier()) } }
}
struct SetupView: View {
    private struct IncomingInvitation:Identifiable { let id=UUID();let url:URL }
    @State private var incomingInvitation:IncomingInvitation?
    @StateObject private var engine = NativeEngine()
    @StateObject private var syncModel=DeviceSyncModel.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var cloudMigrationInvoked = false
    @State private var sample = ""
    @FocusState private var sampleFocused: Bool
    @State private var testResult = ""
    @State private var snapshotResult = ""
    @State private var learningFixtureResult = ""
    @State private var learningFixtureChecksum = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("启用键盘") {
                    Text("打开系统设置，进入“键盘”，启用灵鹤输入法。").font(.footnote).foregroundStyle(.secondary)
                    Button("打开设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                Section("完全访问") {
                    NavigationLink("开启方法与权限说明") { KeyboardPermissionHelpView() }.accessibilityIdentifier("open-keyboard-permissions")
                    Text("在键盘使用共享设置、词库和共享文本，需要“允许完全访问”。基础打字和本机纠错可离线使用。").font(.footnote).foregroundStyle(.secondary)
                }
                Section("试打") {
                    TextField("输入一些文字", text: $sample, axis: .vertical).focused($sampleFocused).accessibilityIdentifier("sample-text")
                    Button("清空") { sample = "" }.accessibilityIdentifier("clear-sample")
                    #if targetEnvironment(simulator)
                    Button("合成上下文") {sample="今天我的";sampleFocused=true}.accessibilityIdentifier("seed-context")
                    #endif
                }
                Section("输入设置") {
                    LabeledContent("中文词库", value: engine.ready ? "已准备" : "准备失败")
                    NavigationLink("键盘与词库") { InputSettingsView() }
                    NavigationLink("使用帮助") { InputHelpView() }
                    NavigationLink("隐私与开源许可") { AppLegalView() }.accessibilityIdentifier("open-legal")
                    NavigationLink("共享文本") { SharedTextEntryView() }.accessibilityIdentifier("open-shared-inbox")
                    NavigationLink("设备与同步") { DeviceSyncView() }.accessibilityIdentifier("open-sync")
                    NavigationLink("活动归档") { ActivityArchiveView() }.accessibilityIdentifier("open-activity-archive")
                }
                #if DEBUG
                Section("开发验证") {
                    NavigationLink("系统输入验证") { NativeKeyboardHostProbe().navigationTitle("系统输入验证") }.accessibilityIdentifier("open-native-host-probe")
                    Button("准备学习快照") {
                        do {
                            var model = LearningModel()
                            try model.setDeviceCount(reading: "ni hao", text: "拟好", device: "synthetic-peer", count: 1000)
                            guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: LocalLearningCoordinator.groupID) else { throw LearningSyncFailure.engineUnavailable }
                            try SharedLearningSnapshot(directory: directory).publish(model.export(), by: .containingApp)
                            UserDefaults(suiteName: LocalLearningCoordinator.groupID)?.set(true, forKey: "learning-sharing-enabled")
                            learningFixtureResult = "学习快照已准备"
                        } catch { learningFixtureResult = "学习快照准备失败" }
                    }.accessibilityIdentifier("prepare-learning-fixture")
                    if !learningFixtureResult.isEmpty { Text(learningFixtureResult).accessibilityIdentifier("learning-fixture-result") }
                    Button("核对共享快照") {
                        do {
                            guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: LocalLearningCoordinator.groupID) else { throw LearningSyncFailure.engineUnavailable }
                            let data = try Data(contentsOf: directory.appendingPathComponent("learning-v1.json"))
                            learningFixtureChecksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                        } catch { learningFixtureChecksum = "快照读取失败" }
                    }.accessibilityIdentifier("check-learning-checksum")
                    if !learningFixtureChecksum.isEmpty { Text(learningFixtureChecksum).accessibilityIdentifier("learning-checksum") }
                    Button("准备共享快照") {
                        do { try SharedSnapshotProbe.prepareInContainingApp(); snapshotResult = "共享快照已准备" }
                        catch { snapshotResult = "共享快照准备失败" }
                    }.accessibilityIdentifier("prepare-snapshot")
                    if !snapshotResult.isEmpty { Text(snapshotResult).accessibilityIdentifier("snapshot-result") }
                    Button("验证离线候选") {
                        engine.clear()
                        for char in "nihao".utf8 { _ = engine.key(Int32(char)) }
                        testResult = engine.candidates.contains("你好") ? "候选验证通过" : "候选验证失败"
                        engine.clear()
                    }.accessibilityIdentifier("engine-smoke")
                    if !testResult.isEmpty { Text(testResult).accessibilityIdentifier("engine-result") }
                }
                #endif
            }.navigationTitle("灵鹤输入法")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        if sampleFocused { Button("完成") { sampleFocused = false }.accessibilityIdentifier("dismiss-keyboard") }
                    }
                }
        }
        .task(id:scenePhase) {
            syncModel.setClipboardActive(scenePhase == .active)
            guard scenePhase == .active else {return}
            if ProcessInfo.processInfo.arguments.contains("--export-keyboard-runtime-diagnostics") {
                try? KeyboardRuntimeDiagnostics.exportToContainingApp()
            }
            if !cloudMigrationInvoked, ProcessInfo.processInfo.arguments.contains("--migrate-cloud-learning") {
                cloudMigrationInvoked = true
                syncModel.setCloudLearning(true)
            }
            while !Task.isCancelled {
                await syncModel.poll()
                guard !Task.isCancelled,scenePhase == .active,UIApplication.shared.applicationState == .active else{return}
                await ActivityArchiveModel.shared.backgroundPass(validating:{
                    !Task.isCancelled && UIApplication.shared.applicationState == .active
                })
                try? await Task.sleep(nanoseconds:syncModel.info.ticket != nil || syncModel.info.joining ? 2_000_000_000:15_000_000_000)
            }
        }
        .onOpenURL { url in
            guard (try? DeviceInvitation.decode(url)) != nil || (try? QuickPairQR.decode(url,now:UInt64(Date().timeIntervalSince1970))) != nil else { return }
            incomingInvitation=IncomingInvitation(url:url)
        }
        .sheet(item:$incomingInvitation) { invitation in
            NavigationStack {
                DeviceSyncView(initialInvitation:invitation.url)
                    .toolbar { ToolbarItem(placement:.cancellationAction) { Button("完成") { incomingInvitation=nil } } }
            }
        }
    }
}
