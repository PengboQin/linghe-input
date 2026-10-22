import XCTest
@testable import PrivateInputKit

final class LearningDeltaPublicationTests: XCTestCase {
    func testBootstrapChangeRetryAndResetConverge() throws {
        let group = UUID(); var source = LearningModel(), peer = LearningModel()
        for index in 0..<100 {
            try source.record(reading: "ci", text: "词\(index)", device: "a")
        }
        let full = try source.export()
        let initial = try LearningDeltaPublication.prepare(archive: full, group: group, epoch: 1, previous: nil)
        XCTAssertTrue(initial.bootstrap); XCTAssertEqual(initial.changedEntries, 100)
        try peer.merge(XCTUnwrap(initial.payload))
        let unchanged = try LearningDeltaPublication.prepare(archive: full, group: group, epoch: 1, previous: initial.checkpoint)
        XCTAssertNil(unchanged.payload)
        try source.record(reading: "ci", text: "词1", device: "a")
        let change = try LearningDeltaPublication.prepare(archive: source.export(), group: group, epoch: 1, previous: initial.checkpoint)
        XCTAssertEqual(change.changedEntries, 1)
        XCTAssertLessThan(try XCTUnwrap(change.payload).count * 10, full.count)
        try peer.merge(XCTUnwrap(change.payload)); try peer.merge(XCTUnwrap(change.payload))
        XCTAssertEqual(try source.export(), try peer.export())
        try source.resetFrequency(reading: "ci", text: "词1")
        let reset = try LearningDeltaPublication.prepare(archive: source.export(), group: group, epoch: 1, previous: change.checkpoint)
        try peer.merge(XCTUnwrap(reset.payload)); try peer.merge(XCTUnwrap(change.payload))
        XCTAssertEqual(peer.entries["ci\u{001F}词1"]?.frequency, 0)
        source.remove(id: "ci\u{001F}词1")
        let remove = try LearningDeltaPublication.prepare(archive: source.export(), group: group, epoch: 1, previous: reset.checkpoint)
        try peer.merge(XCTUnwrap(remove.payload))
        XCTAssertEqual(peer.entries["ci\u{001F}词1"]?.deleted, true)
    }

    func testContextChangesBootstrapAndSilentLossRejected() throws {
        let group = UUID(); var model = LearningModel()
        try model.record(reading: "ren", text: "人", device: "a")
        let first = try LearningDeltaPublication.prepare(archive: model.export(), group: group, epoch: 1, previous: nil)
        XCTAssertTrue(try LearningDeltaPublication.prepare(archive: model.export(), group: group, epoch: 2, previous: first.checkpoint).bootstrap)
        XCTAssertTrue(try LearningDeltaPublication.prepare(archive: model.export(), group: UUID(), epoch: 1, previous: first.checkpoint).bootstrap)
        XCTAssertThrowsError(try LearningDeltaPublication.prepare(archive: LearningModel().export(), group: group, epoch: 1, previous: first.checkpoint))
    }
}
