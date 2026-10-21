#if os(macOS)
import XCTest
@testable import PrivateInputKit

final class NativeRimeBridgeTests: XCTestCase {
    func testActualEngineLearningFlowsThroughPeerMergeAndImport() throws {
        guard let driver = ProcessInfo.processInfo.environment["PRIVATE_INPUT_ENGINE_DRIVER"], let resources = ProcessInfo.processInfo.environment["PRIVATE_INPUT_RIME_RESOURCES"] else {
            throw XCTSkip("Run scripts/test_rime_bridge.sh for the real native-engine fixture")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PrivateInput-Bridge-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let macDir = root.appendingPathComponent("mac"), iosDir = root.appendingPathComponent("ios")
        @discardableResult func run(_ directory: URL, _ args: [String]) throws -> String {
            let process = Process(); process.executableURL = URL(fileURLWithPath: driver)
            process.arguments = [resources, directory.path] + args
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
            try process.run(); let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, String(decoding: output, as: UTF8.self))
            return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try run(macDir, ["learn", "nihao", "你好"])
        for _ in 0..<12 { try run(iosDir, ["learn", "nihao", "拟好"]) }
        var mac = RimeLearningCheckpoint(), ios = RimeLearningCheckpoint()
        try mac.observeExport(Data(contentsOf: macDir.appendingPathComponent("checkpoint.tsv")), device: "mac")
        try ios.observeExport(Data(contentsOf: iosDir.appendingPathComponent("checkpoint.tsv")), device: "ios")
        try mac.mergeRemoteArchive(ios.outboundArchive())
        let plan = root.appendingPathComponent("merged.tsv");try mac.engineImport().write(to: plan)
        XCTAssertEqual(try run(macDir, ["import-rank", plan.path]), "拟好", "Peer preference must work before any new receiving-device learning")
        let imported = try Data(contentsOf: macDir.appendingPathComponent("checkpoint.tsv"))
        try mac.establishBaselineAfterImport(imported);try mac.observeExport(imported, device: "mac")
        XCTAssertEqual(mac.model.entries.values.first(where: { $0.text == "拟好" })?.counts["ios"], 12)
        XCTAssertNil(mac.model.entries.values.first(where: { $0.text == "拟好" })?.counts["mac"])
        try run(macDir, ["import", plan.path])
        XCTAssertEqual(try RimeLearningFormat.parseExport(Data(contentsOf: macDir.appendingPathComponent("checkpoint.tsv"))), try RimeLearningFormat.parseExport(imported))
        // A local choice after importing a peer is attributed only to this device.
        try run(macDir, ["learn", "nihao", "拟好"])
        try mac.observeExport(Data(contentsOf: macDir.appendingPathComponent("checkpoint.tsv")), device: "mac")
        let rare = try XCTUnwrap(mac.model.entries.values.first(where: { $0.text == "拟好" }))
        XCTAssertEqual(rare.counts["ios"], 12); XCTAssertEqual(rare.counts["mac"], 1)
        try run(iosDir, ["import", plan.path])
        XCTAssertEqual(try run(macDir, ["rank"]), "拟好", "Peer learning must change the actual receiving engine's preferred candidate")
    }
}
#endif
