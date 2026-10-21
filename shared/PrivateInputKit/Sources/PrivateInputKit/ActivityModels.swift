import Foundation
import CryptoKit

/// Archiving is separate from encrypted word/clipboard sync and always starts off.
public struct ActivityConfiguration: Codable, Equatable {
    public var enabled: Bool
    public var paused: Bool
    public var endpoint: URL?
    public var providers: Set<String>
    public var excludedSourceApps: Set<String>
    public var consentVersion: UInt64
    public var maxQueueBytes: Int
    public var maxQueueEvents: Int
    public init(enabled: Bool = false, paused: Bool = false, endpoint: URL? = nil,
                providers: Set<String> = [], excludedSourceApps: Set<String> = [],
                consentVersion: UInt64 = 0, maxQueueBytes: Int = 32 * 1024 * 1024,
                maxQueueEvents: Int = 20000) {
        self.enabled = enabled; self.paused = paused; self.endpoint = endpoint
        self.providers = providers; self.excludedSourceApps = excludedSourceApps
        self.consentVersion = consentVersion; self.maxQueueBytes = maxQueueBytes
        self.maxQueueEvents = maxQueueEvents
    }
    public var collecting: Bool { enabled && !paused && consentVersion > 0 && endpoint != nil && !providers.isEmpty }
    public func validate() throws {
        guard (1048576...134217728).contains(maxQueueBytes), (1...100000).contains(maxQueueEvents),
              providers.count <= 32, excludedSourceApps.count <= 256,
              providers.allSatisfy(ActivityEvent.validProvider),
              !enabled || (consentVersion > 0 && endpoint != nil && !providers.isEmpty) else { throw ActivityError.invalidConfiguration }
        if let endpoint { _ = try ActivityHTTPTransport(endpoint: endpoint) }
    }
}

public enum ActivityError: Error, Equatable {
    case invalidConfiguration, disabled, unsafeField, excludedSource, providerDisabled
    case invalidEvent, eventTooLarge, quotaExceeded, storageFailure, sequenceExhausted, alreadyObserved
    case staleAuthorization, invalidAcknowledgement, invalidResponse, responseTooLarge
    case invalidEndpoint, httpStatus(Int), remote(String), serverDisabled, consentMismatch
}
public enum ActivityEventType: String, Codable, CaseIterable {
    case inputCommit = "input_commit", clipboardObserved = "clipboard_observed", pasteAction = "paste_action"
    case textRevise = "text_revise", textRetract = "text_retract", sourceImport = "source_import", coverageGap = "coverage_gap"
}
public enum ActivityFieldSafety { case safe, secure, unknown }
public enum ActivityCommitConfirmation: String, Codable {
    case insertRequested = "insert_requested", editorAcknowledged = "editor_acknowledged", observedMatch = "observed_match"
    case notApplicable = "not_applicable", unknown
}

/// JSON extension values are inert data. Numbers use integers for cross-language canonicalization.
public indirect enum ActivityJSONValue: Codable, Equatable {
    case string(String), integer(Int64), bool(Bool), null, array([ActivityJSONValue]), object([String: ActivityJSONValue])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: ActivityJSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([ActivityJSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .string(v): try c.encode(v)
        case let .integer(v): try c.encode(v)
        case let .bool(v): try c.encode(v)
        case let .array(v): try c.encode(v)
        case let .object(v): try c.encode(v)
        }
    }
}

public struct ActivityProviderCapabilities: Equatable {
    public let identifier: String
    public let eventTypes: Set<ActivityEventType>
    public let foregroundOnly: Bool
    public init(identifier: String, eventTypes: Set<ActivityEventType>, foregroundOnly: Bool) {
        self.identifier = identifier; self.eventTypes = eventTypes; self.foregroundOnly = foregroundOnly
    }
}
public protocol ActivityProvider {
    var capabilities: ActivityProviderCapabilities { get }
    func stop()
}

/// A provider supplies only what it actually observed. Unknown application/document/anchors stay nil.
public struct ActivityEventDraft {
    public var providerID: String
    public var eventType: ActivityEventType
    public var text: String
    public var observedAt: Date
    public var timeZone: TimeZone
    public var inputSession: String?
    public var editorEpoch: String?
    public var spanID: String?
    public var editOperation: ActivityJSONValue?
    public var sourceKind: String?
    public var sourceApp: String?
    public var documentID: String?
    public var commitConfirmation: ActivityCommitConfirmation
    public var links: [ActivityJSONValue]
    public var extensions: [String: ActivityJSONValue]?
    /// A system clipboard version or immutable import primary key, never a text hash.
    public var observationID: String?
    public init(providerID: String, eventType: ActivityEventType, text: String, observedAt: Date = Date(),
                timeZone: TimeZone = .current, inputSession: String? = nil, editorEpoch: String? = nil,
                spanID: String? = nil, editOperation: ActivityJSONValue? = nil, sourceKind: String? = nil,
                sourceApp: String? = nil, documentID: String? = nil,
                commitConfirmation: ActivityCommitConfirmation = .unknown,
                links: [ActivityJSONValue] = [], extensions: [String: ActivityJSONValue]? = nil, observationID: String? = nil) {
        self.providerID = providerID; self.eventType = eventType; self.text = text; self.observedAt = observedAt
        self.timeZone = timeZone; self.inputSession = inputSession; self.editorEpoch = editorEpoch; self.spanID = spanID
        self.editOperation = editOperation; self.sourceKind = sourceKind; self.sourceApp = sourceApp; self.documentID = documentID
        self.commitConfirmation = commitConfirmation; self.links = links; self.extensions = extensions; self.observationID = observationID
    }
}

public struct ActivityEvent: Codable, Equatable {
    public struct Content: Codable, Equatable { public let text: String }
    public let schemaVersion: Int
    public let eventID: UUID
    public let deviceGroup: UUID
    public let deviceID: UUID
    public let installationID: UUID
    public let deviceSeq: UInt64
    public let providerID: String
    public let eventType: ActivityEventType
    public let observedAt: String
    public let timezoneID: String
    public let utcOffsetMinutes: Int
    public let inputSession: String?
    public let editorEpoch: String?
    public let spanID: String?
    public let editOp: ActivityJSONValue?
    public let sourceKind: String?
    public let sourceApp: String?
    public let documentID: String?
    public let content: Content
    public let deliveryState: String
    public let commitConfirmation: ActivityCommitConfirmation
    public let consentVersion: UInt64
    public let sensitivity: String
    public let links: [ActivityJSONValue]
    public let timeQuality: String
    public let extensions: [String: ActivityJSONValue]?
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", eventID = "event_id", deviceGroup = "device_group", deviceID = "device_id"
        case installationID = "installation_id", deviceSeq = "device_seq", providerID = "provider_id", eventType = "event_type"
        case observedAt = "observed_at", timezoneID = "timezone_id", utcOffsetMinutes = "utc_offset_minutes"
        case inputSession = "input_session", editorEpoch = "editor_epoch", spanID = "span_id", editOp = "edit_op"
        case sourceKind = "source_kind", sourceApp = "source_app", documentID = "document_id", content
        case deliveryState = "delivery_state", commitConfirmation = "commit_confirmation", consentVersion = "consent_version"
        case sensitivity, links, timeQuality = "time_quality", extensions
    }
    init(draft: ActivityEventDraft, group: UUID, device: UUID, installation: UUID, sequence: UInt64, consent: UInt64) throws {
        guard Self.validProvider(draft.providerID), draft.text.utf8.count <= 262144,
              draft.observedAt.timeIntervalSince1970.isFinite,
              draft.links.count <= 128,
              draft.eventType != .coverageGap || draft.text.isEmpty,
              [draft.inputSession, draft.editorEpoch, draft.spanID, draft.sourceKind, draft.sourceApp, draft.documentID].allSatisfy({ ($0?.utf8.count ?? 0) <= 1024 }),
              (draft.observationID?.utf8.count ?? 0) <= 1024 else { throw ActivityError.invalidEvent }
        schemaVersion = 1; eventID = UUID(); deviceGroup = group; deviceID = device; installationID = installation
        deviceSeq = sequence; providerID = draft.providerID; eventType = draft.eventType
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        observedAt = formatter.string(from: draft.observedAt); timezoneID = draft.timeZone.identifier
        utcOffsetMinutes = draft.timeZone.secondsFromGMT(for: draft.observedAt) / 60
        inputSession = draft.inputSession; editorEpoch = draft.editorEpoch; spanID = draft.spanID; editOp = draft.editOperation
        sourceKind = draft.sourceKind; sourceApp = draft.sourceApp; documentID = draft.documentID
        content = Content(text: draft.text); deliveryState = "draft_unknown"; commitConfirmation = draft.commitConfirmation
        consentVersion = consent; sensitivity = "personal"; links = draft.links; timeQuality = "device_clock_unverified"
        extensions = draft.extensions
        guard try encoded().count <= 262144 else { throw ActivityError.eventTooLarge }
    }
    public func encoded() throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try encoder.encode(self) }
    static func validProvider(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 96 && text.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45,46,95].contains($0) }
    }
}

public enum ActivityOperation: UInt8, Codable {
    case status = 1, groupPolicy = 2, deviceConsent = 3, ingest = 4, query = 5, changes = 6, snapshot = 7, export = 8, erase = 9, paragraphs = 10, registerDelegate = 11
}
/// A keyboard delegate owns ONLY this signing key. No group roots, exchange or
/// local-storage keys need to cross from the containing app into the extension.
public struct ActivityRequestSigner {
    public enum Scope { case deviceIdentity, captureDelegate }
    public let device: UUID
    public let signingKey: Curve25519.Signing.PrivateKey
    public let scope: Scope
    public init(device: UUID, signingKey: Curve25519.Signing.PrivateKey) { self.device = device; self.signingKey = signingKey; scope = .captureDelegate }
    public init(identity: DeviceIdentity) { device = identity.device; signingKey = identity.signingKey; scope = .deviceIdentity }
}
public struct SignedActivityRequest: Codable {
    public let version: UInt8
    public let group: UUID
    public let sender: UUID
    public let nonce: UUID
    public let issuedAt: UInt64
    public let operation: ActivityOperation
    public let body: Data
    public let signature: Data
    public func canonical() throws -> Data {
        guard version == 1, body.count <= 524288 else { throw ActivityError.eventTooLarge }
        var bytes = Data("PrivateInput/activity-request/v1\0".utf8)
        bytes.append(version); bytes.appendUUID(group); bytes.appendUUID(sender); bytes.appendUUID(nonce)
        bytes.appendBE(issuedAt); bytes.append(operation.rawValue); bytes.append(Data(SHA256.hash(data: body)))
        return bytes
    }
    public static func sign(group: UUID, identity: DeviceIdentity, operation: ActivityOperation, body: Data, now: UInt64) throws -> Self {
        try sign(group: group, signer: ActivityRequestSigner(identity: identity), operation: operation, body: body, now: now)
    }
    public static func sign(group: UUID, signer: ActivityRequestSigner, operation: ActivityOperation, body: Data, now: UInt64) throws -> Self {
        let request = Self(version: 1, group: group, sender: signer.device, nonce: UUID(), issuedAt: now, operation: operation, body: body, signature: Data())
        return Self(version: request.version, group: group, sender: request.sender, nonce: request.nonce, issuedAt: now,
                    operation: operation, body: body, signature: try signer.signingKey.signature(for: request.canonical()))
    }
    public func encoded() throws -> Data { _ = try canonical(); return try JSONEncoder().encode(self) }
}
