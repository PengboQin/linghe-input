import SwiftUI
import UIKit
import PrivateInputKit
import UniformTypeIdentifiers


struct DeviceSyncView: View {
    @StateObject private var model: DeviceSyncModel
    private let showsSharedTextLink: Bool
    init(model:DeviceSyncModel? = nil, showsSharedTextLink:Bool = false,initialInvitation:URL? = nil) {
        _model=StateObject(wrappedValue:model ?? DeviceSyncModel.shared);self.showsSharedTextLink=showsSharedTextLink
        _invitation=State(initialValue:initialInvitation?.absoluteString ?? "")
    }
    @State private var server = DeviceSyncDefaults.endpoint
    @State private var invitation = ""
    @State private var accessCode = ""
    @State private var showingScanner = false
    @State private var showingClipboardPermission = false
    private enum EntryFocus: Hashable { case server, invitation }
    @FocusState private var entryFocus: EntryFocus?
    @State private var disconnecting = false
    @State private var showingInvitation = false
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Form {
            if !model.info.configured && !model.info.joining {
                Section("连接我的设备") {
                    TextField("HTTPS 服务器地址", text: $server).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).focused($entryFocus, equals: .server).accessibilityIdentifier("sync-server")
                    Button("建立设备组") { model.run { try await $0.create(endpoint: server) } }.disabled(server.isEmpty).accessibilityIdentifier("sync-create")
                    Button { showingScanner=true } label: {Label("扫描接入二维码",systemImage:"qrcode.viewfinder")}.accessibilityIdentifier("sync-scan")
                    TextField("六位接入码",text:$accessCode).keyboardType(.numberPad).focused($entryFocus,equals:.invitation).accessibilityIdentifier("sync-access-code")
                        .onChange(of:accessCode) { value in accessCode=String(value.filter{ $0.isASCII && $0.isNumber }.prefix(6)) }
                    Button("连接设备") {model.run {try await $0.joinQuick(code:accessCode,endpoint:server)}}.disabled(accessCode.count != 6 || server.isEmpty).accessibilityIdentifier("sync-join")
                }.disabled(model.busy)
            }
            if model.info.configured {
                Section("我的设备") {
                    LabeledContent("设备组", value: "\(model.info.count) 台设备").accessibilityIdentifier("sync-device-count")
                    if model.info.canManage {
                        Button("接入新设备") { model.run {try await $0.makeQuickInvitation()};showingInvitation=true }.accessibilityIdentifier("sync-invite")
                    }
                    Button("退出设备组") { disconnecting = true }.accessibilityIdentifier("sync-disconnect")
                }.disabled(model.busy)
                Section("同步") {
                    Toggle("输入习惯与个人词库", isOn: Binding(get: { model.info.learning }, set: { model.consent(learning: $0, clipboard: model.info.clipboard) })).disabled(model.savingConsent).accessibilityIdentifier("sync-learning")
                    Toggle("按组优化词频", isOn: Binding(get: { model.info.cloudLearning }, set: { model.setCloudLearning($0) })).disabled(model.busy || !model.info.learning).accessibilityIdentifier("sync-cloud-learning")
                    Text("已选词条和词频由所设服务器按组整理，服务器管理员可读。").font(.footnote).foregroundStyle(.secondary)
                    if model.info.cloudLearning { Text(model.info.cloudPhase).font(.footnote).foregroundStyle(.secondary) }
                    Toggle("剪贴板同步", isOn: Binding(get: { model.info.clipboard && model.info.automaticClipboard }, set: { model.setClipboardSynchronization($0) })).disabled(model.busy || model.savingConsent).accessibilityIdentifier("sync-clipboard")
                    if model.info.automaticClipboard && model.info.automaticClipboardReadPaused {Text("剪贴板读取已暂停，可在“剪贴板权限”中检查并重试。").font(.footnote).foregroundStyle(.secondary)}
                    Button("剪贴板权限…") {showingClipboardPermission=true}.accessibilityIdentifier("sync-clipboard-permission")
                    Button("立即同步") { model.run { _ = try await $0.synchronize() } }.disabled(model.busy || model.savingConsent || (!model.info.learning && !model.info.clipboard)).accessibilityIdentifier("sync-now")
                }
            }
            if (model.info.joining || model.info.ownerPending) && !model.info.quickJoining {
                Section("核对设备") {
                    if let code = model.info.code {
                        Text(code).font(.title.monospacedDigit()).accessibilityIdentifier("sync-code")
                        Text("确认两台设备显示的验证码一致。").font(.footnote).foregroundStyle(.secondary)
                        Button("验证码一致，确认连接") { model.run { try await $0.confirmPair() } }.accessibilityIdentifier("sync-confirm")
                    } else if model.info.ownerPending {
                        Button("重试完成连接") { model.run { try await $0.confirmPair() } }.accessibilityIdentifier("sync-retry-confirm")
                    } else {
                        Text("请在已连接的设备中打开加入请求。")
                        Button("获取验证码") { model.run { try await $0.fetchJoiningCode() } }.accessibilityIdentifier("sync-get-code")
                        Button("重发加入请求") { model.run { try await $0.retryJoining() } }.accessibilityIdentifier("sync-retry-join")
                    }
                    if model.info.joining {
                        Button("使用其他邀请") { model.run { try await $0.cancelJoining() } }.accessibilityIdentifier("sync-change-invitation")
                    }
                }.disabled(model.busy)
            }
            if showsSharedTextLink && model.info.configured {
                Section {
                    NavigationLink("共享文本") { SharedTextInboxView(model:model) }.accessibilityIdentifier("sync-open-shared-text")
                }
            }
            if model.info.configured {DeviceMemberSections(model:model)}
            if model.info.quickJoining {PairingWaitSection(model:model)}
            if model.info.departed != nil {Text("此设备已离组，个人词库和共享资料已清除。请重新配对。").foregroundStyle(.secondary)}
            if model.busy { ProgressView().accessibilityIdentifier("sync-foreground-progress") }
            if !model.status.isEmpty { Text(model.status).foregroundStyle(.secondary).accessibilityIdentifier("sync-status").accessibilityValue(model.diagnostic) }
        }
        .navigationTitle("设备与同步")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if entryFocus != nil {
                    Button("完成") { entryFocus = nil }.accessibilityIdentifier("sync-dismiss-keyboard")
                }
            }
        }
        .confirmationDialog("断开此设备的连接？", isPresented: $disconnecting, titleVisibility: .visible) {
            Button("退出并清除本机资料", role: .destructive) { model.run { try await $0.disconnect() } }
        } message: {
            Text("退出后清除本机个人词库、学习记录、共享文本和组密钥，恢复初装词库。此操作无法撤销。")
        }
        .task { await model.reload();if server.isEmpty {server=model.info.endpoint};if let url=URL(string:invitation),url.host=="pair" {model.run {try await $0.joinQuick(link:url)}} }
        .sheet(isPresented:$showingClipboardPermission) {ClipboardPermissionView(model:model)}
        .sheet(isPresented:$showingInvitation) { DeviceInvitationView(model:model) }
        .sheet(isPresented:$showingScanner) { NavigationStack {PairingScannerView {url in showingScanner=false;model.run {try await $0.joinQuick(link:url)}}.navigationTitle("扫描接入二维码").toolbar {ToolbarItem(placement:.cancellationAction) {Button("取消") {showingScanner=false}}}} }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds:(model.info.joining || model.info.ticket != nil) ? 2_000_000_000:15_000_000_000)
                guard !Task.isCancelled else { break }
                await model.poll()
            }
        }
    }
}

private struct ClipboardPermissionView:View {
    @ObservedObject var model:DeviceSyncModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var retried=false
    var body:some View {
        NavigationStack {
            Form {
                Section {
                    Text("如系统设置中显示“从其他 App 粘贴”，可改为“允许”，减少反复询问。")
                    Button("打开系统设置") {
                        if let url=URL(string:UIApplication.openSettingsURLString) {openURL(url)}
                    }.accessibilityIdentifier("clipboard-open-system-settings")
                }
                Section {
                    Button("重新尝试读取") {retried=model.retryAutomaticClipboardRead()}
                        .disabled(!model.info.automaticClipboard || model.savingConsent || model.retryingAutomaticClipboardRead)
                        .accessibilityIdentifier("clipboard-retry-read")
                    if retried {Text("请复制新内容验证。").foregroundStyle(.secondary)}
                } footer: {
                    Text("iOS 决定是否显示该选项及后续粘贴询问。")
                }
            }
            .navigationTitle("剪贴板权限").navigationBarTitleDisplayMode(.inline)
            .toolbar {ToolbarItem(placement:.confirmationAction) {Button("完成") {dismiss()}}}
        }
    }
}
