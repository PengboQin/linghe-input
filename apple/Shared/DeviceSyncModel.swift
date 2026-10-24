import Foundation
import Combine
import PrivateInputKit

@MainActor final class DeviceSyncModel: ObservableObject {
    @Published var info = DeviceSyncInfo()
    @Published var status = ""
    @Published var busy = false
    @Published var diagnostic = ""
    @Published var savingConsent = false
    @Published var automaticClipboardPreparing=false
    @Published var retryingAutomaticClipboardRead=false
    private var automaticClipboardReadRetryTask:Task<Void,Never>?
    private var polling = false
    private let automaticClipboard=AutomaticClipboardBridge()
    #if os(iOS)
    private var clipboardActive=false
    #else
    private var clipboardActive=true
    #endif
    private var liveClipboardTimer:Task<Void,Never>?
    func setClipboardActive(_ value:Bool) {
        clipboardActive=value
        if !value {
            automaticClipboard.pause();automaticClipboardReadRetryTask?.cancel()
            liveClipboardTimer?.cancel();liveClipboardTimer=nil;ClipboardLiveCoordinator.shared.suspend()
        } else {startLiveClipboard()}
    }
    private func startLiveClipboard() {
        guard liveClipboardTimer==nil else{return}
        liveClipboardTimer=Task { [weak self] in
            while !Task.isCancelled {
                guard let self else{return}
                if self.clipboardActive {
                    ClipboardLiveCoordinator.shared.tick(fullAccess:true,validating:{[weak self] in self?.clipboardActive==true})
                }
                try? await Task.sleep(nanoseconds:1_000_000_000)
            }
        }
    }
    private var background:Task<Void,Never>?
    static let shared=DeviceSyncModel()
    #if os(macOS)
    func startBackgroundPairing() {
        guard background==nil else {return}
        startLiveClipboard()
        background=Task { [weak self] in
            var pass=0
            while !Task.isCancelled {
                guard let self else {return}
                await self.poll(pairingOnly:pass % 3 != 0);pass += 1
                await ActivityArchiveModel.shared.backgroundPass()
                try? await Task.sleep(nanoseconds:self.info.ticket != nil || self.info.joining ? 2_000_000_000:5_000_000_000)
            }
        }
    }
    #endif
    // Views share one authority; reopening a screen cannot retain stale
    // consent while another session writes the same configuration file.
    private static let sharedSession = try? DeviceSyncSession()
    let session: DeviceSyncSession?
    convenience init() { self.init(session:Self.sharedSession) }
    init(session:DeviceSyncSession?) { self.session=session }
    func sharedText(id:UUID,now:UInt64=UInt64(Date().timeIntervalSince1970)) -> String? {
        guard info.configured,info.clipboard,!savingConsent,
              let clip=info.clips.first(where:{$0.id==id && $0.expiresAt>now}) else { return nil }
        return clip.text
    }
    func run(_ action: @escaping (DeviceSyncSession) async throws -> Void) {
        guard !busy, let session else { return }
        busy = true
        Task {
            // Keep the action the user just tapped. An invisible automatic pass
            // may finish first, but must never swallow that explicit action.
            while polling {if Task.isCancelled {busy=false;return};try? await Task.sleep(nanoseconds:50_000_000)}
            _ = await perform(action, using:session)
        }
    }
    private func perform(_ action: (DeviceSyncSession) async throws -> Void, using session:DeviceSyncSession) async -> Bool {
        defer { busy = false }
            do { try await action(session); info = try await session.info(); status = ""; return true }
            catch {
                #if targetEnvironment(simulator)
                diagnostic = String(reflecting:error)
                #elseif DEBUG
                if case IdentityStoreError.osStatus(let code) = error { diagnostic = "identity_status=\(code)" }
                else if let network = error as? URLError { diagnostic = "network_status=\(network.code.rawValue)" }
                else if case RelayClientError.httpStatus(let code) = error { diagnostic = "http_status=\(code)" }
                else { diagnostic = String(reflecting: type(of: error)) }
                #endif
                if case ReplicaStoreError.sharingDisabled = error { status = "" }
                else if case ReplicaStoreError.quota = error { status = "本机存储已达上限，现有数据已保留" }
                else if case RelayClientError.httpStatus(let code) = error {
                    status = code == 429 ? "尝试过于频繁，请稍后重试" : (code == 404 || code == 403 ? "接入码无效或已使用，请重新生成" : "连接失败，可重试")
                } else if case PairingError.expired = error { status = "邀请已过期，请重新发送加入请求" }
                else { status = "操作未完成，数据已保留，可重试" }
                if let retained = try? await session.info() { info = retained }
                return false
            }
    }
    /// Periodic work never toggles the foreground spinner or disables the form.
    func poll(pairingOnly:Bool=false) async {
        guard !busy,!polling,!savingConsent,!info.joiningExpired,let session else { return }
        polling=true;defer { polling=false }
        do {
            try await session.pollPairing()
            guard !Task.isCancelled else{return}
            let current=try await session.info()
            guard !Task.isCancelled else{return}
            let auto=clipboardActive ? try await session.automaticClipboardSession():nil
            let liveOwns=clipboardActive && ClipboardLiveCoordinator.shared.isActive
            let upload=clipboardActive && !liveOwns ? automaticClipboard.prepare(auto):nil
            if !clipboardActive {automaticClipboard.pause()}
            automaticClipboardPreparing=automaticClipboard.initializing
            if let upload {
                try await session.enqueueAutomaticClipboard(text:upload.text,scope:upload.scope)
                automaticClipboard.queued(upload)
            }
            if (!pairingOnly || upload != nil) && current.configured && (current.learning || current.clipboard) {
                if !liveOwns {automaticClipboard.begin()}
                let result=try await session.synchronize()
                guard !Task.isCancelled else {automaticClipboard.pause();return}
                let after=clipboardActive ? try await session.automaticClipboardSession():nil
                if clipboardActive,!liveOwns,!ClipboardLiveCoordinator.shared.isActive {await automaticClipboard.finish(after,received:result.received,now:UInt64(Date().timeIntervalSince1970),validating:{self.clipboardActive && !ClipboardLiveCoordinator.shared.isActive})}
                else {automaticClipboard.pause()}
                automaticClipboardPreparing=automaticClipboard.initializing
            }
            let next=try await session.info();if info != next {info=next}
            if !status.isEmpty { status="" }
        } catch {
            if info.joining || info.ownerPending || info.ticket != nil {
                if case PairingError.expired=error {status="连接已超时，请重新扫码或输入新的接入码"}
                else if let network=error as? URLError {status=network.code == .timedOut ? "连接服务器超时，将自动重试" : "暂时无法连接服务器，将自动重试"}
                else if case RelayClientError.httpStatus(409)=error {status="设备组正在更新，将自动重试"}
                else {status="配对暂未完成，将自动重试；也可重新生成接入码"}
            }
            if let retained=try? await session.info(),info != retained { info=retained }
        }
    }
    func reload() async {
        guard !busy,let session else { return };busy=true
        _ = await perform({ _ in },using:session)
    }
    func synchronizeSharedText() async {
        guard info.configured,info.clipboard else { await reload();return }
        guard !busy,!savingConsent,let session else { return };busy=true
        while polling {if Task.isCancelled {busy=false;return};try? await Task.sleep(nanoseconds:50_000_000)}
        _ = await perform({ session in
            // Bounded UI catch-up, using the existing small protocol batches.
            // Each pass obtains and rechecks its own current consent lease.
            for _ in 0..<16 {
                try Task.checkCancellation()
                let result = try await session.synchronize()
                if result.received == 0 { break }
            }
        },using:session)
    }
    func sendSharedText(_ text:String) async -> Bool {
        guard !busy,!savingConsent,let session else { return false };busy=true
        while polling {if Task.isCancelled {busy=false;return false};try? await Task.sleep(nanoseconds:50_000_000)}
        return await perform({ try await $0.send(text:text) },using:session)
    }
    func refresh() { run { _ in } }
    /// Wait for any in-flight pass before changing the attempt token. A finish
    /// still in flight must not consume the explicit user's retry.
    @discardableResult func retryAutomaticClipboardRead(preferences:UserDefaults?=nil) -> Bool {
        let preferences=preferences ?? UserDefaults(suiteName:LocalLearningCoordinator.groupID)
        guard !retryingAutomaticClipboardRead,let preferences,
              let scope=preferences.string(forKey:"automatic-clipboard-scope"),
              let generation=preferences.string(forKey:"automatic-clipboard-consent-generation"),
              allowsAutomaticClipboardReadRetry(scope:scope,generation:generation,preferences:preferences) else{return false}
        retryingAutomaticClipboardRead=true
        automaticClipboardReadRetryTask=Task { [weak self] in
            guard let self else{return}
            defer{self.retryingAutomaticClipboardRead=false;self.automaticClipboardReadRetryTask=nil}
            while self.polling || self.busy || self.savingConsent {
                guard !Task.isCancelled,self.allowsAutomaticClipboardReadRetry(scope:scope,generation:generation,preferences:preferences) else{return}
                do{try await Task.sleep(nanoseconds:50_000_000)}catch{return}
            }
            guard !Task.isCancelled,self.allowsAutomaticClipboardReadRetry(scope:scope,generation:generation,preferences:preferences) else{return}
            #if os(iOS)
            ActivityArchiveCapture.shared.resetClipboardObservationAttempts(preferences:preferences)
            #else
            preferences.removeObject(forKey:"automatic-clipboard-read-paused")
            #endif
            self.automaticClipboard.requestReadRetry();self.info.automaticClipboardReadPaused=false
            ClipboardLiveCoordinator.shared.requestReadRetry(preferences:preferences)
            await self.poll()
        }
        return true
    }
    private func allowsAutomaticClipboardReadRetry(scope:String,generation:String,preferences:UserDefaults) -> Bool {
        clipboardActive && info.configured && info.clipboard && info.automaticClipboard &&
        preferences.bool(forKey:"clipboard-sharing-enabled") && preferences.bool(forKey:"automatic-clipboard-enabled") &&
        preferences.string(forKey:"automatic-clipboard-scope")==scope &&
        preferences.string(forKey:"automatic-clipboard-consent-generation")==generation
    }
    func setClipboardSynchronization(_ enabled: Bool) {
        guard !busy, !savingConsent, let session else { return }
        info.clipboard = enabled; info.automaticClipboard = enabled
        automaticClipboard.suspend(); automaticClipboardPreparing = false
        savingConsent = true
        Task {
            defer { savingConsent = false }
            while polling {
                if Task.isCancelled { info = (try? await session.info()) ?? info; return }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            do {
                try await session.setClipboardSynchronization(enabled)
                info = try await session.info(); status = ""
                if enabled, clipboardActive {
                    _ = automaticClipboard.prepare(try await session.automaticClipboardSession())
                    automaticClipboardPreparing = automaticClipboard.initializing
                }
            } catch {
                if let retained = try? await session.info() { info = retained }
                status = "设置未保存，请重试"
            }
        }
    }
    func setAutomaticClipboard(_ enabled:Bool) {
        guard !savingConsent,let session else{return}
        info.automaticClipboard=enabled;automaticClipboard.suspend();automaticClipboardPreparing=false;savingConsent=true
        Task {
            defer{savingConsent=false}
            do {
                try await session.setAutomaticClipboard(enabled);info=try await session.info();status=""
                if enabled,clipboardActive {_ = automaticClipboard.prepare(try await session.automaticClipboardSession());automaticClipboardPreparing=automaticClipboard.initializing}
            }
            catch {if let current=try? await session.info(){info=current};status="设置未保存，请重试"}
        }
    }
    func setCloudLearning(_ enabled: Bool) {
        run { session in
            if enabled { try await session.enableCloudLearningMigration() }
            else { try await session.disableCloudLearningMigration() }
        }
    }
    func consent(learning: Bool, clipboard: Bool) {
        guard !savingConsent, let session else { return }
        // Reflect a toggle immediately; keeping the old binding value while
        // the actor saves can make the native switch snap back.
        info.learning = learning; info.clipboard = clipboard
        if !clipboard {info.automaticClipboard=false;automaticClipboard.suspend();automaticClipboardPreparing=false}
        savingConsent = true
        Task {
            defer { savingConsent = false }
            do { try await session.consent(learning: learning, clipboard: clipboard); info = try await session.info(); status = "" }
            catch {
                if let retained = try? await session.info() { info = retained }
                status = "设置未保存，请重试"
            }
        }
    }
}

