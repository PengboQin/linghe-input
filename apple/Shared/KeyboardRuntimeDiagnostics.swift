import Foundation

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
    }
    enum Metric: String {
        case ready, elapsedMilliseconds, persistedBytes, skippedWriteBytes
        case nativeImports, nativeResets, completed, skipped, sourceCount
    }
    struct Event: Codable {
        let phase: Phase
        let uptimeMilliseconds: UInt64
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
    struct Buffer {
        private(set) var events: [Event] = []
        private(set) var sequence: UInt64 = 0
        mutating func append(_ phase: Phase, metrics: [Metric: Double], uptimeMilliseconds: UInt64, build: String) -> Snapshot? {
            guard sequence < KeyboardRuntimeDiagnostics.maximumWrites else { return nil }
            sequence += 1
            let values = Dictionary(uniqueKeysWithValues: metrics.compactMap { key, value in
                value.isFinite && value >= 0 ? (key.rawValue, min(value, 1_000_000_000_000)) : nil
            })
            events.append(Event(phase: phase, uptimeMilliseconds: uptimeMilliseconds, metrics: values))
            events = Array(events.suffix(8))
            return Snapshot(version: 1, build: build, sequence: sequence, maximumWrites: KeyboardRuntimeDiagnostics.maximumWrites, events: events)
        }
    }
    private static let lock = NSLock()
    private static var buffer = Buffer()

    static func record(_ phase: Phase, _ metrics: [Metric: Double] = [:]) {
        #if os(iOS)
        guard Bundle.main.bundleURL.pathExtension == "appex",
              let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.live.linghe.privateinput") else { return }
        lock.lock()
        guard let snapshot = buffer.append(phase, metrics: metrics, uptimeMilliseconds: UInt64(ProcessInfo.processInfo.systemUptime * 1000),
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown") else { lock.unlock(); return }
        // Synchronous atomic metadata publication avoids a queued writer starting
        // only after the extension has disappeared. No flock or SQLite handle.
        // Failure (including no full access) must never disable offline typing.
        defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(snapshot), data.count <= 8192 else { return }
        try? data.write(to: directory.appendingPathComponent(filename), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #endif
    }

    /// Explicit containing-app diagnostics export. No private keyboard database
    /// access, network transfer, original mutation or new permission request.
    static func exportToContainingApp() throws {
        #if os(iOS)
        guard Bundle.main.bundleURL.pathExtension != "appex",
              let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.live.linghe.privateinput") else { return }
        let file = directory.appendingPathComponent(filename)
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        let data = try handle.read(upToCount: 8193) ?? Data()
        guard data.count <= 8192 else { throw CocoaError(.fileReadTooLarge) }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        guard snapshot.version == 1, snapshot.events.count <= 8, snapshot.sequence <= maximumWrites else { throw CocoaError(.fileReadCorruptFile) }
        let output = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PrivateInput/Diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: output.appendingPathComponent(filename), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #endif
    }
}
