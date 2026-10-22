import Foundation
import CryptoKit
import Security
import PrivateInputKit
#if os(iOS)
import UIKit
#else
import AppKit
import Carbon
#endif

/// Public pairing proof only; no root/exchange/storage/delegate private keys.
struct ActivityArchiveConnection: Codable {
    let relayEndpoint: URL
    let group: UUID
    let device: UUID
    let anchor: MembershipAnchor
    var membership: SignedMembership
    let personalEpoch: String
    func verified() throws -> VerifiedMembership {
        guard group == anchor.group, group == membership.group,
              personalEpoch == PersonalDataReset.generation else { throw ActivityError.staleAuthorization }
        let checked = try anchor.verify(membership)
        _ = try checked.member(device)
        return checked
    }
}
struct ActivityArchiveLiveConnection {
    let publicConnection: ActivityArchiveConnection
    let identity: DeviceIdentity
}

enum ActivityArchiveLocation {
    static var directory: URL? { PersonalLexiconLocation.directory?.appendingPathComponent("ActivityArchive", isDirectory: true) }
    static var descriptor: URL? { directory?.appendingPathComponent("connection-v1.json") }
    static func queue(_ connection: ActivityArchiveConnection) throws -> ActivityLocalEventQueue {
        guard let root = directory else { throw ActivityError.storageFailure }
        let folder = root.appendingPathComponent(connection.group.uuidString).appendingPathComponent(connection.device.uuidString)
        return try ActivityLocalEventQueue(file: folder.appendingPathComponent("events.sqlite"), group: connection.group, device: connection.device)
    }
    static func load() throws -> ActivityArchiveConnection {
        guard let file = descriptor else { throw ActivityError.storageFailure }
        let data = try Data(contentsOf: file)
        guard data.count <= 2 * 1024 * 1024 else { throw ActivityError.invalidConfiguration }
        let value = try JSONDecoder().decode(ActivityArchiveConnection.self, from: data)
        _ = try value.verified(); return value
    }
    static func publish(_ connection: ActivityArchiveConnection) throws {
        _ = try connection.verified()
        guard let file = descriptor else { throw ActivityError.storageFailure }
        if let old = try? load(), old.group == connection.group {
            _ = try old.anchor.verify(connection.membership, replacing: old.verified())
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(connection).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    static func purgeForConfirmedDeparture(root: URL) throws {
        ActivityArchiveCapture.shared.stop()
        let activity = root.appendingPathComponent("ActivityArchive", isDirectory: true)
        guard FileManager.default.fileExists(atPath: activity.path) else { return }
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey]
        guard try activity.resourceValues(forKeys: keys).isSymbolicLink != true else { throw ActivityError.storageFailure }
        for groupFolder in try FileManager.default.contentsOfDirectory(at: activity, includingPropertiesForKeys: Array(keys)) {
            guard UUID(uuidString: groupFolder.lastPathComponent) != nil else { continue }
            guard try groupFolder.resourceValues(forKeys: keys).isSymbolicLink != true else { throw ActivityError.storageFailure }
            for deviceFolder in try FileManager.default.contentsOfDirectory(at: groupFolder, includingPropertiesForKeys: Array(keys)) {
                guard let group = UUID(uuidString: groupFolder.lastPathComponent), let device = UUID(uuidString: deviceFolder.lastPathComponent),
                      try deviceFolder.resourceValues(forKeys: keys).isSymbolicLink != true else { throw ActivityError.storageFailure }
                let file = deviceFolder.appendingPathComponent("events.sqlite")
                if FileManager.default.fileExists(atPath: file.path) {
                    let q = try ActivityLocalEventQueue(file: file, group: group, device: device)
                    try q.purgeForConfirmedDeparture()
                }
            }
        }
        let file = activity.appendingPathComponent("connection-v1.json")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        try ActivityArchiveDelegateKeys.removeAllForConfirmedDeparture()
    }
}

/// Least-privileged extension key in the EXISTING shared Keychain group.
/// Main registers its public key; the server permits status/ingest only.
enum ActivityArchiveDelegateKeys {
    private static let service = "live.linghe.privateinput.activity-delegate.v1"
    private static func query(connection: ActivityArchiveConnection? = nil) throws -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrSynchronizable as String: false]
        if let connection { query[kSecAttrAccount as String] = connection.group.uuidString + ":" + connection.device.uuidString }
        #if os(iOS)
        guard let group = Bundle.main.object(forInfoDictionaryKey: "PrivateInputSharedKeychainGroup") as? String,
              !group.isEmpty, !group.contains("$(") else { throw IdentityStoreError.corrupt }
        query[kSecAttrAccessGroup as String] = group
        #endif
        return query
    }
    static func load(connection: ActivityArchiveConnection, create: Bool = false) throws -> ActivityRequestSigner {
        var search = try query(connection: connection)
        search[kSecReturnData as String] = true; search[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let result = SecItemCopyMatching(search as CFDictionary, &item)
        if result == errSecSuccess {
            guard let bytes = item as? Data, bytes.count == 32 else { throw IdentityStoreError.corrupt }
            return ActivityRequestSigner(device: connection.device, signingKey: try .init(rawRepresentation: bytes))
        }
        guard result == errSecItemNotFound, create else { throw IdentityStoreError.osStatus(result) }
        let key = Curve25519.Signing.PrivateKey()
        var insert = try query(connection: connection)
        insert[kSecValueData as String] = key.rawRepresentation
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let saved = SecItemAdd(insert as CFDictionary, nil)
        if saved == errSecDuplicateItem { return try load(connection: connection) }
        guard saved == errSecSuccess else { throw IdentityStoreError.osStatus(saved) }
        return ActivityRequestSigner(device: connection.device, signingKey: key)
    }
    static func removeAllForConfirmedDeparture() throws {
        let result = SecItemDelete(try query() as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw IdentityStoreError.osStatus(result) }
    }
}

/// Memory-only entry points on the host callback. All disk/network work is dispatched.
final class ActivityArchiveCapture: @unchecked Sendable {
    static let shared = ActivityArchiveCapture()
    private struct Context { let connection: ActivityArchiveConnection; let queue: ActivityLocalEventQueue; let lease: ActivityAuthorizationLease }
    struct DiagnosticScope: Equatable {
        fileprivate let group: UUID, device: UUID, lease: UUID
        fileprivate let personalEpoch: String
    }
    private func diagnosticScope(_ context: Context) -> DiagnosticScope {
        .init(group: context.connection.group, device: context.connection.device, lease: context.lease.generation, personalEpoch: context.connection.personalEpoch)
    }
    /// In-memory permission check only; existing output authorization does not
    /// authorize process diagnostics. A scope never contains a private key.
    var diagnosticScope: DiagnosticScope? {
        lock.lock(); defer { lock.unlock() }
        guard permission, let context, context.lease.configuration.providers.contains(ActivityInputDiagnostic.provider) else { return nil }
        return diagnosticScope(context)
    }
    private let lock = NSLock()
    private let io = DispatchQueue(label: "live.linghe.privateinput.activity", qos: .utility)
    private var context: Context?
    private var permission = false
    private var permissionGeneration = UUID()
    private var lastRefresh = Date.distantPast
    private var lastUpload = Date.distantPast
    private var uploading = false
    private var uploadTask: Task<Void, Never>?
    private(set) var diagnostic: String = ""
    private let observationSession = UUID().uuidString
    private var clipboardVersion: Int?
    private var clipboardAttemptedVersion: Int?
    private var syncClipboard: (version: Int, event: UUID, sender: UUID)?
    private var sourceNames: [String: String] = [:]
    #if PRIVATE_INPUT_TESTING
    /// Compiled only by the isolated adapter executable, never product builds.
    /// A real signed synthetic connection/SQLite queue is used; networking is
    /// kept disabled and no real singleton, Keychain or preferences are touched.
    func installIsolatedTestContext(connection: ActivityArchiveConnection, queue: ActivityLocalEventQueue, lease: ActivityAuthorizationLease) throws {
        _ = try connection.verified()
        lock.lock(); defer { lock.unlock() }
        permission = true; context = Context(connection: connection, queue: queue, lease: lease); uploading = true
    }
    func drainIsolatedTestIO() { io.sync { } }
    #endif

    func stop() {
        lock.lock(); permission = false; permissionGeneration = UUID(); context = nil; sourceNames.removeAll()
        let task = uploadTask; uploadTask = nil; lock.unlock(); task?.cancel()
    }
    /// Hiding a keyboard ends its network lifetime, not consent for events which
    /// were already observed and are waiting for their local SQLite transaction.
    func suspendNetwork() { lock.lock(); let task = uploadTask; lock.unlock(); task?.cancel() }
    func refresh(permitted: Bool, force: Bool = false) {
        guard permitted else { stop(); return }
        lock.lock()
        permission = true
        let generation = permissionGeneration
        let due = force || Date().timeIntervalSince(lastRefresh) > 2
        if due { lastRefresh = Date() }
        lock.unlock()
        guard due else { return }
        io.async { [weak self] in
            guard let self, self.isPermitted(generation) else { return }
            do {
                let connection = try ActivityArchiveLocation.load(), q = try ActivityArchiveLocation.queue(connection)
                let lease = try q.authorizationLease()
                self.lock.lock()
                if self.permission && self.permissionGeneration == generation { self.context = Context(connection: connection, queue: q, lease: lease) }
                self.lock.unlock()
                if try q.status().pending > 0 { self.scheduleUpload() }
            } catch { self.lock.lock(); self.context = nil; self.lock.unlock() }
        }
    }
    func permits(_ provider: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return permission && context?.lease.configuration.providers.contains(provider) == true
    }
    func capture(_ draft: ActivityEventDraft, safety: ActivityFieldSafety, diagnosticScope expectedScope: DiagnosticScope? = nil, completion: ((UUID?) -> Void)? = nil) {
        lock.lock()
        let sameScope = expectedScope == nil || context.map { diagnosticScope($0) == expectedScope } == true
        let snapshot = permission && sameScope ? context : nil; let generation = permissionGeneration; lock.unlock()
        guard let snapshot, snapshot.lease.configuration.providers.contains(draft.providerID) else { completion?(nil); return }
        var draft = draft
        if draft.extensions == nil { draft.extensions = [:] }
        draft.extensions?[ActivityDeviceDescription.extensionKey] = .object(ActivityDeviceDescription.fields)
        io.async { [weak self] in
            guard let self, self.isPermitted(generation, diagnosticScope: expectedScope), snapshot.connection.personalEpoch == PersonalDataReset.generation else {
                if let completion { DispatchQueue.main.async { completion(nil) } }; return
            }
            var eventID: UUID?
            do { eventID = try snapshot.queue.capture(draft, safety: safety, lease: snapshot.lease).eventID; self.scheduleUpload() }
            catch ActivityError.alreadyObserved { }
            catch { self.report(error) }
            if let completion { let result = eventID; DispatchQueue.main.async { completion(result) } }
        }
    }
    func recordDiagnostic(action: String, key: String, before: String, after: String, candidates: [String] = [],
                          sourceApp: String?, document: String?, session: String, epoch: String,
                          safety: ActivityFieldSafety, decision: ActivityInputDecisionDiagnostic? = nil, diagnosticScope: DiagnosticScope? = nil) {
        guard permits(ActivityInputDiagnostic.provider), safety == .safe,
              let diagnostic = ActivityInputDiagnostic(action: action, key: key, before: before, after: after, candidates: candidates) else { return }
        var extras = sourceContextExtensions(sourceApp: sourceApp)
        extras[ActivityInputDiagnostic.extensionKey] = .object(diagnostic.fields)
        if let decision { extras[ActivityInputDecisionDiagnostic.extensionKey] = decision.extensionValue }
        capture(ActivityEventDraft(providerID: ActivityInputDiagnostic.provider, eventType: .sourceImport, text: diagnostic.text,
            inputSession: session, editorEpoch: epoch, sourceKind: "ime_diagnostic", sourceApp: sourceApp,
            documentID: document, commitConfirmation: .notApplicable, extensions: extras), safety: safety, diagnosticScope: diagnosticScope)
    }
    func recordDecision(_ value: ActivityInputDecisionDiagnostic, scope: DiagnosticScope, document: String?, session: String, epoch: String) {
        guard permits(ActivityInputDiagnostic.provider) else { return }
        capture(ActivityEventDraft(providerID: ActivityInputDiagnostic.provider, eventType: .sourceImport, text: "",
            inputSession: session, editorEpoch: epoch, sourceKind: "ime_diagnostic", documentID: document,
            commitConfirmation: .notApplicable, extensions: [ActivityInputDecisionDiagnostic.extensionKey: value.extensionValue]),
            safety: .safe, diagnosticScope: scope)
    }
    func recordInput(_ text: String, sourceApp: String?, document: String?, session: String, epoch: String,
                     safety: ActivityFieldSafety, pasteEvent: UUID? = nil, pasteSender: UUID? = nil,
                     sourceContext: ActivitySourceContext? = nil, decisionLink: [String: String]? = nil,
                     diagnosticScope: DiagnosticScope? = nil, completion: ((UUID?) -> Void)? = nil) {
        guard !text.isEmpty, permits(pasteEvent == nil ? "ime.commit.v1" : "ime.paste.v1") else { completion?(nil); return }
        var links: [ActivityJSONValue] = []
        if let pasteEvent {
            var link: [String: ActivityJSONValue] = ["event_id": .string(pasteEvent.uuidString), "relation": .string("explicit_shared_text_paste")]
            if let pasteSender { link["device_id"] = .string(pasteSender.uuidString) }
            links = [.object(link)]
        }
        var extras = sourceContextExtensions(sourceApp: sourceApp, supplied: sourceContext)
        if let decisionLink, !decisionLink.isEmpty, diagnosticScope != nil, diagnosticScope == self.diagnosticScope {
            extras["org.linghe.decision-link.v1"] = .object(decisionLink.mapValues(ActivityJSONValue.string))
        }
        capture(ActivityEventDraft(providerID: pasteEvent == nil ? "ime.commit.v1" : "ime.paste.v1",
                                   eventType: pasteEvent == nil ? .inputCommit : .pasteAction, text: text,
                                   inputSession: session, editorEpoch: epoch, spanID: UUID().uuidString,
                                   editOperation: .object(["kind": .string("unknown")]), sourceKind: pasteEvent == nil ? "ime" : "shared_text",
                                   sourceApp: sourceApp, documentID: document, commitConfirmation: .insertRequested,
                                   links: links, extensions: extras), safety: safety, completion: completion)
    }
    func recordSystemPaste(_ text: String, sourceApp: String?, document: String?, session: String, epoch: String,
                           safety: ActivityFieldSafety, sourceContext: ActivitySourceContext? = nil) {
        guard !text.isEmpty, permits("ime.paste.v1") else { return }
        capture(ActivityEventDraft(providerID: "ime.paste.v1", eventType: .pasteAction, text: text,
            inputSession: session, editorEpoch: epoch, spanID: UUID().uuidString,
            editOperation: .object(["kind": .string("unknown")]), sourceKind: "system_clipboard",
            sourceApp: sourceApp, documentID: document, commitConfirmation: .insertRequested,
            links: [], extensions: sourceContextExtensions(sourceApp: sourceApp, supplied: sourceContext)), safety: safety)
    }
    private func sourceContextExtensions(sourceApp: String?, supplied: ActivitySourceContext? = nil) -> [String: ActivityJSONValue] {
        let context: ActivitySourceContext
        if let supplied { context = supplied }
        else {
            #if os(iOS)
            let platform = "ios"
            let name: String? = nil
            let component = Bundle.main.bundleURL.pathExtension == "appex" ? "keyboard_extension" : "app"
            #else
            let platform = "macos"
            let name = sourceApp.flatMap { sourceDisplayName($0) }
            let component = "input_method"
            #endif
            context = ActivitySourceContext(platform: platform, sourceAppID: sourceApp, sourceAppName: name,
                inputMethodVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                inputMethodBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                captureComponent: component)
        }
        return [ActivitySourceContext.extensionKey: .object(context.fields.mapValues(ActivityJSONValue.string)),
                ActivityDeviceDescription.extensionKey: .object(ActivityDeviceDescription.fields)]
    }
    #if os(macOS)
    private func sourceDisplayName(_ identifier: String) -> String? {
        lock.lock(); let cached = sourceNames[identifier]; lock.unlock()
        if let cached { return cached }
        let name = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first?.localizedName
        if let name {
            lock.lock()
            if permission {
                if sourceNames.count >= 64 { sourceNames.removeAll() }
                sourceNames[identifier] = name
            }
            lock.unlock()
        }
        return name
    }
    #endif
    func recordHostPassthroughGap(sourceApp: String?, session: String) {
        guard permits("ime.commit.v1") else { return }
        capture(ActivityEventDraft(providerID: "ime.commit.v1", eventType: .coverageGap, text: "",
                                   inputSession: session, editorEpoch: UUID().uuidString, sourceKind: "ime",
                                   sourceApp: sourceApp, commitConfirmation: .notApplicable,
                                   extensions: sourceContextExtensions(sourceApp: sourceApp).merging(["org.linghe.coverage.v1": .object(["reason": .string("host_passthrough_unobservable")])], uniquingKeysWith: { _, newer in newer })), safety: .safe)
    }
    func noteSyncedClipboardWrite(version: Int, event: UUID, sender: UUID) {
        lock.lock(); syncClipboard = (version, event, sender); lock.unlock()
    }
    /// Explicit user enable/save/retry actions only; a background refresh must
    /// never clear a paused OS read and repeat the permission prompt.
    func resetClipboardObservationAttempts(preferences:UserDefaults?=nil) {
        clipboardAttemptedVersion = nil
        #if os(iOS)
        (preferences ?? UserDefaults(suiteName:LocalLearningCoordinator.groupID))?.removeObject(forKey:"automatic-clipboard-read-paused")
        #endif
    }
    /// Main/keyboard callers invoke this ONLY while active/visible and permitted by the OS.
    /// Never makes a clipboard write, guesses an external paste, or promises every copy.
    func observeClipboardIfPermitted(active:Bool=true) {
        guard active,permits("clipboard.observed.v1") else { return }
        #if os(iOS)
        let preferences=UserDefaults(suiteName:LocalLearningCoordinator.groupID)
        guard preferences?.bool(forKey:"automatic-clipboard-read-paused") != true else{return}
        let board = UIPasteboard.general, version = board.changeCount
        guard clipboardVersion != version, clipboardAttemptedVersion != version else { return }
        clipboardAttemptedVersion = version
        let hasStrings=board.hasStrings
        guard hasStrings else{return}
        guard let text=board.string else {
            let hasStringsAfter=board.hasStrings,versionAfter=board.changeCount
            if ClipboardReadPausePolicy.shouldPause(textIsNil:true,hasStringsBefore:hasStrings,versionBefore:version,versionAfter:versionAfter,hasStringsAfter:hasStringsAfter) {
                preferences?.set(true,forKey:"automatic-clipboard-read-paused")
                ClipboardCacheCoordinator.recordMarkerReadPause(source:"archive-observer",version:version,hasStrings:hasStringsAfter)
            }
            return
        }
        guard board.changeCount == version else { return }
        #else
        guard !IsSecureEventInputEnabled() else { return }
        let board = NSPasteboard.general, version = board.changeCount
        guard clipboardVersion != version, clipboardAttemptedVersion != version else { return }
        clipboardAttemptedVersion = version
        let excluded = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"]
        guard !(board.types ?? []).contains(where: { excluded.contains($0.rawValue) }), let text = board.string(forType: .string) else { return }
        guard board.changeCount == version else { return }
        #endif
        clipboardVersion = version
        lock.lock(); let origin = syncClipboard; lock.unlock()
        var links: [ActivityJSONValue] = [], extra: [String: ActivityJSONValue]?
        if let origin, origin.version == version {
            links = [.object(["event_id": .string(origin.event.uuidString), "device_id": .string(origin.sender.uuidString), "relation": .string("sync_received")])]
            extra = ["org.linghe.clipboard.v1": .object(["origin": .string("sync_received")])]
        }
        // The frontmost app at observation time is not proof of who copied.
        extra = sourceContextExtensions(sourceApp: nil).merging(extra ?? [:], uniquingKeysWith: { _, newer in newer })
        capture(ActivityEventDraft(providerID: "clipboard.observed.v1", eventType: .clipboardObserved, text: text,
                                   sourceKind: "clipboard", commitConfirmation: .notApplicable, links: links,
                                   extensions: extra, observationID: observationSession + ":" + String(version)), safety: .safe)
    }
    private func isPermitted(_ generation: UUID, diagnosticScope expectedScope: DiagnosticScope? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return permission && permissionGeneration == generation && (expectedScope == nil || context.map { diagnosticScope($0) == expectedScope } == true)
    }
    private func report(_ error: Error) {
        let code: String
        switch error { case ActivityError.quotaExceeded: code = "local_quota"; case ActivityError.staleAuthorization, ActivityError.disabled: code = "paused"; default: code = "archive_unavailable" }
        lock.lock(); diagnostic = code; lock.unlock()
    }
    private func scheduleUpload() {
        lock.lock()
        guard permission, let snapshot = context, !uploading, Date().timeIntervalSince(lastUpload) >= 2 else { lock.unlock(); return }
        uploading = true; lastUpload = Date()
        let generation = permissionGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.finishUpload() }
            do {
                guard self.isPermitted(generation), let endpoint = snapshot.lease.configuration.endpoint else { return }
                let signer = try ActivityArchiveDelegateKeys.load(connection: snapshot.connection)
                let local = try snapshot.connection.verified()
                let now = UInt64(Date().timeIntervalSince1970)
                // Delegate keys cannot authenticate the old relay. The containing app
                // refreshes this public proof. The worker requires the archive's CURRENT
                // membership revision to agree, instead of trusting a server-only role change.
                let client = try ActivityArchiveClient(endpoint: endpoint)
                let worker = ActivityArchiveWorker(queue: snapshot.queue, client: client)
                _ = try await worker.flush(signer: signer, membershipRevision: local.statement.revision, now: now)
            } catch { self.report(error) }
        }
        uploadTask = task; lock.unlock()
    }
    private func finishUpload() { lock.lock(); uploading = false; uploadTask = nil; lock.unlock() }
}
