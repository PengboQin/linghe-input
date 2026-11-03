import XCTest
import PrivateInputKit

/// L1 offline pipeline benchmark. It uses only a temporary directory and
/// synthetic entries; it never opens the user App Group, Rime database or
/// network. Run with `xcodebuild test -only-testing:PrivateInput-MacInputTests/LearningPerformanceBenchmarkTests`.
final class LearningPerformanceBenchmarkTests: XCTestCase {
    func testSyntheticObservationPipeline() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("PrivateInput-L1-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let coordinator = try LocalLearningCoordinator(base: base, rankingPreferences: nil)
        let export = try Self.syntheticExport(count: 6_000)
        let prepareStart = ProcessInfo.processInfo.systemUptime
        let prepared = try XCTUnwrap(try coordinator.prepareObservation(exported: export, allowDatedLearning: false))
        let prepareMilliseconds = (ProcessInfo.processInfo.systemUptime - prepareStart) * 1000

        let persistStart = ProcessInfo.processInfo.systemUptime
        _ = try coordinator.persistObservation(prepared)
        let persistMilliseconds = (ProcessInfo.processInfo.systemUptime - persistStart) * 1000

        let publishStart = ProcessInfo.processInfo.systemUptime
        try coordinator.publishObservation(prepared, by: .containingAppLocal)
        let publishMilliseconds = (ProcessInfo.processInfo.systemUptime - publishStart) * 1000

        let noChangeStart = ProcessInfo.processInfo.systemUptime
        let noChange = try coordinator.prepareObservation(exported: export, allowDatedLearning: false)
        let noChangeMilliseconds = (ProcessInfo.processInfo.systemUptime - noChangeStart) * 1000
        XCTAssertNil(noChange, "identical export must take the no-change path")
        let changed = try coordinator.prepareObservation(exported: try Self.syntheticExport(count: 6_001), allowDatedLearning: false)
        XCTAssertNotNil(changed, "a real new row must not be hidden by the no-change path")

        print("L1_PIPELINE rows=6000 prepare_ms=\(String(format: "%.2f", prepareMilliseconds)) persist_ms=\(String(format: "%.2f", persistMilliseconds)) publish_ms=\(String(format: "%.2f", publishMilliseconds)) no_change_ms=\(String(format: "%.2f", noChangeMilliseconds)) export_bytes=\(export.count)")
    }

    private static func syntheticExport(count: Int) throws -> Data {
        var model = try LearningModel(capacityProfile: LearningCapacityProfiles.expanded10000)
        for index in 0..<count {
            try model.record(reading: "ci" + letters(index), text: "词\(index)", device: "bench")
        }
        return try RimeLearningFormat.importTSV(from: model)
    }

    private static func letters(_ value: Int) -> String {
        var value = value, result = ""
        repeat { result = String(UnicodeScalar(97 + value % 26)!) + result; value /= 26 } while value > 0
        return result
    }
}
