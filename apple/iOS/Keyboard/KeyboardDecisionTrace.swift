import Foundation
import PrivateInputKit

/// Optional, input-owner value bookkeeping. Instantiate/update only after the
/// independent diagnostic-provider and safe-field checks. No I/O or settings.
struct KeyboardDecisionTrace<Scope: Equatable> {
    struct Candidate: Equatable {
        let identity: String, text: String, reading: String, source: String
    }
    struct State {
        let scope: Scope, document: String?, epoch: String
        let compositionID: String, revision: Int64, stateID: String, clockDomain: String
        let rows: [Candidate], candidateIDs: [String]
        let metadata: [String: ActivityJSONValue]
        func matchesOwner(scope: Scope?, document: String?, epoch: String) -> Bool {
            self.scope == scope && self.document == document && self.epoch == epoch
        }
    }
    struct Selection {
        let state: State, candidate: Candidate, candidateID: String, rank: Int64, decisionID: String, method: String
        var pressStateID: String?, releaseStateID: String?, pressUS: Int64?, releaseUS: Int64?
        var link: [String: String] { ["composition_id": state.compositionID, "decision_id": decisionID, "state_id": state.stateID] }
    }
    private(set) var state: State?
    private var compositionID = UUID().uuidString
    private let clockDomain = UUID().uuidString
    private var held: [String: Selection] = [:]
    private var released: Selection?
    private var complete = false

    mutating func publish(scope: Scope, document: String?, epoch: String, revision: Int64, rows: [Candidate], metadata: [String: ActivityJSONValue] = [:]) -> State {
        if complete || state.map({ $0.scope != scope || $0.document != document || $0.epoch != epoch }) == true {
            compositionID = UUID().uuidString; held = [:]; released = nil; complete = false; state = nil
        }
        let bounded = Array(rows.prefix(5))
        if let state, state.revision == revision, state.rows == bounded, state.metadata == metadata { return state }
        let next = State(scope: scope, document: document, epoch: epoch, compositionID: compositionID, revision: revision,
            stateID: UUID().uuidString, clockDomain: clockDomain, rows: bounded,
            candidateIDs: bounded.map { _ in UUID().uuidString }, metadata: metadata)
        state = next; return next
    }
    mutating func endComposition() { complete = true; held = [:]; released = nil }
    private func selection(_ candidate: Candidate, rank: Int, method: String, state: State) -> Selection {
        let id = state.rows.firstIndex(of: candidate).map { state.candidateIDs[$0] } ?? UUID().uuidString
        return Selection(state: state, candidate: candidate, candidateID: id, rank: Int64(rank), decisionID: UUID().uuidString, method: method)
    }
    mutating func press(_ candidate: Candidate, rank: Int, nowUS: Int64) -> Selection? {
        guard let state, rank >= 0 else { return nil }
        var value = selection(candidate, rank: rank, method: "touch", state: state)
        value.pressStateID = state.stateID; value.pressUS = nowUS
        if held.count >= 4 { held.removeAll() }
        held[candidate.identity] = value; return value
    }
    mutating func release(_ candidate: Candidate, accepted: Bool, nowUS: Int64) -> Selection? {
        guard var value = held.removeValue(forKey: candidate.identity), let state else { return nil }
        value.releaseStateID = state.stateID; value.releaseUS = nowUS
        released = accepted ? value : nil; return value
    }
    mutating func select(_ candidate: Candidate, rank: Int, method: String) -> Selection? {
        guard let state, rank >= 0 else { return nil }
        defer { released = nil }
        if let released, released.candidate.identity == candidate.identity { return released }
        return selection(candidate, rank: rank, method: method, state: state)
    }
    static func decision(_ state: State, stage: String, nowUS: Int64, selection: Selection? = nil,
                         reason: String? = nil, outputEventID: UUID? = nil, includeCandidates: Bool = false) -> ActivityInputDecisionDiagnostic? {
        var details = state.metadata
        details["snapshot_id"] = .string(state.stateID + ".snapshot")
        if includeCandidates {
            // Large rows are omitted, not truncated and called complete. Ranks
            // remain absolute positions in the actually published array.
            let values = zip(state.rows.indices, state.rows).compactMap { index, row in
                candidateValue(row, id: state.candidateIDs[index], rank: Int64(index))
            }
            details["candidates"] = .array(values); details["observed_count"] = .integer(Int64(values.count))
            details["coverage"] = .string("published_subset"); details["truncated"] = .bool(true)
        }
        if let selection {
            details["decision_id"] = .string(selection.decisionID)
            details["selected_candidate_id"] = .string(selection.candidateID); details["selected_rank"] = .integer(selection.rank)
            details["method"] = .string(selection.method)
            if let value = candidateValue(selection.candidate, id: selection.candidateID, rank: selection.rank) { details["selected_candidate"] = value }
            else {
                details["reason"] = .string("selected_text_too_large")
                details["filter_reason_counts"] = .object(["selected_text_too_large": .integer(1)])
            }
            if let id = selection.pressStateID { details["press_state_id"] = .string(id) }
            if let id = selection.releaseStateID { details["release_state_id"] = .string(id) }
            if let time = selection.pressUS { details["press_monotonic_us"] = .integer(time) }
            if let time = selection.releaseUS { details["release_monotonic_us"] = .integer(time) }
        }
        if let reason { details["reason"] = .string(reason) }
        if let outputEventID { details["output_event_id"] = .string(outputEventID.uuidString) }
        return try? ActivityInputDecisionDiagnostic(compositionID: state.compositionID, revision: state.revision, stateID: state.stateID,
            stage: stage, clockDomain: state.clockDomain, monotonicUS: nowUS, details: details)
    }
    private static func candidateValue(_ row: Candidate, id: String, rank: Int64) -> ActivityJSONValue? {
        guard row.text.utf8.count <= 256, row.reading.utf8.count <= 256 else { return nil }
        var value: [String: ActivityJSONValue] = ["candidate_id": .string(id), "text": .string(row.text), "absolute_rank": .integer(rank), "source": .string(row.source)]
        if !row.reading.isEmpty { value["reading"] = .string(row.reading) }
        return .object(value)
    }
}
