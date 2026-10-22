import Foundation

/// Additive decision evidence carried only by the independently authorized IME
/// diagnostic provider. This value performs no I/O and does not enable capture.
/// Freeze small value snapshots on the input owner; encode/queue on its worker.
public struct ActivityInputDecisionDiagnostic {
    public static let extensionKey = "org.linghe.decision.v1"
    public static let stages: Set<String> = ["input", "candidates", "press", "release", "selection", "commit", "cancel", "feedback", "error", "marked_text"]
    public static let sources: Set<String> = ["exact", "public", "personal", "cloud", "correction", "semantic", "literal", "unknown"]
    public let fields: [String: ActivityJSONValue]

    /// IDs identify observed states, not text hashes. Revision is monotonic within
    /// a composition. monotonicUS is comparable only inside the same clockDomain.
    /// details follows docs/INPUT-DECISION-DIAGNOSTICS-V1-20261022.md.
    public init(compositionID: String, revision: Int64, stateID: String, stage: String,
                clockDomain: String, monotonicUS: Int64,
                details: [String: ActivityJSONValue] = [:]) throws {
        var value = details
        value["version"] = .integer(1); value["composition_id"] = .string(compositionID)
        value["revision"] = .integer(revision); value["state_id"] = .string(stateID)
        value["stage"] = .string(stage); value["clock_domain"] = .string(clockDomain)
        value["monotonic_us"] = .integer(monotonicUS)
        try Self.validate(value); fields = value
    }

    public var extensionValue: ActivityJSONValue { .object(fields) }
    public static func validate(_ value: [String: ActivityJSONValue]) throws {
        let required: Set<String> = ["version", "composition_id", "revision", "state_id", "stage", "clock_domain", "monotonic_us"]
        let ids: Set<String> = ["composition_id", "state_id", "clock_domain", "snapshot_id", "decision_id", "press_state_id", "release_state_id", "selected_candidate_id", "output_event_id", "related_decision_id"]
        let hashes: Set<String> = ["core_hash", "resource_hash", "policy_hash", "model_hash"]
        let counts: Set<String> = ["revision", "monotonic_us", "total_count", "observed_count", "selected_rank", "recall_count", "filtered_count", "press_monotonic_us", "release_monotonic_us"]
        let optional: Set<String> = ids.union(hashes).union(counts).union(["candidates", "selected_candidate", "truncated", "coverage", "method", "reason", "model_version", "local_overlay", "filter_reason_counts", "label_source", "intended_text", "marked_text", "marked_status"])
        guard required.isSubset(of: Set(value.keys)), Set(value.keys).isSubset(of: required.union(optional)),
              value["version"] == .integer(1), case let .string(stage)? = value["stage"], stages.contains(stage) else { throw ActivityError.invalidEvent }
        func tag(_ v: ActivityJSONValue?) -> Bool {
            guard case let .string(s)? = v else { return false }
            return !s.isEmpty && s.utf8.count <= 96 && s.utf8.allSatisfy { (33...126).contains($0) }
        }
        for key in ids where value[key] != nil { guard tag(value[key]) else { throw ActivityError.invalidEvent } }
        for key in hashes where value[key] != nil {
            guard case let .string(s)? = value[key], s.utf8.count == 64,
                  s.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw ActivityError.invalidEvent }
        }
        for key in counts where value[key] != nil {
            guard case let .integer(n)? = value[key], n >= 0, n <= 9_007_199_254_740_991 else { throw ActivityError.invalidEvent }
        }
        for key in ["reason", "model_version"] where value[key] != nil { guard tag(value[key]) else { throw ActivityError.invalidEvent } }
        for key in ["truncated", "local_overlay"] where value[key] != nil { guard case .bool? = value[key] else { throw ActivityError.invalidEvent } }
        if let method = value["method"] { guard case let .string(s) = method, ["touch", "mouse", "space", "number", "enter", "gesture", "unknown"].contains(s) else { throw ActivityError.invalidEvent } }
        if let label = value["label_source"] { guard case let .string(s) = label, ["user_confirmed", "weak_signal", "synthetic"].contains(s) else { throw ActivityError.invalidEvent } }
        if let marked = value["marked_text"] { guard case let .string(s) = marked, s.utf8.count <= 4096 else { throw ActivityError.invalidEvent } }
        if let status = value["marked_status"] { guard case let .string(s) = status, ["not_used", "insert_requested", "host_acknowledged", "host_rejected", "unknown"].contains(s) else { throw ActivityError.invalidEvent } }
        if let intended = value["intended_text"] {
            guard stage == "feedback", value["label_source"] != nil, case let .string(s) = intended, s.utf8.count <= 256 else { throw ActivityError.invalidEvent }
        }
        if let reasons = value["filter_reason_counts"] {
            guard case let .object(rows) = reasons, rows.count <= 8 else { throw ActivityError.invalidEvent }
            for (reason, count) in rows {
                guard tag(.string(reason)), case let .integer(n) = count, n >= 0, n <= 9_007_199_254_740_991 else { throw ActivityError.invalidEvent }
            }
        }
        func candidate(_ row: ActivityJSONValue) throws -> (String, Int64) {
            guard case let .object(c) = row,
                  Set(["candidate_id", "text", "absolute_rank", "source"]).isSubset(of: Set(c.keys)),
                  Set(c.keys).isSubset(of: Set(["candidate_id", "text", "absolute_rank", "source", "reading"])),
                  tag(c["candidate_id"]), case let .string(id)? = c["candidate_id"],
                  case let .string(text)? = c["text"], text.utf8.count <= 256,
                  case let .integer(rank)? = c["absolute_rank"], rank >= 0, rank <= 9_007_199_254_740_991,
                  case let .string(source)? = c["source"], sources.contains(source) else { throw ActivityError.invalidEvent }
            if let reading = c["reading"] { guard case let .string(s) = reading, s.utf8.count <= 256 else { throw ActivityError.invalidEvent } }
            return (id, rank)
        }
        if let selected = value["selected_candidate"] {
            let (id, rank) = try candidate(selected)
            if let selectedID = value["selected_candidate_id"] { guard selectedID == .string(id) else { throw ActivityError.invalidEvent } }
            if let selectedRank = value["selected_rank"] { guard selectedRank == .integer(rank) else { throw ActivityError.invalidEvent } }
        }
        if let candidates = value["candidates"] {
            guard case let .array(rows) = candidates, rows.count <= 5,
                  value["observed_count"] == .integer(Int64(rows.count)),
                  case let .string(coverage)? = value["coverage"], ["published_subset", "visible_subset", "complete_set"].contains(coverage),
                  case let .bool(truncated)? = value["truncated"] else { throw ActivityError.invalidEvent }
            var seenIDs = Set<String>(), seenRanks = Set<Int64>()
            for row in rows {
                let (id, rank) = try candidate(row)
                guard seenIDs.insert(id).inserted, seenRanks.insert(rank).inserted else { throw ActivityError.invalidEvent }
                if case let .integer(total)? = value["total_count"] { guard rank < total else { throw ActivityError.invalidEvent } }
            }
            if case let .integer(total)? = value["total_count"] {
                guard total >= Int64(rows.count), !(!truncated && total > Int64(rows.count)),
                      coverage != "complete_set" || total == Int64(rows.count) else { throw ActivityError.invalidEvent }
            }
            if coverage == "complete_set" { guard !truncated else { throw ActivityError.invalidEvent } }
        } else if ["total_count", "observed_count", "truncated", "coverage"].contains(where: { value[$0] != nil }) { throw ActivityError.invalidEvent }

    }

    public static func validateEnvelope(provider: String, eventType: ActivityEventType,
                                        sourceKind: String?, confirmation: ActivityCommitConfirmation,
                                        extensions: [String: ActivityJSONValue]?) throws {
        if let link = extensions?["org.linghe.decision-link.v1"] {
            guard [.inputCommit, .pasteAction, .textRevise, .textRetract].contains(eventType),
                  case let .object(ids) = link, !ids.isEmpty,
                  Set(ids.keys).isSubset(of: Set(["composition_id", "decision_id", "state_id"])) else { throw ActivityError.invalidEvent }
            for v in ids.values {
                guard case let .string(s) = v, !s.isEmpty, s.utf8.count <= 96,
                      s.utf8.allSatisfy({ (33...126).contains($0) }) else { throw ActivityError.invalidEvent }
            }
        }
        if extensions?[extensionKey] != nil || extensions?[ActivityInputDiagnostic.extensionKey] != nil {
            guard provider == ActivityInputDiagnostic.provider, eventType == .sourceImport,
                  sourceKind == "ime_diagnostic", confirmation == .notApplicable else { throw ActivityError.invalidEvent }
        }
        guard let detail = extensions?[extensionKey] else { return }
        guard case let .object(fields) = detail else { throw ActivityError.invalidEvent }
        try validate(fields)
    }
}
