import XCTest
@testable import PrivateInputKit

/// Offline, synthetic L1 comparison. It deliberately measures the journal
/// prepare step (one export observe + plan) and does not touch private data,
/// the app container, native Rime, or any device.
final class LearningPerformanceBenchmarkTests: XCTestCase {
    func testSyntheticObservationPlanComparison() throws {
        for count in [200, 6_000] {
            let (export, remote, before) = try fixture(count: count)
            var oldSamples: [Double] = [], newSamples: [Double] = []
            var oldValue: Data?, newValue: Data?
            for _ in 0..<3 {
                let old = try measure {
                    var journal = try LearningImportJournal(checkpoint: before)
                    let intent = try journal.prepare(finalLocalExport: export, remoteArchive: remote, device: "bench")
                    // The old observation path reparsed the same export for its
                    // count guard after prepare had already observed it.
                    _ = try RimeLearningFormat.parseExport(export, capacityProfile: before.capacityProfile)
                    return try intent.target.persistedData()
                }
                oldValue = old.value; oldSamples.append(old.elapsed)
                let new = try measure {
                    var observed = before
                    try observed.observeExport(export, device: "bench")
                    var journal = try LearningImportJournal(checkpoint: before)
                    let intent = try journal.prepare(observed: observed, remoteArchive: remote, device: "bench")
                    return try intent.target.persistedData()
                }
                newValue = new.value; newSamples.append(new.elapsed)
            }
            XCTAssertEqual(oldValue, newValue, "\(count) rows must produce the same plan")
            let oldMilliseconds = (oldSamples.min() ?? 0) * 1000
            let newMilliseconds = (newSamples.min() ?? 0) * 1000
            print("L1_SYNTHETIC rows=\(count) old_ms=\(String(format: "%.2f", oldMilliseconds)) new_ms=\(String(format: "%.2f", newMilliseconds))")
        }
    }

    private func fixture(count: Int) throws -> (Data, Data, RimeLearningCheckpoint) {
        var model = try LearningModel(capacityProfile: LearningCapacityProfiles.expanded10000)
        for index in 0..<count {
            try model.record(reading: "ci" + Self.letters(index), text: "词\(index)", device: "bench")
        }
        let export = try RimeLearningFormat.importTSV(from: model)
        let remote = try LearningModel(capacityProfile: LearningCapacityProfiles.expanded10000).export()
        let before = try RimeLearningCheckpoint(capacityProfile: LearningCapacityProfiles.expanded10000)
        return (export, remote, before)
    }

    private static func letters(_ value: Int) -> String {
        var value = value
        var result = ""
        repeat {
            result = String(UnicodeScalar(97 + value % 26)!) + result
            value /= 26
        } while value > 0
        return result
    }

    private func measure(_ body: () throws -> Data) rethrows -> (value: Data, elapsed: TimeInterval) {
        let start = ProcessInfo.processInfo.systemUptime
        let value = try body()
        return (value, ProcessInfo.processInfo.systemUptime - start)
    }
}

extension LearningPerformanceBenchmarkTests {
    func testSyntheticJournalStageBreakdown() throws {
        let (export, remote, before) = try fixture(count: 6_000)
        var observed = before
        var journal = try LearningImportJournal(checkpoint: before)
        let observeStart = ProcessInfo.processInfo.systemUptime
        try observed.observeExport(export, device: "bench")
        let observeMs = (ProcessInfo.processInfo.systemUptime - observeStart) * 1000
        let prepareStart = ProcessInfo.processInfo.systemUptime
        let intent = try journal.prepare(observed: observed, remoteArchive: remote, device: "bench")
        let prepareMs = (ProcessInfo.processInfo.systemUptime - prepareStart) * 1000
        let encodedStart = ProcessInfo.processInfo.systemUptime
        _ = try intent.target.persistedData()
        let encodedMs = (ProcessInfo.processInfo.systemUptime - encodedStart) * 1000
        let importStart = ProcessInfo.processInfo.systemUptime
        _ = try intent.nativeImportTSV()
        let importMs = (ProcessInfo.processInfo.systemUptime - importStart) * 1000
        let commitStart = ProcessInfo.processInfo.systemUptime
        try journal.commit(transactionID: intent.id, actualEngineExport: export)
        let commitMs = (ProcessInfo.processInfo.systemUptime - commitStart) * 1000
        let outboundStart = ProcessInfo.processInfo.systemUptime
        _ = try journal.outboundArchive()
        let outboundMs = (ProcessInfo.processInfo.systemUptime - outboundStart) * 1000
        print("L1_STAGES observe_ms=\(fmt(observeMs)) prepare_ms=\(fmt(prepareMs)) persisted_ms=\(fmt(encodedMs)) import_ms=\(fmt(importMs)) outbound_ms=\(fmt(outboundMs)) commit_ms=\(fmt(commitMs))")
    }
    private func fmt(_ value: Double) -> String { String(format: "%.2f", value) }
}
