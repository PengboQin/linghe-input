import Foundation
import XCTest
@testable import PrivateInputKit

final class ActivityDecisionDiagnosticTests: XCTestCase {
    private func fixture() throws -> [[String: Any]] {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let url = root.appendingPathComponent("server/activity_archive/fixtures/decision-chain-v1.json")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [String: Any])?["cases"] as? [[String: Any]])
    }
    private func extensions(_ event: [String: Any]) throws -> [String: ActivityJSONValue] {
        let data = try JSONSerialization.data(withJSONObject: event["extensions"] ?? [:])
        return try JSONDecoder().decode([String: ActivityJSONValue].self, from: data)
    }
    func testSameGoldenAsPython() throws {
        let cases = try fixture()
        XCTAssertEqual(cases.count, 46)
        for item in cases {
            let event = try XCTUnwrap(item["event"] as? [String: Any]), ext = try extensions(event)
            let valid = try XCTUnwrap(item["valid"] as? Bool), name = try XCTUnwrap(item["name"] as? String)
            do {
                try ActivityInputDecisionDiagnostic.validateEnvelope(provider: event["provider_id"] as! String,
                    eventType: ActivityEventType(rawValue: event["event_type"] as! String)!,
                    sourceKind: event["source_kind"] as? String,
                    confirmation: ActivityCommitConfirmation(rawValue: event["commit_confirmation"] as! String)!, extensions: ext)
                XCTAssertTrue(valid, name)
            } catch { XCTAssertFalse(valid, name) }
        }
    }
    func testConstructorAndUnobservedCandidateSelection() throws {
        let sample = try ActivityInputDecisionDiagnostic(compositionID: "composition-synthetic", revision: 3,
            stateID: "state-3", stage: "selection", clockDomain: "clock-synthetic", monotonicUS: 100,
            details: ["selected_candidate": .object(["candidate_id": .string("candidate-31"),
                "text": .string("公开合成候选"), "reading": .string("gong kai he cheng hou xuan"),
                "absolute_rank": .integer(31), "source": .string("unknown")])])
        XCTAssertNil(sample.fields["total_count"])
        XCTAssertNil(sample.fields["output_event_id"])
        XCTAssertEqual(sample.fields["stage"], .string("selection"))
        XCTAssertThrowsError(try ActivityInputDecisionDiagnostic(compositionID: "x", revision: -1,
            stateID: "s", stage: "candidates", clockDomain: "c", monotonicUS: 0))
    }
    func testQueueIndependentConsentReserveAndRevocation() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Decision-Synthetic-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let queue = try ActivityLocalEventQueue(file: folder.appendingPathComponent("archive.sqlite"), group: UUID(), device: UUID())
        let detail = try ActivityInputDecisionDiagnostic(compositionID: "composition-synthetic", revision: 3,
            stateID: "state-3", stage: "marked_text", clockDomain: "clock-synthetic", monotonicUS: 100)
        let draft = ActivityEventDraft(providerID: ActivityInputDiagnostic.provider, eventType: .sourceImport,
            text: "444", inputSession: "session-synthetic", editorEpoch: "epoch-synthetic", sourceKind: "ime_diagnostic",
            commitConfirmation: .notApplicable, extensions: [ActivityInputDecisionDiagnostic.extensionKey: detail.extensionValue])
        var config = ActivityConfiguration(enabled: true, endpoint: URL(string: "https://synthetic.example.invalid")!,
            providers: ["ime.commit.v1"], consentVersion: 1, maxQueueEvents: 8)
        var lease = try queue.configure(config)
        XCTAssertThrowsError(try queue.capture(draft, safety: .safe, lease: lease))
        XCTAssertEqual(try queue.status().lastSequence, 0)
        config.providers.insert(ActivityInputDiagnostic.provider); config.consentVersion = 2
        lease = try queue.configure(config)
        for _ in 0..<6 { _ = try queue.capture(draft, safety: .safe, lease: lease) }
        XCTAssertThrowsError(try queue.capture(draft, safety: .safe, lease: lease)) { XCTAssertEqual($0 as? ActivityError, .quotaExceeded) }
        let output = ActivityEventDraft(providerID: "ime.commit.v1", eventType: .inputCommit, text: "合成输出",
            commitConfirmation: .insertRequested, extensions: ["org.linghe.decision-link.v1": .object(["composition_id": .string("composition-synthetic")])])
        _ = try queue.capture(output, safety: .safe, lease: lease)
        config.providers.remove(ActivityInputDiagnostic.provider); config.consentVersion = 3
        _ = try queue.configure(config)
        XCTAssertThrowsError(try queue.capture(draft, safety: .safe, lease: lease)) { XCTAssertEqual($0 as? ActivityError, .staleAuthorization) }
        XCTAssertEqual(try queue.status().lastSequence, 7)
    }
}
