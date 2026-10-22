import AppKit
import SwiftUI
import PrivateInputKit
import UniformTypeIdentifiers
import Vision

enum MacSettingsPage: String, CaseIterable, Identifiable {
    case input, lexicon, sharedText, devices, archive, help
    var id: Self { self }
    var title: String {
        switch self { case .input: return "输入"; case .lexicon: return "个人词库"; case .sharedText: return "共享文本"; case .devices: return "设备与同步"; case .archive: return "活动归档"; case .help: return "帮助" }
    }
    var icon: String {
        switch self { case .input: return "keyboard"; case .lexicon: return "character.book.closed"; case .sharedText: return "doc.on.clipboard"; case .devices: return "arrow.triangle.2.circlepath"; case .archive: return "archivebox"; case .help: return "questionmark.circle" }
    }
}
@MainActor final class MacSettingsNavigation: ObservableObject { @Published var selection: MacSettingsPage? = .input }

@MainActor final class DeviceSyncWindow: NSObject, NSWindowDelegate {
    static let shared = DeviceSyncWindow()
    private var window: NSWindow?
    private let navigation = MacSettingsNavigation()
    private var themeObserver: NSObjectProtocol?
    override init() {
        super.init()
        themeObserver=NotificationCenter.default.addObserver(forName:MacThemePreferences.updated,object:nil,queue:.main) { [weak self] _ in
            if let window=self?.window {MacThemePreferences.apply(to:window)}
        }
    }
    deinit {if let themeObserver {NotificationCenter.default.removeObserver(themeObserver)}}
    func show(_ page: MacSettingsPage? = nil) {
        if let page { navigation.selection = page }
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = MacSettingsWindowLayout.makeWindow(rootView: MacSettingsView(navigation:navigation))
        window.delegate = self
        self.window = window; window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) { window = nil }
}

struct MacDeviceSyncView: View {
    @ObservedObject var model: DeviceSyncModel
    @State private var server = DeviceSyncDefaults.endpoint
    @State private var accessCode = ""
    @State private var importingQR = false
    @State private var disconnecting = false
    @State private var showingInvitation = false
    var body: some View {
        Form {
            if !model.info.configured && !model.info.joining {
                Section("连接我的设备") {
                    TextField("HTTPS 服务器地址", text: $server)
                    Button("建立设备组") { model.run { try await $0.create(endpoint: server) } }.disabled(server.isEmpty)
                    TextField("六位接入码",text:$accessCode).onChange(of:accessCode) { value in accessCode=String(value.filter{$0.isASCII && $0.isNumber}.prefix(6)) }
                    Button("连接设备") {model.run {try await $0.joinQuick(code:accessCode,endpoint:server)}}.disabled(accessCode.count != 6 || server.isEmpty)
                    Button("从图片读取接入二维码…") {importingQR=true}
                }.disabled(model.busy)
            }
            if model.info.configured {
                Section("我的设备") {
                    LabeledContent("设备组", value: "\(model.info.count) 台设备")
                    Button("接入新设备") {model.run {try await $0.makeQuickInvitation()};showingInvitation=true}
                    Button("退出设备组") { disconnecting = true }
                }.disabled(model.busy)
                Section("同步") {
                    Toggle("输入习惯与个人词库", isOn: Binding(get: { model.info.learning }, set: { model.consent(learning: $0, clipboard: model.info.clipboard) })).disabled(model.savingConsent)
                    Toggle("按组优化词频", isOn: Binding(get: { model.info.cloudLearning }, set: { model.setCloudLearning($0) })).disabled(model.busy || !model.info.learning).accessibilityIdentifier("sync-cloud-learning")
                    Text("已选词条和词频由所设服务器按组整理，服务器管理员可读。").font(.footnote).foregroundStyle(.secondary)
                    if model.info.cloudLearning { Text(model.info.cloudPhase).font(.footnote).foregroundStyle(.secondary) }
                    Toggle("共享文本", isOn: Binding(get: { model.info.clipboard }, set: { model.consent(learning: model.info.learning, clipboard: $0) })).disabled(model.savingConsent)
                    Toggle("自动同步系统剪贴板",isOn:Binding(get:{model.info.automaticClipboard},set:{model.setAutomaticClipboard($0)})).disabled(model.savingConsent || !model.info.clipboard).accessibilityIdentifier("sync-automatic-clipboard")
                    if model.info.automaticClipboard && model.automaticClipboardPreparing {Text("正在接收已有记录；准备完成后自动接收新的剪贴板文字。").font(.footnote).foregroundStyle(.secondary)}
                    Button("立即同步") { model.run { _ = try await $0.synchronize() } }.disabled(model.busy || model.savingConsent || (!model.info.learning && !model.info.clipboard))
                }
            }
            if (model.info.joining || model.info.ownerPending) && !model.info.quickJoining {
                Section("核对设备") {
                    if let code = model.info.code {
                        Text(code).font(.title.monospacedDigit())
                        Text("确认两台设备显示的验证码一致。").foregroundStyle(.secondary)
                        Button("验证码一致，确认连接") { model.run { try await $0.confirmPair() } }
                    } else if model.info.ownerPending {
                        Button("重试完成连接") { model.run { try await $0.confirmPair() } }
                    } else {
                        Button("获取验证码") { model.run { try await $0.fetchJoiningCode() } }
                        Button("重发加入请求") { model.run { try await $0.retryJoining() } }
                    }
                    if model.info.joining { Button("使用其他邀请") { model.run { try await $0.cancelJoining() } } }
                }.disabled(model.busy)
            }
            if model.info.configured {DeviceMemberSections(model:model)}
            if model.info.quickJoining {PairingWaitSection(model:model)}
            if model.info.departed != nil {Text("此设备已离组，个人词库和共享资料已清除。请重新配对。").foregroundStyle(.secondary)}
            if model.busy { ProgressView() }
            if !model.status.isEmpty { Text(model.status).foregroundStyle(.secondary) }
        }.formStyle(.grouped).task { await model.reload();if server.isEmpty {server=model.info.endpoint} }
        .sheet(isPresented:$showingInvitation) { DeviceInvitationView(model:model) }
        .fileImporter(isPresented:$importingQR,allowedContentTypes:[.image]) { result in
            guard case .success(let url)=result else {return}
            let scoped=url.startAccessingSecurityScopedResource();defer {if scoped {url.stopAccessingSecurityScopedResource()}}
            do {
                let request=VNDetectBarcodesRequest();request.symbologies=[.qr]
                try VNImageRequestHandler(url:url).perform([request])
                guard let value=request.results?.compactMap(\.payloadStringValue).first,let link=URL(string:value),link.scheme=="privateinput",link.host=="pair" else {model.status="图片中没有可用的接入二维码";return}
                model.run {try await $0.joinQuick(link:link)}
            } catch {model.status="无法读取图片，请输入六位接入码"}
        }
        .confirmationDialog("断开此设备的连接？", isPresented: $disconnecting, titleVisibility: .visible) {
            Button("退出并清除本机资料", role: .destructive) { model.run { try await $0.disconnect() } }
        } message: { Text("退出后清除本机个人词库、学习记录、共享文本和组密钥，恢复初装词库。此操作无法撤销。") }
    }
}

struct MacSettingsView: View {
    @ObservedObject var navigation: MacSettingsNavigation
    @ObservedObject private var model = DeviceSyncModel.shared
    @State private var draft = ""
    @State private var theme=MacThemePreferences.current
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        MacSettingsShell(title: (navigation.selection ?? .input).title) {
            List(MacSettingsPage.allCases,selection:$navigation.selection) { page in
                Label(page.title,systemImage:page.icon).tag(page)
                    .accessibilityIdentifier("mac-settings-"+page.rawValue)
            }.listStyle(.sidebar)
        } detail: {
            Group {
                switch navigation.selection ?? .input {
                case .input: InputSettingsView()
                case .lexicon: PersonalLexiconSettings()
                case .sharedText: MacSharedTextView(model:model,draft:$draft,openDevices:{navigation.selection = .devices})
                case .devices: MacDeviceSyncView(model:model)
                case .archive: ActivityArchiveView()
                case .help: InputHelpView()
                }
            }.scrollContentBackground(.hidden)
        }.tint(Color(nsColor:theme.palette(dark:colorScheme == .dark).accent))
        .onReceive(NotificationCenter.default.publisher(for:MacThemePreferences.updated)) {_ in theme=MacThemePreferences.current}
        .task {await model.reload()}

    }
}
