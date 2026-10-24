import SwiftUI
import PrivateInputKit

@MainActor final class ActivityArchiveModel: ObservableObject {
    static let shared = ActivityArchiveModel()
    @Published private(set) var configuration = ActivityConfiguration()
    @Published private(set) var queueStatus: ActivityQueueStatus?
    @Published private(set) var serverEnabled = false
    @Published private(set) var busy = false
    @Published var server = ""
    @Published var inputEnabled = true
    @Published var clipboardEnabled = false
    @Published var diagnosticEnabled = false
    @Published var allowGroupReaders = false
    @Published var retentionDays = 30
    @Published var groupMegabytes = 100
    @Published private(set) var message = ""
    @Published private(set) var connected = false
    @Published private(set) var canManageGroup = false
    private var connection: ActivityArchiveLiveConnection?
    private var queue: ActivityLocalEventQueue?
    private var remoteStatus: ActivityServerStatus?
    private var applying = false
    private var lastBackground = Date.distantPast

    func reload() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            try await loadContext(refresh: true)
            guard let q = queue else { return }
            configuration = try q.configuration(); queueStatus = try q.status()
            if server.isEmpty { server = configuration.endpoint?.absoluteString ?? connection?.publicConnection.relayEndpoint.absoluteString ?? "" }
            diagnosticEnabled = configuration.providers.contains(ActivityInputDiagnostic.provider)
            if !configuration.providers.isEmpty {
                inputEnabled = configuration.providers.contains("ime.commit.v1")
                clipboardEnabled = configuration.providers.contains("clipboard.observed.v1")
            }
            if let endpoint = configuration.endpoint { try await readStatus(endpoint: endpoint) }
            message = ""
        } catch { report(error) }
    }
    func connect() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            try await loadContext(refresh: true)
            guard let endpoint = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw ActivityError.invalidEndpoint }
            _ = try ActivityHTTPTransport(endpoint: endpoint)
            try await readStatus(endpoint: endpoint)
            if let q = queue {
                var value = try q.configuration()
                if value.endpoint != endpoint {
                    value.enabled = false; value.consentVersion = 0; value.endpoint = endpoint
                    _ = try q.configure(value); configuration = value
                    ActivityArchiveCapture.shared.stop()
                }
            }
            message = "已连接，归档仍由组和本设备分别控制"
        } catch { report(error) }
    }
    func setGroup(enabled: Bool) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            try await loadContext(refresh: true)
            guard let live = connection, let endpoint = URL(string: server), canManageGroup else { throw ActivityError.invalidConfiguration }
            let client = try ActivityArchiveClient(endpoint: endpoint)
            let status = try await client.status(group: live.publicConnection.group, identity: live.identity, now: now)
            _ = try await client.setGroupPolicy(group: live.publicConnection.group, identity: live.identity,
                                                expectedVersion: status.policyVersion, enabled: enabled,
                                                retentionDays: retentionDays, maxGroupBytes: Int64(groupMegabytes) * 1048576, now: now)
            try await readStatus(endpoint: endpoint)
            if !enabled, let queue {
                try queue.invalidateAuthorization(); configuration = try queue.configuration()
                ActivityArchiveCapture.shared.stop(); queueStatus = try queue.status()
            }
            message = enabled ? "本组允许归档；每台设备仍需单独开启" : "本组归档已关闭"
        } catch { report(error) }
    }
    func setEnabled(_ enabled: Bool) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            try await loadContext(refresh: enabled)
            guard let live = connection, let queue else { throw ActivityError.invalidConfiguration }
            if !enabled {
                var stopped = try queue.configuration(); stopped.enabled = false
                _ = try queue.configure(stopped); configuration = stopped
                ActivityArchiveCapture.shared.stop()
                queueStatus = try queue.status()
                guard let endpoint = stopped.endpoint else { return }
                let client = try ActivityArchiveClient(endpoint: endpoint)
                let status = try await client.status(group: live.publicConnection.group, identity: live.identity, now: now)
                let providers = Set(status.consent?.providers ?? Array(selectedProviders))
                let readers = Set(status.consent?.readers ?? [live.identity.device])
                _ = try await client.setDeviceConsent(group: live.publicConnection.group, identity: live.identity,
                                                      expectedVersion: status.consent?.version ?? 0, enabled: false,
                                                      providers: providers, readers: readers, now: now)
                message = "已停止本设备归档，未上传记录已隔离保留"
            } else { try await applyEnabled(live: live, queue: queue) }
        } catch { report(error) }
    }
    func applyDeviceSettings() async {
        if configuration.enabled { await setEnabled(true); return }
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            try await loadContext(refresh: false)
            guard let queue, let endpoint = URL(string: server) else { throw ActivityError.invalidConfiguration }
            var value = try queue.configuration(); value.endpoint = endpoint; value.providers = selectedProviders
            _ = try queue.configure(value); configuration = value; message = "设置已保存，记录保持关闭"
        } catch { report(error) }
    }
    func pause(_ paused: Bool) {
        guard !busy, let queue else { return }
        // Apply local fencing before scheduling any async work or a remote call.
        do {
            var value = try queue.configuration(); value.paused = paused
            _ = try queue.configure(value); configuration = value; queueStatus = try queue.status()
            ActivityArchiveCapture.shared.stop()
            if !paused { ActivityArchiveCapture.shared.refresh(permitted: true, force: true) }
            message = paused ? "已暂停；恢复后只记录新的内容" : "已恢复，旧待发记录仍隔离保留"
        } catch { report(error) }
    }
    /// Called while the main app is active, and by the Mac application background owner.
    /// It refreshes existing relay membership normally and never requires a settings window.
    func backgroundPass(validating:()->Bool={true}) async {
        guard !Task.isCancelled,validating(),!busy, !applying, Date().timeIntervalSince(lastBackground) >= 5 else { return }
        lastBackground = Date(); applying = true; defer { applying = false }
        do {
            // Do not create a sync identity/group or contact the archive by merely launching.
            guard let publicConnection = try? ActivityArchiveLocation.load() else { return }
            let q = try ActivityArchiveLocation.queue(publicConnection), value = try q.configuration()
            guard value.collecting else { return }
            try await loadContext(refresh: true)
            guard !Task.isCancelled,validating(),let live = connection, let q = queue, let endpoint = value.endpoint else { return }
            ActivityArchiveCapture.shared.refresh(permitted: true)
            ActivityArchiveCapture.shared.observeClipboardIfPermitted(active:validating() && !Task.isCancelled)
            let client = try ActivityArchiveClient(endpoint: endpoint), worker = ActivityArchiveWorker(queue: q, client: client)
            _ = try await worker.flush(identity: live.identity, membershipRevision: live.publicConnection.membership.revision, now: now)
            guard !Task.isCancelled,validating() else{return}
            queueStatus = try q.status(); configuration = try q.configuration()
        } catch { if !Task.isCancelled,validating() {report(error)} }
    }
    private var now: UInt64 { UInt64(Date().timeIntervalSince1970) }
    private var selectedProviders: Set<String> {
        var values: Set<String> = []
        if inputEnabled { values.formUnion(["ime.commit.v1", "ime.paste.v1"]) }
        if clipboardEnabled { values.insert("clipboard.observed.v1") }
        if diagnosticEnabled { values.insert(ActivityInputDiagnostic.provider) }
        return values
    }
    private func loadContext(refresh: Bool) async throws {
        guard let session = DeviceSyncModel.shared.session else { throw ReplicaStoreError.missingGroup }
        let live = try await session.archiveConnection(refresh: refresh)
        try ActivityArchiveLocation.publish(live.publicConnection)
        connection = live; queue = try ActivityArchiveLocation.queue(live.publicConnection); connected = true
        canManageGroup = try live.publicConnection.verified().member(live.identity.device).permissions == .all
    }
    private func readStatus(endpoint: URL) async throws {
        guard let live = connection else { throw ReplicaStoreError.missingGroup }
        let status = try await ActivityArchiveClient(endpoint: endpoint).status(group: live.publicConnection.group, identity: live.identity, now: now)
        guard status.membershipRevision == live.publicConnection.membership.revision else { throw ActivityError.staleAuthorization }
        remoteStatus = status; serverEnabled = status.enabled
        retentionDays = status.limits.retentionDays; groupMegabytes = max(1, Int(status.limits.maxGroupBytes / 1048576))
        allowGroupReaders = Set(status.consent?.readers ?? []).subtracting([live.identity.device]).isEmpty == false
    }
    private func applyEnabled(live: ActivityArchiveLiveConnection, queue: ActivityLocalEventQueue) async throws {
        guard let endpoint = URL(string: server), !selectedProviders.isEmpty else { throw ActivityError.invalidConfiguration }
        let client = try ActivityArchiveClient(endpoint: endpoint)
        let status = try await client.status(group: live.publicConnection.group, identity: live.identity, now: now)
        guard status.enabled else { throw ActivityError.serverDisabled }
        guard status.membershipRevision == live.publicConnection.membership.revision else { throw ActivityError.staleAuthorization }
        // Fence old collectors before changing server consent. A failed request leaves
        // them stopped rather than letting a stale grant keep collecting silently.
        var stopped = try queue.configuration(); stopped.enabled = false
        _ = try queue.configure(stopped); ActivityArchiveCapture.shared.stop()
        let readers: Set<UUID> = allowGroupReaders ? Set(live.publicConnection.membership.members.map(\.device)) : [live.identity.device]
        let consent = try await client.setDeviceConsent(group: live.publicConnection.group, identity: live.identity,
                                                        expectedVersion: status.consent?.version ?? 0, enabled: true,
                                                        providers: selectedProviders, readers: readers, now: now)
        let delegate = try ActivityArchiveDelegateKeys.load(connection: live.publicConnection, create: true)
        _ = try await client.registerDelegate(group: live.publicConnection.group, identity: live.identity,
                                               expectedConsentVersion: consent.consentVersion,
                                               publicKey: delegate.signingKey.publicKey.rawRepresentation, now: now)
        let value = ActivityConfiguration(enabled: true, endpoint: endpoint, providers: selectedProviders,
                                          excludedSourceApps: stopped.excludedSourceApps, consentVersion: consent.consentVersion,
                                          maxQueueBytes: stopped.maxQueueBytes, maxQueueEvents: stopped.maxQueueEvents)
        _ = try queue.configure(value); configuration = value; queueStatus = try queue.status(); serverEnabled = true
        ActivityArchiveCapture.shared.resetClipboardObservationAttempts()
        ActivityArchiveCapture.shared.refresh(permitted: true, force: true)
        message = "已开启；服务器将保存所选来源的完整明文"
    }
    private func report(_ error: Error) {
        if let queue { configuration = (try? queue.configuration()) ?? configuration; queueStatus = try? queue.status() }
        switch error {
        case ReplicaStoreError.missingGroup: connected = false; message = "先在设备与同步中连接设备组"
        case ActivityError.serverDisabled: serverEnabled = false; message = "本组尚未允许归档，请先开启组归档"
        case ActivityError.invalidEndpoint: message = "请填写有效的 HTTPS 归档服务器地址"
        case ActivityError.quotaExceeded: message = "本机归档空间已满，输入仍可正常使用"
        case ActivityError.consentMismatch, ActivityError.staleAuthorization: message = "授权已变化，请重新连接并确认本设备设置"
        default: message = configuration.enabled ? "归档暂不可用，现有记录已保留，输入不受影响" : "本机记录保持关闭；服务器操作未完成，可重试"
        }
    }
}

struct ActivityArchiveView: View {
    @ObservedObject private var model = ActivityArchiveModel.shared
    @State private var confirmingEnable = false
    var body: some View {
        Form {
            Section {
                TextField("HTTPS 归档服务器地址", text: $model.server)
                    .accessibilityIdentifier("archive-endpoint")
                Button("连接并查看组设置") { Task { await model.connect() } }.disabled(model.busy || model.server.isEmpty)
            } header: { Text("归档服务器") } footer: {
                Text("完整原文以明文存放在你选择的服务器。服务器管理员能够读取；与加密词库和共享文本同步分开控制。")
            }
            if model.connected {
                Section("设备组") {
                    Toggle("本组允许归档", isOn: Binding(get: { model.serverEnabled }, set: { value in Task { await model.setGroup(enabled: value) } }))
                        .disabled(model.busy || !model.canManageGroup)
                    Stepper("保留 \(model.retentionDays) 天", value: $model.retentionDays, in: 1...3650).disabled(model.busy || !model.canManageGroup)
                    Stepper("组容量 \(model.groupMegabytes) MB", value: $model.groupMegabytes, in: 1...1024).disabled(model.busy || !model.canManageGroup)
                    Button("保存组策略") { Task { await model.setGroup(enabled: model.serverEnabled) } }.disabled(model.busy || !model.canManageGroup)
                }
                Section {
                    Toggle("记录本设备", isOn: Binding(get: { model.configuration.enabled }, set: { value in
                        if value { confirmingEnable = true } else { Task { await model.setEnabled(false) } }
                    })).accessibilityIdentifier("archive-enabled").disabled(model.busy)
                    Toggle("输入法输出与明确粘贴", isOn: $model.inputEnabled)
                    Toggle("实际可读的剪贴板文字", isOn: $model.clipboardEnabled)
                    Toggle("输入过程与未选中拼音", isOn: $model.diagnosticEnabled)
                    Text("仅记录本输入法处理的按键和候选过程；包含未发送内容。密码与未知安全字段不记录。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Picker("档案读取范围", selection: $model.allowGroupReaders) {
                        Text("仅此设备").tag(false)
                        Text("允许当前本组设备").tag(true)
                    }
                    Button("应用本设备设置") { Task { await model.applyDeviceSettings() } }.disabled(model.busy)
                    if model.configuration.enabled {
                        Toggle("暂停记录", isOn: Binding(get: { model.configuration.paused }, set: { model.pause($0) })).disabled(model.busy)
                    }
                } header: { Text("本设备") } footer: {
                    Text("每台设备单独开启。复制记录不代表已粘贴，上屏不代表已发送。输入记录不采集密码与未知安全字段；剪贴板记录系统实际允许读取的文字。iOS 仅在 App 活跃或键盘实际可用且允许完全访问时工作。")
                }
                if let status = model.queueStatus {
                    Section("本机状态") {
                        LabeledContent("待上传", value: String(status.pending))
                        LabeledContent("隔离保留", value: String(status.held))
                        LabeledContent("已收到归档回执", value: String(status.acknowledged))
                        LabeledContent("正文与事件", value: ByteCountFormatter.string(fromByteCount: Int64(status.payloadBytes), countStyle: .file))
                        Button("立即上传") { Task { await model.backgroundPass() } }.disabled(model.busy || !model.configuration.collecting)
                        Text("关闭或暂停后，原待发记录不会在重新开启时自动上传。离组清除本机归档；服务器已有档案另按保留与删除策略处理。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            if !model.message.isEmpty { Section { Text(model.message).foregroundStyle(.secondary) } }
            if model.busy { ProgressView() }
        }.formStyle(.grouped).navigationTitle("隐私与归档")
            .task { await model.reload() }
            .confirmationDialog("开启本设备明文归档？", isPresented: $confirmingEnable, titleVisibility: .visible) {
                Button("开启所选来源") { Task { await model.setEnabled(true) } }
            } message: { Text("之后所选来源的完整文字将排队上传到 \(model.server)。服务器管理员能够读取原文，其他组成员不会自动开启。") }
    }
}
