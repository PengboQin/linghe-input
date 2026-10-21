import XCTest
@testable import PrivateInputKit

/// Synthetic v2 data only. No relay, disk store, real user profile or engine.
final class RecentLearningTests: XCTestCase {
    private let referenceDay = 20_700
    private var policy: RecentLearningPolicy { try! RecentLearningPolicy(referenceDay: referenceDay) }
    private let word = LearningEntry(reading: "ni hao", text: "你好")
    private func bytes(_ entries: [RecentLearningEntry]) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(RecentLearningArchive(entries: entries))
    }
    private func seeded(_ device: String, amount: UInt64, day: Int? = nil) throws -> RecentLearningModel {
        var model = RecentLearningModel()
        try model.recordLocalDelta(reading: word.reading, text: word.text, replica: device, amount: amount,
                                   trustedDay: day ?? referenceDay, policy: policy)
        return model
    }
    private func assertAtomicReject(_ incoming: Data, model: inout RecentLearningModel,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        let original = try model.export(policy: policy)
        XCTAssertThrowsError(try model.merge(incoming, policy: policy), file: file, line: line)
        XCTAssertEqual(try model.export(policy: policy), original, file: file, line: line)
    }
    func testThreeOfflineReplicasConvergeInEveryOrderAndRepeatedDelivery() throws {
        let snapshots = try [seeded("ios", amount: 2, day: referenceDay - 2),
                             seeded("mac", amount: 5, day: referenceDay - 1),
                             seeded("android", amount: 3)].map { try $0.export(policy: policy) }
        let orders = [[0,1,2], [0,2,1], [1,0,2], [1,2,0], [2,0,1], [2,1,0]]
        var expected: Data?
        for order in orders {
            var receiver = RecentLearningModel()
            for index in order + order.reversed() + order { try receiver.merge(snapshots[index], policy: policy) }
            let result = try receiver.export(policy: policy)
            if let expected { XCTAssertEqual(result, expected) } else { expected = result }
            let entry = try XCTUnwrap(receiver.entries[word.id])
            XCTAssertEqual(entry.word.frequency, 10)
            XCTAssertEqual(entry.buckets.count, 3)
            var echo = receiver; try echo.merge(result, policy: policy)
            XCTAssertEqual(try echo.export(policy: policy), result)
        }
    }
    func testEntryMergeAssociativeCommutativeAndIdempotentAcrossDays() throws {
        let a = try XCTUnwrap(seeded("ios", amount: 2, day: referenceDay - 2).entries[word.id])
        let b = try XCTUnwrap(seeded("mac", amount: 5, day: referenceDay - 1).entries[word.id])
        let c = try XCTUnwrap(seeded("android", amount: 3).entries[word.id])
        XCTAssertEqual(try a.merging(b, policy: policy), try b.merging(a, policy: policy))
        XCTAssertEqual(try a.merging(a, policy: policy), a)
        XCTAssertEqual(try a.merging(b, policy: policy).merging(c, policy: policy),
                       try a.merging(b.merging(c, policy: policy), policy: policy))
    }
    func testSameReplicaCumulativeSnapshotIsNotAddedTwiceAndLegacyNeverCreatesBuckets() throws {
        var model = try seeded("ios", amount: 2, day: referenceDay - 1)
        let early = try model.export(policy: policy)
        try model.recordLocalDelta(reading: word.reading, text: word.text, replica: "ios", amount: 3,
                                   trustedDay: referenceDay, policy: policy)
        let current = try model.export(policy: policy), legacy = try model.legacyProjection()
        for _ in 0..<3 { try model.merge(early, policy: policy); try model.mergeLegacy(legacy, policy: policy) }
        XCTAssertEqual(try model.export(policy: policy), current)
        var migration = RecentLearningModel(); try migration.mergeLegacy(legacy, policy: policy)
        XCTAssertEqual(migration.entries[word.id]?.word.frequency, 5)
        XCTAssertEqual(migration.entries[word.id]?.buckets, [])
        let first = try migration.export(policy: policy)
        try migration.mergeLegacy(legacy, policy: policy)
        XCTAssertEqual(try migration.export(policy: policy), first)
    }
    func testMalformedBatchDuplicateDayAndDuplicateEntryRejectAtomically() throws {
        var model = try seeded("ios", amount: 2)
        let good = RecentLearningEntry(word: .init(reading: "shi jie", text: "世界", counts: ["mac": 2]),
                                       buckets: [.init(day: referenceDay, counts: ["mac": 2])])
        var bad = good; bad.buckets.append(bad.buckets[0])
        try assertAtomicReject(bytes([good, bad]), model: &model)
        try assertAtomicReject(bytes([good, good]), model: &model)
        bad.buckets = [.init(day: referenceDay, counts: ["unknown": 1])]
        try assertAtomicReject(bytes([good, bad]), model: &model)
        bad.buckets = [.init(day: referenceDay, counts: ["mac": 3])]
        try assertAtomicReject(bytes([bad]), model: &model)
        try assertAtomicReject(Data("not-json".utf8), model: &model)
        var archive = RecentLearningArchive(entries: [good]); archive.algorithmVersion = 99
        try assertAtomicReject(JSONEncoder().encode(archive), model: &model)
    }
    func testByteLimitRejectsWireAndValidUnionWithoutMutation() throws {
        var model = try seeded("ios", amount: 2)
        try assertAtomicReject(Data(repeating: 0x20, count: RecentLearningModel.byteLimit + 1), model: &model)
        let prefix = String(repeating: "x", count: 600)
        let first = (0..<1500).map { RecentLearningEntry(word: .init(reading: "ni hao", text: prefix + String($0))) }
        let second = (1500..<3000).map { RecentLearningEntry(word: .init(reading: "ni hao", text: prefix + String($0))) }
        let left = try bytes(first), right = try bytes(second)
        XCTAssertLessThan(left.count, RecentLearningModel.byteLimit)
        XCTAssertLessThan(right.count, RecentLearningModel.byteLimit)
        model = RecentLearningModel(); try model.merge(left, policy: policy)
        try assertAtomicReject(right, model: &model)
    }
    func testComponentLimitAcceptsBoundaryThenRejectsValidUnionAtomically() throws {
        let replicas = (0..<64).map { "r\($0)" }
        let totals = Dictionary(uniqueKeysWithValues: replicas.map { ($0, UInt64(5)) })
        let daily = Dictionary(uniqueKeysWithValues: replicas.map { ($0, UInt64(1)) })
        // 125 words × 5 UTC days × 64 replica components = exactly 40,000.
        let entries = (0..<125).map { index in
            RecentLearningEntry(word: .init(reading: "ni hao", text: "Synthetic-\(index)", counts: totals),
                                buckets: (0..<5).map { .init(day: referenceDay - $0, counts: daily) })
        }
        let encoded = try bytes(entries)
        XCTAssertLessThan(encoded.count, RecentLearningModel.byteLimit)
        var model = RecentLearningModel(); try model.merge(encoded, policy: policy)
        XCTAssertEqual(model.entries.count, 125)
        let overflow = RecentLearningEntry(word: .init(reading: "ni hao", text: "overflow", counts: ["ios": 1]),
                                           buckets: [.init(day: referenceDay, counts: ["ios": 1])])
        try assertAtomicReject(bytes([overflow]), model: &model)
    }
    func testResetDeleteRestoreAndIndependentPinConvergeAcrossOfflineGeneration() throws {
        var reset = try seeded("ios", amount: 7), pinPeer = reset
        let old = try reset.export(policy: policy)
        try reset.resetFrequency(id: word.id, policy: policy)
        try pinPeer.setPinned(id: word.id, pinned: true, replica: "mac", policy: policy)
        let resetSnapshot = try reset.export(policy: policy), pinSnapshot = try pinPeer.export(policy: policy)
        try reset.merge(pinSnapshot, policy: policy); try pinPeer.merge(resetSnapshot, policy: policy)
        XCTAssertEqual(reset.entries, pinPeer.entries)
        XCTAssertEqual(reset.entries[word.id]?.word.frequency, 0)
        XCTAssertEqual(reset.entries[word.id]?.buckets, [])
        XCTAssertEqual(reset.entries[word.id]?.word.pinned, true)
        try reset.remove(id: word.id, policy: policy)
        try reset.merge(old, policy: policy)
        XCTAssertTrue(try XCTUnwrap(reset.entries[word.id]).word.deleted)
        XCTAssertNil(try reset.score(id: word.id, policy: policy))
        let deleted = try reset.export(policy: policy)
        try reset.recordLocalDelta(reading: word.reading, text: word.text, replica: "ios", amount: 4,
                                   trustedDay: referenceDay, policy: policy)
        XCTAssertEqual(try reset.export(policy: policy), deleted)
        try reset.restore(id: word.id, policy: policy); try reset.merge(deleted, policy: policy)
        XCTAssertFalse(try XCTUnwrap(reset.entries[word.id]).word.deleted)
        XCTAssertEqual(reset.entries[word.id]?.word.generation, 2)
        XCTAssertEqual(reset.entries[word.id]?.word.frequency, 0)
        XCTAssertTrue(try XCTUnwrap(reset.entries[word.id]).word.pinned)
    }
    func testPinVersionForkAndImpossibleBucketUnionRejectAtomically() throws {
        var model = try seeded("ios", amount: 2)
        var fork = try XCTUnwrap(model.entries[word.id]); fork.word.pinned = true
        try assertAtomicReject(bytes([fork]), model: &model)
        // Individually valid snapshots from one identity cannot claim two
        // different days' increments without cumulative evidence for both.
        var shifted = try XCTUnwrap(model.entries[word.id]); shifted.buckets[0].day -= 1
        try assertAtomicReject(bytes([shifted]), model: &model)
    }
    func testFutureAndExpiredBucketsCannotAdvanceCallerPolicyOrEvictCurrentUse() throws {
        var model = try seeded("ios", amount: 2)
        let future = RecentLearningEntry(word: .init(reading: word.reading, text: word.text, counts: ["mac": 9]),
                                          buckets: [.init(day: referenceDay + 90, counts: ["mac": 9])])
        let before = try XCTUnwrap(model.score(id: word.id, policy: policy)).recent
        try model.merge(bytes([future]), policy: policy)
        XCTAssertEqual(model.entries[word.id]?.buckets.count, 1)
        XCTAssertEqual(try XCTUnwrap(model.score(id: word.id, policy: policy)).recent, before)
        XCTAssertEqual(policy.referenceDay, referenceDay)
        let boundary = try RecentLearningEntry(word: .init(reading: "guo qu", text: "过去", counts: ["ios": 3]),
            buckets: [.init(day: referenceDay - 90, counts: ["ios": 1]),
                      .init(day: referenceDay - 89, counts: ["ios": 1]),
                      .init(day: referenceDay + 1, counts: ["ios": 1])]).normalized(policy)
        XCTAssertEqual(boundary.buckets.map(\.day), [referenceDay - 89])
    }
    func testClockUsesFullUTCSecondsAcrossMidnightAndWallClockNeverDatesUsage() throws {
        let anchor = Double(referenceDay * 86400 + 86399)
        var clock = try RecentLearningClock(authenticatedUnixSeconds: anchor, uptime: 10, bootSession: "boot-a")
        XCTAssertEqual(clock.day(wallUnixSeconds: anchor, uptime: 10, bootSession: "boot-a"), referenceDay)
        XCTAssertEqual(clock.day(wallUnixSeconds: anchor + 0.9, uptime: 10.9, bootSession: "boot-a"), referenceDay)
        XCTAssertEqual(clock.day(wallUnixSeconds: anchor + 1, uptime: 11, bootSession: "boot-a"), referenceDay + 1)
        // A wall clock behind by ten minutes cannot return the previous day.
        XCTAssertEqual(clock.day(wallUnixSeconds: anchor - 600, uptime: 12, bootSession: "boot-a"), referenceDay + 1)
    }
    func testClockRollbackRebootExpiryAndAnomalyRemainStickyAfterSerialization() throws {
        let anchor = Double(referenceDay * 86400)
        for mode in 0..<4 {
            var clock = try RecentLearningClock(authenticatedUnixSeconds: anchor, uptime: 10, bootSession: "boot-a")
            _ = clock.day(wallUnixSeconds: anchor + 10, uptime: 20, bootSession: "boot-a")
            switch mode {
            case 0: XCTAssertNil(clock.day(wallUnixSeconds: anchor + 9, uptime: 19, bootSession: "boot-a"))
            case 1: XCTAssertNil(clock.day(wallUnixSeconds: anchor + 11, uptime: 21, bootSession: "boot-b"))
            case 2: XCTAssertNil(clock.day(wallUnixSeconds: anchor + 604801, uptime: 604811, bootSession: "boot-a"))
            default: XCTAssertNil(clock.day(wallUnixSeconds: anchor + 100000, uptime: 21, bootSession: "boot-a"))
            }
            XCTAssertFalse(clock.trusted)
            clock = try JSONDecoder().decode(RecentLearningClock.self, from: JSONEncoder().encode(clock))
            XCTAssertNil(clock.day(wallUnixSeconds: anchor + 12, uptime: 22, bootSession: "boot-a"))
        }
        XCTAssertThrowsError(try RecentLearningClock(authenticatedUnixSeconds: .nan, uptime: 0, bootSession: "a"))
        XCTAssertThrowsError(try RecentLearningClock(authenticatedUnixSeconds: anchor, uptime: .infinity, bootSession: "a"))
    }
    func testSaturatingCountersUntrustedDatesAndLearningDisabled() throws {
        var model = RecentLearningModel()
        try model.recordLocalDelta(reading: word.reading, text: word.text, replica: "ios", amount: 999_999_999,
                                   trustedDay: nil, policy: policy)
        try model.recordLocalDelta(reading: word.reading, text: word.text, replica: "ios", amount: 8,
                                   trustedDay: referenceDay, policy: policy)
        try model.recordLocalDelta(reading: word.reading, text: word.text, replica: "ios", amount: 8,
                                   trustedDay: referenceDay, policy: policy)
        XCTAssertEqual(model.entries[word.id]?.word.frequency, 1_000_000_000)
        XCTAssertEqual(model.entries[word.id]?.buckets, [.init(day: referenceDay, counts: ["ios": 1])])
        let original = try model.export(policy: policy); model.learningEnabled = false
        try model.recordLocalDelta(reading: word.reading, text: word.text, replica: "mac", amount: 1,
                                   trustedDay: referenceDay, policy: policy)
        XCTAssertEqual(try model.export(policy: policy), original)
    }
    func testRecentHabitOutweighsOldTotalsButPinAndSpellingClassRemainSeparate() throws {
        var model = RecentLearningModel()
        let old = LearningEntry(reading: "dou xian", text: "窦宪", counts: ["mac": 1_000_000_000], pinned: true,
                                pinVersion: .init(sequence: 1, device: "mac"))
        try model.merge(bytes([.init(word: old)]), policy: policy)
        for _ in 0..<10 {
            try model.recordLocalDelta(reading: "dou xian", text: "都先", replica: "ios", amount: 1,
                                       trustedDay: referenceDay, policy: policy)
        }
        let a = try XCTUnwrap(model.score(id: old.id, policy: policy))
        let b = try XCTUnwrap(model.score(id: "dou xian\u{1f}都先", policy: policy))
        XCTAssertGreaterThan(b.total, a.total)
        XCTAssertTrue(a.pinned); XCTAssertFalse(b.pinned)
        XCTAssertEqual(a.historical, 0.2, accuracy: 0.000001)
        XCTAssertLessThanOrEqual(b.total, 1.0)
        XCTAssertEqual(try XCTUnwrap(model.score(id: "dou xian\u{1f}都先", policy: nil)).recent, 0)
        // The model returns only bounded within-class evidence. It has no
        // spelling-category field or ordering API that can promote a typo
        // across exact-spelling/prefix/category eligibility boundaries.
    }
    func testCheckpointBatchMatchesIndividualUpdatesAndRejectsInvalidTailAtomically() throws {
        let deltas: [RecentLearningDelta] = [
            .init(reading: word.reading, text: word.text, replica: "ios", amount: 2, trustedDay: referenceDay - 1),
            .init(reading: word.reading, text: word.text, replica: "ios", amount: 3, trustedDay: referenceDay),
            .init(reading: "shi jie", text: "世界", replica: "mac", amount: 4, trustedDay: nil)
        ]
        var batch = RecentLearningModel(), individually = RecentLearningModel()
        try batch.recordLocalDeltas(deltas, policy: policy)
        for delta in deltas {
            try individually.recordLocalDelta(reading: delta.reading, text: delta.text, replica: delta.replica,
                amount: delta.amount, trustedDay: delta.trustedDay, policy: policy)
        }
        let original = try batch.export(policy: policy)
        XCTAssertEqual(original, try individually.export(policy: policy))
        let invalid = RecentLearningDelta(reading: "bad-123", text: "invalid", replica: "mac", amount: 1, trustedDay: referenceDay)
        XCTAssertThrowsError(try batch.recordLocalDeltas(deltas + [invalid], policy: policy))
        XCTAssertEqual(try batch.export(policy: policy), original)
        let tooMany = Array(repeating: deltas[0], count: 5001)
        XCTAssertThrowsError(try batch.recordLocalDeltas(tooMany, policy: policy))
        XCTAssertEqual(try batch.export(policy: policy), original)
    }
    func testV2CannotAccidentallyPublishInCurrentLegacyLearningDomain() throws {
        let model = try seeded("ios", amount: 2)
        let v2 = try model.export(policy: policy), projected = try model.legacyProjection()
        XCTAssertThrowsError(try SecureMessage.validatePayload(v2, domain: .learning))
        XCTAssertNoThrow(try SecureMessage.validatePayload(projected, domain: .learning))
        var legacy = LearningModel()
        XCTAssertThrowsError(try legacy.merge(v2))
        XCTAssertNoThrow(try legacy.merge(projected))
        XCTAssertEqual(legacy.entries[word.id]?.frequency, 2)
    }
    func testClockDecodeCannotBypassInitializationOrRestoreForgedAnchors() throws {
        let anchor = Double(referenceDay * 86400)
        let clock = try RecentLearningClock(authenticatedUnixSeconds: anchor, uptime: 10, bootSession: "boot-a")
        let encoded = try JSONEncoder().encode(clock)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for (key, value) in [("anchorUnixSeconds", -1 as Any), ("anchorUptime", -1 as Any),
                             ("lastUptime", 9 as Any), ("bootSession", "" as Any)] {
            var forged = original; forged[key] = value
            let data = try JSONSerialization.data(withJSONObject: forged)
            XCTAssertThrowsError(try JSONDecoder().decode(RecentLearningClock.self, from: data), key)
        }
    }
    func testPinTieBreakAndUnpinAreIndependentFromFrequencyReset() throws {
        var a = try seeded("ios", amount: 3), b = a
        try a.setPinned(id: word.id, pinned: true, replica: "ios", policy: policy)
        try b.setPinned(id: word.id, pinned: false, replica: "mac", policy: policy)
        let left = try a.export(policy: policy), right = try b.export(policy: policy)
        try a.merge(right, policy: policy); try b.merge(left, policy: policy)
        XCTAssertEqual(a.entries, b.entries)
        XCTAssertFalse(try XCTUnwrap(a.entries[word.id]).word.pinned)
        XCTAssertEqual(a.entries[word.id]?.word.pinVersion, .init(sequence: 1, device: "mac"))
        try a.setPinned(id: word.id, pinned: true, replica: "ios", policy: policy)
        try b.resetFrequency(id: word.id, policy: policy)
        try b.merge(a.export(policy: policy), policy: policy)
        XCTAssertTrue(try XCTUnwrap(b.entries[word.id]).word.pinned)
        XCTAssertEqual(b.entries[word.id]?.word.frequency, 0)
    }
    func testGenerationAndPinCounterOverflowRejectWithoutMutation() throws {
        let maximum = RecentLearningEntry(word: .init(reading: word.reading, text: word.text,
            generation: UInt64.max, counts: ["ios": 1], pinVersion: .init(sequence: UInt64.max, device: "ios")),
            buckets: [.init(day: referenceDay, counts: ["ios": 1])])
        var model = RecentLearningModel(); try model.merge(bytes([maximum]), policy: policy)
        let before = try model.export(policy: policy)
        XCTAssertThrowsError(try model.resetFrequency(id: word.id, policy: policy))
        XCTAssertThrowsError(try model.setPinned(id: word.id, pinned: true, replica: "mac", policy: policy))
        XCTAssertEqual(try model.export(policy: policy), before)
        try model.remove(id: word.id, policy: policy)
        let deleted = try model.export(policy: policy)
        XCTAssertThrowsError(try model.restore(id: word.id, policy: policy))
        XCTAssertEqual(try model.export(policy: policy), deleted)
    }
    func testCapabilitiesRequireEveryAuthenticatedWriterAndUnknownWriterBlocksPublication() {
        let cap = Set([RecentLearningCompatibility.capability])
        XCTAssertTrue(RecentLearningCompatibility.canPublish(activeWriters: ["ios", "mac", "keyboard"],
                      authenticatedCapabilities: ["ios": cap, "mac": cap, "keyboard": cap]))
        XCTAssertFalse(RecentLearningCompatibility.canPublish(activeWriters: ["ios", "mac"], authenticatedCapabilities: ["ios": cap]))
        XCTAssertFalse(RecentLearningCompatibility.canPublish(activeWriters: [], authenticatedCapabilities: [:]))
        XCTAssertFalse(RecentLearningCompatibility.canPublish(activeWriters: [""], authenticatedCapabilities: ["": cap]))
    }
}
