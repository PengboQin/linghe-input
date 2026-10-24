import Foundation
import OSLog

/// Lifecycle/performance metadata only. This is deliberately separate from the
/// opt-in input-decision archive: no text, key, candidate, path or group ID can
/// be supplied. A fixed write budget prevents a diagnostic from becoming an
/// unbounded disk writer itself. It never acquires an interprocess file lock.
enum KeyboardRuntimeDiagnostics {
    enum Phase: String, Codable {
        case loadViewBegin, loadViewEnd, viewLoadBegin, engineCreateBegin, engineCreateEnd, viewLoadEnd
        case viewWillAppear, viewDidAppear, viewWillDisappear, viewDidDisappear
        case nativeStart, nativeResourcesReady, nativeLocalStateReady
        case nativeInitializeBegin, nativeInitializeEnd, nativeSessionBegin, nativeSessionEnd
        case nativeLanguageBegin, nativeLanguageEnd, nativeJournalReady, nativeStartEnd
        case checkpointScheduled, checkpointPreflight, checkpointPreflightEnd
        case checkpointBegin, checkpointEnd, checkpointFailed, checkpointSkipped
        case candidateBatchSlow, nativeBatchSlow, clipboardReadSlow, clipboardWriteSlow, hostContextSlow, checkpointSlow
    }
    enum Metric: String, CaseIterable {
        case ready, elapsedMilliseconds, persistedBytes, skippedWriteBytes
        case nativeImports, nativeResets, completed, skipped, sourceCount
        case owner, nativeSessionCount, failureStage, failureClass, validationReasons
    }
    /// Fixed numeric categories only. Never bridge an NSError description,
    /// pointer, filesystem path, device/group or host identity into metadata.
    enum MaintenanceStage: UInt64 {
        case none = 0, controllerPreflight = 1, hiddenAdmission = 2
        case directoryCreation = 3, nativeSessionAdmission = 4, nativeExport = 5
        case nativeRestore = 6, observationPlan = 7, observationCommit = 8
        case nativeCheckpoint = 9, sharedPublication = 10, sourceValidation = 11
        case lifecycleCancellation = 12
    }
    enum MaintenanceFailure: UInt64 {
        case none = 0, busy = 1, filesystem = 2, exportFailed = 3
        case importFailed = 4, engineUnavailable = 5, invalidData = 6, other = 7
    }
    private static let ownerLock = NSLock()
    private static var nextOwner: UInt64 = 0
    /// Allocated once per controller, independent of the lifecycle writer lock.
    /// This process-local ordinal has no stable identity across process restarts.
    static func allocateOwner() -> UInt64 {
        ownerLock.lock(); defer { ownerLock.unlock() }
        guard nextOwner < 1_000_000_000_000 else { return 0 }
        nextOwner += 1; return nextOwner
    }
    static func maintenanceMetrics(owner: UInt64, stage: MaintenanceStage,
                                   failure: MaintenanceFailure = .none,
                                   nativeSessionCount: UInt64? = nil) -> [Metric: Double] {
        var metrics: [Metric: Double] = [.owner: Double(owner), .failureStage: Double(stage.rawValue),
                                       .failureClass: Double(failure.rawValue)]
        if let nativeSessionCount { metrics[.nativeSessionCount] = Double(nativeSessionCount) }
        return metrics
    }
    static func maintenanceFailurePhase(_ failure: MaintenanceFailure) -> Phase {
        failure == .busy ? .checkpointSkipped : .checkpointFailed
    }
    struct Event: Codable {
        let phase: Phase
        let uptimeMilliseconds: UInt64
        let wallTimeMilliseconds: UInt64?
        let metrics: [String: Double]
    }
    struct Snapshot: Codable {
        let version: Int
        let build: String
        let sequence: UInt64
        let maximumWrites: UInt64
        let events: [Event]
    }
    static let filename = "keyboard-runtime-phase-v1.json"
    static let maximumWrites: UInt64 = 96
    static let maximumFileBytes = 8192
    /// The dedicated leaf contains metadata only. A developer can copy this
    /// file/leaf through CoreDevice without restarting its keyboard host.
    struct MetadataLocation {
        static let relativeDirectory = "Library/Application Support/PrivateInput/Diagnostics/KeyboardRuntime"
        let groupRoot: URL
        var directory: URL { groupRoot.appendingPathComponent(Self.relativeDirectory, isDirectory: true) }
        var file: URL { directory.appendingPathComponent(KeyboardRuntimeDiagnostics.filename) }
        var legacyFile: URL { groupRoot.appendingPathComponent(KeyboardRuntimeDiagnostics.filename) }
        private static func missing(_ error: NSError) -> Bool {
            error.domain == NSCocoaErrorDomain &&
                [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) ||
                error.domain == NSPOSIXErrorDomain && error.code == Int(POSIXErrorCode.ENOENT.rawValue)
        }

        func readValidatedData() throws -> Data {
            let handle: FileHandle
            do { handle = try FileHandle(forReadingFrom: file) }
            catch let error as NSError {
                guard Self.missing(error) else { throw error }
                // FileHandle may label a directory as "no such file". Confirm
                // absence with metadata before authorizing the legacy fallback.
                var absent = false
                do { _ = try FileManager.default.attributesOfItem(atPath: file.path) }
                catch let metadataError as NSError {
                    guard Self.missing(metadataError) else { throw metadataError }
                    absent = true
                }
                guard absent else { throw error }
                // Compatibility is read-only, only when the new file is absent.
                // A present but corrupt/unreadable file must never expose stale
                // data by silently switching to a previous build's root file.
                handle = try FileHandle(forReadingFrom: legacyFile)
            }
            defer { try? handle.close() }
            let data = try handle.read(upToCount: KeyboardRuntimeDiagnostics.maximumFileBytes + 1) ?? Data()
            guard data.count <= KeyboardRuntimeDiagnostics.maximumFileBytes else { throw CocoaError(.fileReadTooLarge) }
            let object = try JSONSerialization.jsonObject(with: data)
            guard let root = object as? [String: Any],
                  Set(root.keys).isSubset(of: ["version", "build", "sequence", "maximumWrites", "events"]),
                  let events = root["events"] as? [[String: Any]], events.allSatisfy({
                      Set($0.keys).isSubset(of: ["phase", "uptimeMilliseconds", "wallTimeMilliseconds", "metrics"])
                  }) else { throw CocoaError(.fileReadCorruptFile) }
            try KeyboardRuntimeDiagnostics.validate(JSONDecoder().decode(Snapshot.self, from: data))
            return data
        }
    }
    /// One instance is owned by the existing writer lock. Directory creation
    /// occurs once after its first success; each accepted event replaces only
    /// the new file, never the old Group-root compatibility file.
    struct MetadataWriter {
        let location: MetadataLocation
        private var directoryPrepared = false
        init(groupRoot: URL) { location = MetadataLocation(groupRoot: groupRoot) }
        mutating func write(_ snapshot: Snapshot) throws {
            try KeyboardRuntimeDiagnostics.validate(snapshot)
            let data = try JSONEncoder().encode(snapshot)
            guard data.count <= KeyboardRuntimeDiagnostics.maximumFileBytes else { throw CocoaError(.fileWriteUnknown) }
            if !directoryPrepared {
                #if os(iOS)
                let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700,
                    .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
                #else
                let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
                #endif
                try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true, attributes: attributes)
                directoryPrepared = true
            }
            #if os(iOS)
            try data.write(to: location.file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: location.file, options: .atomic)
            #endif
        }
    }
    private static func validate(_ snapshot: Snapshot) throws {
        let allowed = Set(Metric.allCases.map(\.rawValue))
        guard snapshot.version == 1, snapshot.maximumWrites == maximumWrites,
              snapshot.sequence <= maximumWrites, snapshot.events.count <= 8,
              snapshot.events.allSatisfy({ event in
                  event.metrics.allSatisfy { allowed.contains($0.key) && $0.value.isFinite && (0...1_000_000_000_000).contains($0.value) }
              }) else { throw CocoaError(.fileReadCorruptFile) }
    }
    struct Buffer {
        private(set) var events: [Event] = []
        private(set) var sequence: UInt64 = 0
        mutating func append(_ phase: Phase, metrics: [Metric: Double], uptimeMilliseconds: UInt64, build: String, wallTimeMilliseconds:UInt64? = nil) -> Snapshot? {
            guard sequence < KeyboardRuntimeDiagnostics.maximumWrites else { return nil }
            // Repeated controller startups must not consume the final outcome
            // of an already-admitted maintenance job (observed on physical92).
            // This reserves writes inside the same96 limit, never extra I/O.
            let terminal = phase == .checkpointEnd || phase == .checkpointFailed || phase == .checkpointSkipped
            guard terminal || sequence < KeyboardRuntimeDiagnostics.maximumWrites - 16 else { return nil }
            sequence += 1
            let values = Dictionary(uniqueKeysWithValues: metrics.compactMap { key, value in
                value.isFinite && value >= 0 ? (key.rawValue, min(value, 1_000_000_000_000)) : nil
            })
            events.append(Event(phase: phase, uptimeMilliseconds: uptimeMilliseconds, wallTimeMilliseconds:wallTimeMilliseconds, metrics: values))
            events = Array(events.suffix(8))
            return Snapshot(version: 1, build: build, sequence: sequence, maximumWrites: KeyboardRuntimeDiagnostics.maximumWrites, events: events)
        }
    }
    private static let lock = NSLock()
    private static var buffer = Buffer()
    private static var metadataWriter: MetadataWriter?
    private static let slowLog=Logger(subsystem:"live.linghe.privateinput.keyboard",category:"slow-operation")
    private static var lastSlowReport:[Phase:Double]=[:]

    /// Slow calls only: numeric clocks plus a fixed operation name. No file,
    /// network, raw input, candidate, document or app identifier is accepted.
    /// OSLog avoids adding another synchronous writer to a stalled UI path.
    static func recordSlow(_ phase:Phase,startedUptime:TimeInterval) {
        let now=ProcessInfo.processInfo.systemUptime,elapsed=(now-startedUptime)*1000
        guard elapsed.isFinite,elapsed>=32 else{return}
        // Diagnostics may be dropped; never wait for the lifecycle writer.
        guard lock.try() else{return}
        let allowed=lastSlowReport[phase].map{now-$0>=5} ?? true
        if allowed {lastSlowReport[phase]=now}
        lock.unlock()
        guard allowed else{return}
        let wall=Date().timeIntervalSince1970*1000
        slowLog.notice("operation=\(phase.rawValue,privacy:.public) elapsed_ms=\(elapsed,privacy:.public) uptime_ms=\(now*1000,privacy:.public) wall_ms=\(wall,privacy:.public)")
    }
    static func record(_ phase: Phase, _ metrics: [Metric: Double] = [:]) {
        #if os(iOS)
        guard Bundle.main.bundleURL.pathExtension == "appex",
              let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.live.linghe.privateinput") else { return }
        lock.lock()
        guard let snapshot = buffer.append(phase, metrics: metrics, uptimeMilliseconds: UInt64(ProcessInfo.processInfo.systemUptime * 1000),
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            wallTimeMilliseconds:UInt64(max(0,Date().timeIntervalSince1970*1000))) else { lock.unlock(); return }
        // Synchronous atomic metadata publication avoids a queued writer starting
        // only after the extension has disappeared. No flock or SQLite handle.
        // Failure (including no full access) must never disable offline typing.
        defer { lock.unlock() }
        if metadataWriter == nil { metadataWriter = MetadataWriter(groupRoot: directory) }
        try? metadataWriter?.write(snapshot)
        #endif
    }

    /// Explicit containing-app diagnostics export. No private keyboard database
    /// access, network transfer, original mutation or new permission request.
    static func exportToContainingApp() throws {
        #if os(iOS)
        guard Bundle.main.bundleURL.pathExtension != "appex",
              let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.live.linghe.privateinput") else { return }
        let data = try MetadataLocation(groupRoot: directory).readValidatedData()
        let output = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PrivateInput/Diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: output.appendingPathComponent(filename), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #endif
    }
}
