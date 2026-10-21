import Foundation
import CSQLite
import Darwin

public struct ActivityQueueStatus: Equatable {
    public let pending: Int
    public let held: Int
    public let acknowledged: Int
    public let payloadBytes: Int
    public let installationID: UUID
    public let lastSequence: UInt64
}
public struct ActivityAuthorizationLease: Equatable {
    public let generation: UUID
    public let configuration: ActivityConfiguration
}
public struct ActivityBatch: Codable {
    public let batchID: UUID
    public let events: [ActivityEvent]
    enum CodingKeys: String, CodingKey { case batchID = "batch_id", events }
    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(self)
        guard bytes.count <= 524288 else { throw ActivityError.eventTooLarge }; return bytes
    }
}

/// Synchronous local transactions only. Providers dispatch capture onto their own serial
/// background queue; keyboard insertion must never wait for disk or a network call.
/// SQLite serializes app/extension processes. A durable generation also fences old workers
/// and queued rows after disable, pause, provider, endpoint or consent changes.
public final class ActivityLocalEventQueue: @unchecked Sendable {
    public let group: UUID
    public let device: UUID
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(file: URL, group: UUID, device: UUID) throws {
        self.group = group; self.device = device
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // macOS's /var is itself a system symlink. Resolve the containing directory,
        // while keeping the actual database leaf protected by SQLITE_OPEN_NOFOLLOW.
        guard let resolved = realpath(file.deletingLastPathComponent().path, nil) else { throw ActivityError.storageFailure }
        let canonicalFile = URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent(file.lastPathComponent)
        free(resolved)
        guard sqlite3_open_v2(canonicalFile.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; db = nil; throw ActivityError.storageFailure
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: canonicalFile.path)
            sqlite3_busy_timeout(db, 1500)
            try execute("PRAGMA journal_mode=WAL; PRAGMA secure_delete=ON; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; PRAGMA journal_size_limit=65536; PRAGMA wal_autocheckpoint=64;")
            try execute("CREATE TABLE IF NOT EXISTS activity_meta (key TEXT PRIMARY KEY, value BLOB NOT NULL); CREATE TABLE IF NOT EXISTS activity_events (event_id TEXT PRIMARY KEY, seq INTEGER NOT NULL UNIQUE, provider TEXT NOT NULL, observation TEXT, generation TEXT NOT NULL, payload BLOB NOT NULL, state INTEGER NOT NULL DEFAULT 0, batch_id TEXT, attempts INTEGER NOT NULL DEFAULT 0, next_attempt INTEGER NOT NULL DEFAULT 0, ack_at INTEGER); CREATE UNIQUE INDEX IF NOT EXISTS activity_observation ON activity_events(provider,observation) WHERE observation IS NOT NULL; CREATE INDEX IF NOT EXISTS activity_pending ON activity_events(state,generation,next_attempt,seq); CREATE TABLE IF NOT EXISTS activity_observations(provider TEXT NOT NULL,observation TEXT NOT NULL,event_id TEXT NOT NULL,PRIMARY KEY(provider,observation));")
            try transaction {
                if try metadata("group") == nil {
                    try setMetadata("group", Data(group.uuidString.utf8)); try setMetadata("device", Data(device.uuidString.utf8))
                    try setMetadata("installation", Data(UUID().uuidString.utf8)); try setMetadata("sequence", Data("0".utf8))
                    try setMetadata("generation", Data(UUID().uuidString.utf8))
                    try setMetadata("configuration", JSONEncoder().encode(ActivityConfiguration()))
                }
                guard try textMetadata("group") == group.uuidString, try textMetadata("device") == device.uuidString,
                      try UUID(uuidString: textMetadata("installation")) != nil,
                      try UUID(uuidString: textMetadata("generation")) != nil else { throw ActivityError.storageFailure }
            }
            try capDatabase(try configuration().maxQueueBytes)
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }

    public func configuration() throws -> ActivityConfiguration {
        lock.lock(); defer { lock.unlock() }
        guard let data = try metadata("configuration") else { throw ActivityError.storageFailure }
        guard data.count <= 65536 else { throw ActivityError.invalidConfiguration }
        let configuration = try JSONDecoder().decode(ActivityConfiguration.self, from: data)
        try configuration.validate(); return configuration
    }
    /// Does not destroy old records. They become held and cannot silently upload on re-enable.
    @discardableResult public func configure(_ configuration: ActivityConfiguration) throws -> ActivityAuthorizationLease {
        try configuration.validate()
        lock.lock(); defer { lock.unlock() }
        let result = try transaction {
            if try self.configuration() != configuration {
                try execute("UPDATE activity_events SET state=1,batch_id=NULL WHERE state=0")
                try setMetadata("configuration", JSONEncoder().encode(configuration))
                try setMetadata("generation", Data(UUID().uuidString.utf8))
            }
            return try authorizationLease(requireEnabled: false)
        }
        try capDatabase(configuration.maxQueueBytes)
        return result
    }
    /// Use on membership removal/reset even if the visible preferences have not changed.
    public func invalidateAuthorization() throws {
        lock.lock(); defer { lock.unlock() }
        try transaction {
            var value = try configuration(); value.enabled = false; value.consentVersion = 0
            try execute("UPDATE activity_events SET state=1,batch_id=NULL WHERE state=0")
            try setMetadata("configuration", JSONEncoder().encode(value))
            try setMetadata("generation", Data(UUID().uuidString.utf8))
        }
    }
    public func authorizationLease(requireEnabled: Bool = true) throws -> ActivityAuthorizationLease {
        lock.lock(); defer { lock.unlock() }
        let config = try configuration()
        if requireEnabled && !config.collecting { throw ActivityError.disabled }
        guard let generation = try UUID(uuidString: textMetadata("generation")) else { throw ActivityError.storageFailure }
        return ActivityAuthorizationLease(generation: generation, configuration: config)
    }
    public func validate(_ lease: ActivityAuthorizationLease) throws {
        guard try authorizationLease() == lease else { throw ActivityError.staleAuthorization }
    }
    /// Returns existing event for the same source observation; identical text with a NEW
    /// observation is a separate event. No pending composition/keystroke API exists here.
    @discardableResult public func capture(_ draft: ActivityEventDraft, safety: ActivityFieldSafety, lease: ActivityAuthorizationLease) throws -> ActivityEvent {
        guard case .safe = safety else { throw ActivityError.unsafeField }
        lock.lock(); defer { lock.unlock() }
        return try transaction {
            try validate(lease)
            let config = lease.configuration
            guard config.providers.contains(draft.providerID) else { throw ActivityError.providerDisabled }
            if let app = draft.sourceApp, config.excludedSourceApps.contains(app) { throw ActivityError.excludedSource }
            if let observation = draft.observationID {
                guard !observation.isEmpty, observation.utf8.count <= 1024 else { throw ActivityError.invalidEvent }
                if let data = try firstBlob("SELECT payload FROM activity_events WHERE provider=? AND observation=?", [.text(draft.providerID), .text(observation)]) {
                    let original = try JSONDecoder().decode(ActivityEvent.self, from: data)
                    guard original.content.text == draft.text, original.eventType == draft.eventType else { throw ActivityError.invalidEvent }
                    return original
                }
                var seen = false, markers = 0
                try rows("SELECT 1 FROM activity_observations WHERE provider=? AND observation=?", [.text(draft.providerID), .text(observation)]) { _ in seen = true }
                if seen { throw ActivityError.alreadyObserved }
                try rows("SELECT COUNT(*) FROM activity_observations", []) { markers = Int(sqlite3_column_int64($0, 0)) }
                guard markers < 100000 else { throw ActivityError.quotaExceeded }
            }
            guard let previous = try UInt64(textMetadata("sequence")), previous < UInt64(Int64.max),
                  let installation = try UUID(uuidString: textMetadata("installation")) else { throw ActivityError.sequenceExhausted }
            let event = try ActivityEvent(draft: draft, group: group, device: device, installation: installation, sequence: previous + 1, consent: config.consentVersion)
            let bytes = try event.encoded()
            let status = try self.status()
            guard status.pending + status.held + status.acknowledged < config.maxQueueEvents,
                  status.payloadBytes <= config.maxQueueBytes - bytes.count else { throw ActivityError.quotaExceeded }
            try run("INSERT INTO activity_events(event_id,seq,provider,observation,generation,payload) VALUES(?,?,?,?,?,?)", [
                .text(event.eventID.uuidString), .int(Int64(event.deviceSeq)), .text(event.providerID),
                draft.observationID.map(Binding.text) ?? .null, .text(lease.generation.uuidString), .data(bytes)])
            if let observation = draft.observationID {
                try run("INSERT INTO activity_observations(provider,observation,event_id) VALUES(?,?,?)", [.text(draft.providerID), .text(observation), .text(event.eventID.uuidString)])
            }
            try setMetadata("sequence", Data(String(event.deviceSeq).utf8))
            return event
        }
    }
    /// Stable batch IDs survive timeout/process restarts. Reuse a due batch before making another.
    public func nextBatch(lease: ActivityAuthorizationLease, now: UInt64, limit: Int = 64) throws -> ActivityBatch? {
        lock.lock(); defer { lock.unlock() }
        return try transaction {
            try validate(lease)
            var batchID: UUID?
            try rows("SELECT batch_id FROM activity_events WHERE state=0 AND generation=? AND batch_id IS NOT NULL ORDER BY seq LIMIT 1", [.text(lease.generation.uuidString)]) { stmt in
                batchID = UUID(uuidString: self.string(stmt, 0))
            }
            var events: [ActivityEvent] = [], totalBytes = 0
            let sql: String, parameters: [Binding]
            if let batchID {
                // Every row belongs to the immutable original batch. Do not retry only a subset.
                sql = "SELECT payload,next_attempt FROM activity_events WHERE state=0 AND generation=? AND batch_id=? ORDER BY seq"
                parameters = [.text(lease.generation.uuidString), .text(batchID.uuidString)]
            } else {
                sql = "SELECT payload,next_attempt FROM activity_events WHERE state=0 AND generation=? AND batch_id IS NULL AND next_attempt<=? ORDER BY seq LIMIT ?"
                parameters = [.text(lease.generation.uuidString), .int(Self.integer(now)), .int(Int64(max(1, min(limit, 128))))]
            }
            var notDue = false
            try rows(sql, parameters) { stmt in
                if sqlite3_column_int64(stmt, 1) > Self.integer(now) { notDue = true }
                let data = self.blob(stmt, 0)
                if batchID == nil && totalBytes + data.count > 480000 { return }
                totalBytes += data.count; events.append(try JSONDecoder().decode(ActivityEvent.self, from: data))
            }
            guard !notDue, !events.isEmpty else { return nil }
            let result = ActivityBatch(batchID: batchID ?? UUID(), events: events)
            _ = try result.encoded()
            if batchID == nil {
                for event in events { try run("UPDATE activity_events SET batch_id=? WHERE event_id=? AND state=0", [.text(result.batchID.uuidString), .text(event.eventID.uuidString)]) }
            }
            return result
        }
    }
    /// Exact event IDs only. A maximum received sequence is NOT an acknowledgement.
    public func acknowledge(_ batch: ActivityBatch, eventIDs: Set<UUID>, lease: ActivityAuthorizationLease, now: UInt64) throws {
        lock.lock(); defer { lock.unlock() }
        try transaction {
            try validate(lease)
            let expected = Set(batch.events.map(\.eventID))
            guard expected == eventIDs, !eventIDs.isEmpty else { throw ActivityError.invalidAcknowledgement }
            for event in batch.events {
                guard event.deviceGroup == group, event.deviceID == device,
                      let original = try firstBlob("SELECT payload FROM activity_events WHERE event_id=? AND state=0 AND generation=? AND batch_id=?", [.text(event.eventID.uuidString), .text(lease.generation.uuidString), .text(batch.batchID.uuidString)]),
                      original == (try event.encoded()) else { throw ActivityError.invalidAcknowledgement }
                try run("UPDATE activity_events SET state=2,ack_at=? WHERE event_id=? AND state=0 AND generation=? AND batch_id=?", [.int(Self.integer(now)), .text(event.eventID.uuidString), .text(lease.generation.uuidString), .text(batch.batchID.uuidString)])
                guard sqlite3_changes(db) == 1 else { throw ActivityError.invalidAcknowledgement }
            }
        }
    }
    public func recordFailure(_ batch: ActivityBatch, lease: ActivityAuthorizationLease, now: UInt64) throws {
        lock.lock(); defer { lock.unlock() }
        try transaction {
            try validate(lease)
            var attempt: Int64 = 0
            try rows("SELECT MAX(attempts) FROM activity_events WHERE batch_id=? AND state=0", [.text(batch.batchID.uuidString)]) { attempt = sqlite3_column_int64($0, 0) }
            let exponent = min(max(attempt, 0), 11)
            let delay = min(Int64(3600), (Int64(1) << exponent) * 2) + Int64.random(in: 0...3)
            try run("UPDATE activity_events SET attempts=MIN(attempts+1,1000000),next_attempt=? WHERE state=0 AND generation=? AND batch_id=?", [.int(min(Int64.max - delay, Self.integer(now)) + delay), .text(lease.generation.uuidString), .text(batch.batchID.uuidString)])
        }
    }
    /// Successful records can expire locally; pending/held records require an explicit
    /// user decision, never an implicit upgrade/reset deletion.
    public func pruneAcknowledged(before: UInt64) throws {
        lock.lock(); defer { lock.unlock() }
        try run("DELETE FROM activity_events WHERE state=2 AND ack_at<?", [.int(Self.integer(before))])
        try execute("PRAGMA wal_checkpoint(PASSIVE)")
    }
    public func discardHeldRecords() throws {
        lock.lock(); defer { lock.unlock() }
        try execute("DELETE FROM activity_events WHERE state=1; PRAGMA wal_checkpoint(PASSIVE)")
    }
    /// Only call after independently verified group departure/personal-data reset.
    /// Ordinary pause/disable never calls this. Installation and sequence remain
    /// monotonic so an old server tombstone cannot be bypassed by local reset.
    public func purgeForConfirmedDeparture() throws {
        lock.lock(); defer { lock.unlock() }
        try transaction {
            var value = try configuration(); value.enabled = false; value.consentVersion = 0
            value.providers = []; value.endpoint = nil
            try setMetadata("configuration", JSONEncoder().encode(value))
            try setMetadata("generation", Data(UUID().uuidString.utf8))
            try execute("DELETE FROM activity_events; DELETE FROM activity_observations")
        }
        try execute("PRAGMA wal_checkpoint(TRUNCATE); VACUUM")
    }
    public func status() throws -> ActivityQueueStatus {
        lock.lock(); defer { lock.unlock() }
        var pending = 0, held = 0, acknowledged = 0, bytes = 0
        try rows("SELECT state,COUNT(*),COALESCE(SUM(length(payload)),0) FROM activity_events GROUP BY state", []) { stmt in
            switch sqlite3_column_int(stmt, 0) { case 0: pending = Int(sqlite3_column_int64(stmt, 1)); case 1: held = Int(sqlite3_column_int64(stmt, 1)); case 2: acknowledged = Int(sqlite3_column_int64(stmt, 1)); default: throw ActivityError.storageFailure }
            bytes += Int(sqlite3_column_int64(stmt, 2))
        }
        guard let installation = try UUID(uuidString: textMetadata("installation")), let seq = try UInt64(textMetadata("sequence")) else { throw ActivityError.storageFailure }
        return ActivityQueueStatus(pending: pending, held: held, acknowledged: acknowledged, payloadBytes: bytes, installationID: installation, lastSequence: seq)
    }
    private enum Binding { case text(String), data(Data), int(Int64), null }
    private static func integer(_ n: UInt64) -> Int64 { Int64(min(n, UInt64(Int64.max))) }
    private func capDatabase(_ payloadLimit: Int) throws {
        // A separate hard bound includes metadata/index allowance. WAL is checkpointed
        // in small increments and SQLite reports capacity failures instead of losing input.
        try execute("PRAGMA max_page_count=\((payloadLimit + 4 * 1024 * 1024) / 4096)")
    }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result = try body(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func execute(_ sql: String) throws {
        let code = sqlite3_exec(db, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw code == SQLITE_FULL ? ActivityError.quotaExceeded : ActivityError.storageFailure }
    }
    private func statement(_ sql: String, _ values: [Binding]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw ActivityError.storageFailure }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1), code: Int32
            switch value {
            case let .text(text): code = text.withCString { sqlite3_bind_text(stmt, index, $0, -1, Self.transient) }
            case let .data(data): code = data.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(data.count), Self.transient) }
            case let .int(n): code = sqlite3_bind_int64(stmt, index, n)
            case .null: code = sqlite3_bind_null(stmt, index)
            }
            if code != SQLITE_OK { sqlite3_finalize(stmt); throw ActivityError.storageFailure }
        }
        return stmt
    }
    private func run(_ sql: String, _ values: [Binding]) throws {
        let stmt = try statement(sql, values); defer { sqlite3_finalize(stmt) }
        let code = sqlite3_step(stmt)
        guard code == SQLITE_DONE else { throw code == SQLITE_FULL ? ActivityError.quotaExceeded : ActivityError.storageFailure }
    }
    private func rows(_ sql: String, _ values: [Binding], _ body: (OpaquePointer) throws -> Void) throws {
        let stmt = try statement(sql, values); defer { sqlite3_finalize(stmt) }
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { return }
            guard code == SQLITE_ROW else { throw ActivityError.storageFailure }
            try body(stmt)
        }
    }
    private func string(_ stmt: OpaquePointer, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(stmt, column) else { return "" }; return String(cString: pointer)
    }
    private func blob(_ stmt: OpaquePointer, _ column: Int32) -> Data {
        guard let p = sqlite3_column_blob(stmt, column) else { return Data() }; return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, column)))
    }
    private func firstBlob(_ sql: String, _ values: [Binding]) throws -> Data? {
        var result: Data?; try rows(sql, values) { result = self.blob($0, 0) }; return result
    }
    private func metadata(_ key: String) throws -> Data? { try firstBlob("SELECT value FROM activity_meta WHERE key=?", [.text(key)]) }
    private func textMetadata(_ key: String) throws -> String {
        guard let data = try metadata(key), let value = String(data: data, encoding: .utf8) else { throw ActivityError.storageFailure }; return value
    }
    private func setMetadata(_ key: String, _ value: Data) throws { try run("INSERT INTO activity_meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(key), .data(value)]) }
}
