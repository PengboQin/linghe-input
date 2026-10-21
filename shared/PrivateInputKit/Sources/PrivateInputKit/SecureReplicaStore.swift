import Foundation
import CryptoKit
import CSQLite

public enum ReplicaStoreError: Error { case database(Int32), missingGroup, corrupt, sharingDisabled, quota, pairingConsumed, changedState }
public enum ReceiveOutcome: Equatable { case applied, duplicate, ignoredOwnMessage }
public struct ReceivedClipboard: Codable, Equatable, Identifiable {
    public let id: UUID
    public let sender: UUID
    public let text: String
    public let expiresAt: UInt64
    /// Optional wire identity for a composite, collision-safe UI projection.
    public let wireEvent: UUID?
    public var eventID: UUID {wireEvent ?? id}
    public init(id:UUID,sender:UUID,text:String,expiresAt:UInt64,wireEvent:UUID?=nil) {
        self.id=id;self.sender=sender;self.text=text;self.expiresAt=expiresAt;self.wireEvent=wireEvent
    }
}
public struct PairApprovalView {
    public let session: UUID
    public let challenge: PairingChallenge
    public let code: String
}
private struct StoredGroup: Codable {
    var anchor: MembershipAnchor
    var membership: SignedMembership
    var master: Data
    var learning = LearningModel()
    var ledger = ReplayLedger()
    var clipboard: [ReceivedClipboard] = []
    var setup: GroupSetup { get throws {
        guard master.count == 32 else { throw ReplicaStoreError.corrupt }
        return GroupSetup(membership: try anchor.verify(membership), key: SymmetricKey(data: master))
    } }
}
private struct StoredApproval: Codable {
    let parentDigest: Data
    let membership: SignedMembership
    let master: Data
    let ephemeral: Data
    let challenge: PairingChallenge
    let code: String
    func pending() throws -> PendingPairingApproval {
        guard master.count == 32, ephemeral.count == 32 else { throw ReplicaStoreError.corrupt }
        let anchor = MembershipAnchor(group: membership.group, ownerID: membership.ownerID, ownerPublic: membership.ownerPublic)
        return PendingPairingApproval(parentDigest: parentDigest,
                                      group: GroupSetup(membership: try anchor.verify(membership), key: SymmetricKey(data: master)),
                                      ephemeral: try .init(rawRepresentation: ephemeral), challenge: challenge, confirmationCode: code)
    }
}

/// Local SQLite holds encrypted state/temporary pairing secrets and public
/// encrypted outbox envelopes. Key material comes from the OS identity vault.
/// Calls belong on the containing app's sync worker, never a keystroke callback.
public final class SecureReplicaStore {
    private var db: OpaquePointer?
    private let vault: DeviceIdentityVault
    private let identity: DeviceIdentity
    private let gate = NSLock()
    private let maximumBlob = 16 * 1024 * 1024
    private enum Value { case text(String), blob(Data), number(Int64) }
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(directory: URL, vault: DeviceIdentityVault) throws {
        self.vault = vault; identity = try vault.load()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        #endif
        let file = directory.appendingPathComponent("replica-v1.sqlite")
        if FileManager.default.fileExists(atPath: file.path), try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw ReplicaStoreError.corrupt }
        let status = sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK else { if db != nil { sqlite3_close(db) }; db = nil; throw ReplicaStoreError.database(status) }
        do {
            sqlite3_busy_timeout(db, 1000); sqlite3_limit(db, SQLITE_LIMIT_LENGTH, Int32(maximumBlob + 1024))
            try execute("PRAGMA journal_mode=WAL"); try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA wal_autocheckpoint=128");try execute("PRAGMA journal_size_limit=1048576")
            try execute("PRAGMA trusted_schema=OFF"); try execute("PRAGMA secure_delete=ON")
            // Unknown schema is not overwritten or reset.
            let schema = try integer("PRAGMA user_version")
            guard schema == 0 || schema == 1 else { throw ReplicaStoreError.corrupt }
            try execute("CREATE TABLE IF NOT EXISTS groups (id TEXT PRIMARY KEY, sealed BLOB NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS outbox (event TEXT PRIMARY KEY, group_id TEXT NOT NULL, sender TEXT NOT NULL, epoch TEXT NOT NULL, sequence TEXT NOT NULL, expires INTEGER NOT NULL, wire BLOB NOT NULL, UNIQUE(sender,sequence))")
            try execute("CREATE TABLE IF NOT EXISTS receipts (group_id TEXT NOT NULL, sender TEXT NOT NULL, event TEXT NOT NULL, epoch TEXT NOT NULL, sequence TEXT NOT NULL, digest BLOB NOT NULL, expires INTEGER NOT NULL, PRIMARY KEY(group_id,sender,event), UNIQUE(group_id,sender,epoch,sequence))")
            try execute("CREATE TABLE IF NOT EXISTS pending (session TEXT PRIMARY KEY, group_id TEXT UNIQUE NOT NULL, expires INTEGER NOT NULL, sealed BLOB NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS grants (session TEXT PRIMARY KEY, expires INTEGER NOT NULL, wire BLOB NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS consumed_pairs (session TEXT PRIMARY KEY, expires INTEGER NOT NULL)")
            try execute("PRAGMA user_version=1")
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { if db != nil { sqlite3_close(db) } }
    private func statement(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        var result: OpaquePointer?
        let status = sqlite3_prepare_v2(db, sql, -1, &result, nil)
        guard status == SQLITE_OK, let result else { throw ReplicaStoreError.database(status) }
        do {
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1), code: Int32
                switch value {
                case .text(let text): code = text.withCString { sqlite3_bind_text(result, index, $0, -1, transient) }
                case .number(let number): code = sqlite3_bind_int64(result, index, number)
                case .blob(let data): code = data.withUnsafeBytes { sqlite3_bind_blob(result, index, $0.baseAddress, Int32(data.count), transient) }
                }
                guard code == SQLITE_OK else { throw ReplicaStoreError.database(code) }
            }
            return result
        } catch { sqlite3_finalize(result); throw error }
    }
    private func execute(_ sql: String, _ values: [Value] = []) throws {
        let query = try statement(sql, values); defer { sqlite3_finalize(query) }
        var result = sqlite3_step(query)
        while result == SQLITE_ROW { result = sqlite3_step(query) }
        guard result == SQLITE_DONE else { throw ReplicaStoreError.database(result) }
    }
    private func integer(_ sql: String, _ values: [Value] = []) throws -> Int64 {
        let query = try statement(sql, values); defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { throw ReplicaStoreError.corrupt }; return sqlite3_column_int64(query, 0)
    }
    private func blobs(_ sql: String, _ values: [Value] = []) throws -> [Data] {
        let query = try statement(sql, values); defer { sqlite3_finalize(query) }
        var values: [Data] = [], code = sqlite3_step(query)
        while code == SQLITE_ROW {
            let length = Int(sqlite3_column_bytes(query, 0))
            guard length > 0, length <= maximumBlob, let pointer = sqlite3_column_blob(query, 0) else { throw ReplicaStoreError.corrupt }
            values.append(Data(bytes: pointer, count: length)); code = sqlite3_step(query)
        }
        guard code == SQLITE_DONE else { throw ReplicaStoreError.database(code) }; return values
    }
    private func transaction<T>(_ action: () throws -> T) throws -> T {
        gate.lock(); defer { gate.unlock() }
        try execute("BEGIN IMMEDIATE")
        do { let result = try action(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func timestamp(_ value: UInt64) throws -> Int64 {
        guard value <= UInt64(Int64.max) else { throw ReplicaStoreError.corrupt }; return Int64(value)
    }
    private func aad(_ id: UUID, kind: String) -> Data {
        var value = Data(("PrivateInput/local/" + kind + "/v1\0").utf8); value.appendUUID(identity.device); value.appendUUID(id); return value
    }
    private func seal<T: Encodable>(_ value: T, id: UUID, kind: String) throws -> Data {
        let data = try JSONEncoder().encode(value)
        guard data.count < maximumBlob - 64 else { throw ReplicaStoreError.quota }
        return try ChaChaPoly.seal(data, using: identity.storageKey, authenticating: aad(id, kind: kind)).combined
    }
    private func open<T: Decodable>(_ type: T.Type, data: Data, id: UUID, kind: String) throws -> T {
        let box = try ChaChaPoly.SealedBox(combined: data)
        let plaintext = try ChaChaPoly.open(box, using: identity.storageKey, authenticating: aad(id, kind: kind))
        return try JSONDecoder().decode(type, from: plaintext)
    }
    private func loadGroup(_ id: UUID) throws -> StoredGroup {
        guard let data = try blobs("SELECT sealed FROM groups WHERE id=?", [.text(id.uuidString)]).first else { throw ReplicaStoreError.missingGroup }
        let value = try open(StoredGroup.self, data: data, id: id, kind: "group")
        guard value.anchor.group == id else { throw ReplicaStoreError.corrupt }
        _ = try value.setup; var model = LearningModel(); try model.merge(value.learning.export())
        return value
    }
    private func writeGroup(_ value: StoredGroup) throws {
        let id = value.anchor.group, data = try seal(value, id: id, kind: "group")
        try execute("INSERT INTO groups(id,sealed) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET sealed=excluded.sealed", [.text(id.uuidString), .blob(data)])
    }
    private func saveGroup(_ group: GroupSetup) throws {
        let id = group.membership.anchor.group
        var stored = StoredGroup(anchor: group.membership.anchor, membership: group.membership.statement, master: group.key.withUnsafeBytes { Data($0) })
        if try integer("SELECT count(*) FROM groups WHERE id=?", [.text(id.uuidString)]) > 0 {
            let old = try loadGroup(id), oldSetup = try old.setup
            _ = try old.anchor.verify(group.membership.statement, replacing: oldSetup.membership)
            if old.membership.epoch == group.membership.statement.epoch, oldSetup.key != group.key { throw MembershipError.equivocation }
            stored.learning = old.learning; stored.clipboard = old.clipboard
            let allowed = group.membership.trust(for: .clipboard).members
            stored.clipboard.removeAll { allowed[$0.sender] == nil }
            stored.ledger = old.membership.epoch == group.membership.statement.epoch ? old.ledger : ReplayLedger()
        } else if try integer("SELECT count(*) FROM groups") >= 16 { throw ReplicaStoreError.quota }
        _ = try group.membership.member(identity.device)
        try writeGroup(stored)
        try execute("DELETE FROM outbox WHERE group_id=? AND epoch!=?", [.text(id.uuidString), .text(String(group.membership.statement.epoch))])
    }
    public func initializeGroup(_ group: GroupSetup) throws { try transaction { try saveGroup(group) } }
    public func group(_ id: UUID) throws -> GroupSetup { try transaction { try loadGroup(id).setup } }

    public func beginPairing(_ request: PairRequest, group id: UUID, permissions: DevicePermissions, now: UInt64) throws -> PairApprovalView {
        try transaction {
            try request.validate(now: now)
            try execute("DELETE FROM pending WHERE expires<=?", [.number(try timestamp(now))])
            if let data = try blobs("SELECT sealed FROM pending WHERE session=?", [.text(request.session.uuidString)]).first {
                let old = try open(StoredApproval.self, data: data, id: request.session, kind: "pending")
                guard old.membership.group == id, old.challenge.template.context == (try request.digest),
                      old.membership.members.first(where: { $0.device == request.member.device })?.permissions == permissions else { throw PairingError.malformed }
                return PairApprovalView(session: request.session, challenge: old.challenge, code: old.code)
            }
            let current = try loadGroup(id).setup
            let pending = try DevicePairing.beginApproval(request, current: current, owner: vault.load(), permissions: permissions, now: now)
            let stored = StoredApproval(parentDigest: pending.parentDigest, membership: pending.group.membership.statement,
                                        master: pending.group.key.withUnsafeBytes { Data($0) }, ephemeral: pending.ephemeral.rawRepresentation,
                                        challenge: pending.challenge, code: pending.confirmationCode)
            try execute("INSERT INTO pending(session,group_id,expires,sealed) VALUES(?,?,?,?)", [.text(request.session.uuidString), .text(id.uuidString), .number(try timestamp(pending.challenge.template.expiresAt)), .blob(try seal(stored, id: request.session, kind: "pending"))])
            return PairApprovalView(session: request.session, challenge: pending.challenge, code: pending.confirmationCode)
        }
    }
    public func finishPairing(session: UUID, confirmedCode: String, now: UInt64) throws -> WrappedGroupKey {
        try transaction {
            if let data = try blobs("SELECT wire FROM grants WHERE session=? AND expires>?", [.text(session.uuidString), .number(try timestamp(now))]).first { return try WrappedGroupKey.decode(data) }
            guard let data = try blobs("SELECT sealed FROM pending WHERE session=?", [.text(session.uuidString)]).first else { throw ReplicaStoreError.pairingConsumed }
            let stored = try open(StoredApproval.self, data: data, id: session, kind: "pending"), pending = try stored.pending()
            let old = try loadGroup(pending.group.membership.anchor.group).setup
            guard old.membership.digest == pending.parentDigest else { throw ReplicaStoreError.changedState }
            let result = try DevicePairing.finishApproval(pending, owner: vault.load(), confirmedCode: confirmedCode, now: now)
            try saveGroup(result.group)
            try execute("INSERT INTO grants(session,expires,wire) VALUES(?,?,?)", [.text(session.uuidString), .number(try timestamp(result.package.expiresAt)), .blob(try result.package.encoded())])
            try execute("DELETE FROM pending WHERE session=?", [.text(session.uuidString)])
            return result.package
        }
    }
    /// Prepare public admission messages without changing the usable local key.
    /// The relay commits membership and ALL recipient packages in one transaction.
    public func stageAdmission(session:UUID,now:UInt64) throws -> AdmissionBundle {
        try transaction {
            guard let data=try blobs("SELECT sealed FROM pending WHERE session=?",[.text(session.uuidString)]).first else {throw PairingError.expired}
            let stored=try open(StoredApproval.self,data:data,id:session,kind:"pending"),pending=try stored.pending()
            guard try loadGroup(pending.group.membership.anchor.group).setup.membership.digest==pending.parentDigest else {throw ReplicaStoreError.changedState}
            let owner=try vault.load(),result=try DevicePairing.finishApproval(pending,owner:owner,confirmedCode:pending.confirmationCode,now:now)
            var packages=[result.package]
            for member in result.group.membership.statement.members where member.device != result.package.recipient {
                packages.append(try WrappedGroupKey.seal(setup:result.group,for:member.device,context:Data(repeating:0,count:32),owner:owner,now:now,expiresAt:now+2592000).package)
            }
            return AdmissionBundle(session:session,challenge:pending.challenge,membership:result.group.membership.statement,packages:packages)
        }
    }
    public func commitAdmission(session:UUID,now:UInt64) throws {
        try transaction {
            guard let data=try blobs("SELECT sealed FROM pending WHERE session=?",[.text(session.uuidString)]).first else {throw PairingError.expired}
            let stored=try open(StoredApproval.self,data:data,id:session,kind:"pending"),pending=try stored.pending()
            guard try loadGroup(pending.group.membership.anchor.group).setup.membership.digest==pending.parentDigest else {throw ReplicaStoreError.changedState}
            try saveGroup(pending.group)
            try execute("DELETE FROM pending WHERE session=?",[.text(session.uuidString)])
        }
    }
    public func discardAdmission(session:UUID) throws {
        try transaction {try execute("DELETE FROM pending WHERE session=?",[.text(session.uuidString)])}
    }
    public func prepareMemberChange(group:UUID,members:[GroupMember],now:UInt64) throws -> MemberChangeBundle {
        try transaction {
            let identity=try vault.load(),next=try loadGroup(group).setup.changingMembers(members,owner:identity)
            var packages:[WrappedGroupKey]=[]
            for member in members where member.device != identity.device {
                packages.append(try WrappedGroupKey.seal(setup:next,for:member.device,context:Data(repeating:0,count:32),owner:identity,now:now,expiresAt:now+2592000).package)
            }
            let own=members.contains(where:{$0.device==identity.device}) ? try WrappedGroupKey.seal(setup:next,for:identity.device,context:Data(repeating:0,count:32),owner:identity,now:now,expiresAt:now+2592000).package : nil
            if let own {packages.append(own)}
            return MemberChangeBundle(membership:next.membership.statement,packages:packages,localPackage:own)
        }
    }
    public func pendingApproval(session: UUID, now: UInt64) throws -> PairApprovalView {
        try transaction {
            guard let data = try blobs("SELECT sealed FROM pending WHERE session=? AND expires>?", [.text(session.uuidString), .number(try timestamp(now))]).first else { throw PairingError.expired }
            let stored = try open(StoredApproval.self, data: data, id: session, kind: "pending")
            return PairApprovalView(session: session, challenge: stored.challenge, code: stored.code)
        }
    }
    public func completedGrant(session: UUID, now: UInt64) throws -> WrappedGroupKey? {
        try transaction {
            guard let data = try blobs("SELECT wire FROM grants WHERE session=? AND expires>?", [.text(session.uuidString), .number(try timestamp(now))]).first else { return nil }
            return try WrappedGroupKey.decode(data)
        }
    }
    public func acceptPairing(_ package: WrappedGroupKey, challenge: PairingChallenge, request: PairRequest,
                              confirmedCode: String, now: UInt64) throws {
        try transaction {
            guard try integer("SELECT count(*) FROM consumed_pairs WHERE session=?", [.text(request.session.uuidString)]) == 0 else { throw ReplicaStoreError.pairingConsumed }
            let setup = try DevicePairing.accept(package, challenge: challenge, request: request, recipient: vault.load(), confirmedCode: confirmedCode, now: now)
            try saveGroup(setup)
            try execute("INSERT INTO consumed_pairs(session,expires) VALUES(?,?)", [.text(request.session.uuidString), .number(try timestamp(request.expiresAt))])
        }
    }
    public func enqueue(_ payload: Data, domain: SyncDomain, group id: UUID, sharingEnabled: Bool, now: UInt64, event: UUID = UUID(), expiresAt: UInt64? = nil) throws -> SecureEnvelope {
        guard sharingEnabled else { throw ReplicaStoreError.sharingDisabled }
        return try transaction {
            var state = try loadGroup(id); let setup = try state.setup
            try execute("DELETE FROM outbox WHERE expires<=?", [.number(try timestamp(now))])
            if let wire=try blobs("SELECT wire FROM outbox WHERE event=?",[.text(event.uuidString)]).first {
                let prior=try SecureEnvelope.decode(wire)
                guard prior.group==id,prior.domain==domain,prior.sender==identity.device else {throw ReplicaStoreError.corrupt}
                let opened=try SecureMessage.open(prior,groupKey:setup.key,trust:setup.membership.trust(for:domain),ledger:ReplayLedger(),now:now)
                guard opened.payload==payload else {throw ReplicaStoreError.corrupt};return prior
            }
            guard try integer("SELECT count(*) FROM outbox") < 256 else { throw ReplicaStoreError.quota }
            let ttl: UInt64 = domain == .clipboard ? 600 : 604800
            guard now <= UInt64(Int64.max) - ttl else { throw ReplicaStoreError.corrupt }
            let expiry=expiresAt ?? now+ttl
            guard expiry>now,expiry-now<=ttl else {throw SyncSecurityError.expired}
            let reserved = try vault.reserveSequence()
            guard reserved.identity.device == identity.device else { throw ReplicaStoreError.corrupt }
            let message = try SecureMessage.seal(payload: payload, domain: domain, groupKey: setup.key,
                                                  signingKey: reserved.identity.signingKey, trust: setup.membership.trust(for: domain),
                                                  sender: identity.device, event: event, sequence: reserved.sequence, issuedAt: now, expiresAt: expiry)
            let wire = try message.encoded()
            guard try integer("SELECT coalesce(sum(length(wire)),0) FROM outbox") + Int64(wire.count) <= 32 * 1024 * 1024 else { throw ReplicaStoreError.quota }
            if domain == .learning { try state.learning.merge(payload); try writeGroup(state) }
            try execute("INSERT INTO outbox(event,group_id,sender,epoch,sequence,expires,wire) VALUES(?,?,?,?,?,?,?)", [.text(message.event.uuidString), .text(id.uuidString), .text(identity.device.uuidString), .text(String(message.epoch)), .text(String(message.sequence)), .number(try timestamp(message.expiresAt)), .blob(wire)])
            return message
        }
    }
    public func pendingMessages(now: UInt64) throws -> [Data] {
        try transaction {
            try execute("DELETE FROM outbox WHERE expires<=?", [.number(try timestamp(now))])
            return try blobs("SELECT wire FROM outbox ORDER BY rowid LIMIT 8")
        }
    }
    public func pendingMessages(group: UUID, domains: [SyncDomain], now: UInt64) throws -> [Data] {
        try transaction {
            try execute("DELETE FROM outbox WHERE expires<=?", [.number(try timestamp(now))])
            let allowed = Set(domains.map(\.rawValue))
            guard !allowed.isEmpty else { return [] }
            let placeholders = allowed.map { _ in "?" }.joined(separator: ",")
            let values: [Value] = [.text(group.uuidString)] + allowed.sorted().map { .number(Int64($0)) }
            return try blobs("SELECT wire FROM outbox WHERE group_id=? AND json_extract(CAST(wire AS TEXT),'$.domain') IN (" + placeholders + ") ORDER BY rowid LIMIT 8", values)
        }
    }
    /// Called only after a verified successful relay acknowledgment.
    public func acknowledgeSent(_ event: UUID) throws { try transaction { try execute("DELETE FROM outbox WHERE event=?", [.text(event.uuidString)]) } }
    public func receive(_ wire: Data, now: UInt64, receivingEnabled: Bool) throws -> ReceiveOutcome {
        guard receivingEnabled else { throw ReplicaStoreError.sharingDisabled }
        let message = try SecureEnvelope.decode(wire)
        return try transaction {
            var state = try loadGroup(message.group); let setup = try state.setup
            let required: DevicePermissions = message.domain == .learning ? .learning : .clipboard
            guard try setup.membership.member(identity.device).permissions.contains(required) else { throw MembershipError.notMember }
            let digest = Data(SHA256.hash(data: try message.header() + message.ciphertext))
            let receipt = try blobs("SELECT digest FROM receipts WHERE group_id=? AND sender=? AND event=?", [.text(message.group.uuidString), .text(message.sender.uuidString), .text(message.event.uuidString)]).first
            let opened: OpenedSyncMessage
            do { opened = try SecureMessage.open(message, groupKey: setup.key, trust: setup.membership.trust(for: message.domain), ledger: state.ledger, now: now) }
            catch SyncSecurityError.replay {
                if receipt == digest { return .duplicate }; throw SyncSecurityError.replay
            }
            guard receipt == nil else { throw SyncSecurityError.invalidEnvelope }
            state.clipboard.removeAll { $0.expiresAt <= now }
            if message.sender != identity.device {
                if message.domain == .learning { try state.learning.merge(opened.payload) }
                else {
                    guard let text = String(data: opened.payload, encoding: .utf8) else { throw SyncSecurityError.invalidPayload }
                    state.clipboard.append(ReceivedClipboard(id: message.event, sender: message.sender, text: text, expiresAt: message.expiresAt))
                    while state.clipboard.count > 32 || state.clipboard.reduce(0, { $0 + $1.text.utf8.count }) > 1024 * 1024 { state.clipboard.removeFirst() }
                }
            }
            state.ledger = opened.ledger
            try execute("INSERT INTO receipts(group_id,sender,event,epoch,sequence,digest,expires) VALUES(?,?,?,?,?,?,?)", [.text(message.group.uuidString), .text(message.sender.uuidString), .text(message.event.uuidString), .text(String(message.epoch)), .text(String(message.sequence)), .blob(digest), .number(try timestamp(message.expiresAt))])
            try writeGroup(state) // State and receipt/ledger commit together.
            try execute("DELETE FROM receipts WHERE expires<=?", [.number(try timestamp(now))])
            return message.sender == identity.device ? .ignoredOwnMessage : .applied
        }
    }
    public func learningArchive(group: UUID) throws -> Data { try transaction { try loadGroup(group).learning.export() } }
    public func clipboard(group: UUID, now: UInt64) throws -> [ReceivedClipboard] {
        try transaction { var state = try loadGroup(group); state.clipboard.removeAll { $0.expiresAt <= now }; try writeGroup(state); return state.clipboard }
    }
    public func applyRotation(_ package: WrappedGroupKey, now: UInt64) throws {
        try transaction {
            let old = try loadGroup(package.membership.group).setup
            try saveGroup(package.openRotation(recipient: vault.load(), current: old.membership, now: now))
        }
    }
    public func rotationPackage(group id: UUID, recipient: UUID, now: UInt64) throws -> WrappedGroupKey {
        try transaction {
            guard now <= UInt64(Int64.max) - 2592000 else { throw ReplicaStoreError.corrupt }
            return try WrappedGroupKey.seal(setup: loadGroup(id).setup, for: recipient, context: Data(repeating: 0, count: 32),
                                             owner: vault.load(), now: now, expiresAt: now + 2592000).package
        }
    }
    public func changeMembers(group id: UUID, members: [GroupMember]) throws {
        try transaction { let next = try loadGroup(id).setup.changingMembers(members, owner: vault.load()); try saveGroup(next) }
    }
}
