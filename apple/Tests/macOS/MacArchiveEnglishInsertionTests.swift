import AppKit
import XCTest
import PrivateInputKit

private final class ArchiveEnglishFixtureClient: MacInputClient {
    var insertions: [String] = []
    var marks: [String] = []
    var paired: [(String, Int)] = []
    func insert(_ text: String) { insertions.append(text) }
    func insertPair(_ text: String, caretBack: Int) { paired.append((text, caretBack)) }
    func mark(_ text: String) { marks.append(text) }
    func mark(_ text: String, cursor: Int) { marks.append(text) }
    func surroundingText() -> SurroundingText? { SurroundingText(before: "synthetic before", after: "synthetic after") }
}

final class MacArchiveEnglishInsertionTests: XCTestCase {
    private func eligible() -> MacArchiveEnglishInsertion.State {
        .init(archiveEnabled: true, secureInput: false, english: true, sessionHandled: false,
              preeditBeforeEmpty: true, preeditAfterEmpty: true, insertedDuringSession: false,
              markedDuringSession: false, hostMarkedBefore: false, hostMarkedAfter: false)
    }
    func testPlainASCIIActualCaseShiftCapsSpaceAndPunctuationInsertExactlyOnce() {
        for (text, key, flags) in [("a", 0, 0), ("A", 0, Int(NSEvent.ModifierFlags.shift.rawValue)),
                                  ("A", 0, Int(NSEvent.ModifierFlags.capsLock.rawValue)), (" ", 49, 0),
                                  ("@", 19, Int(NSEvent.ModifierFlags.shift.rawValue)), (".", 47, 0),
                                  ("?", 44, Int(NSEvent.ModifierFlags.shift.rawValue)),
                                  ("9", 92, Int(NSEvent.ModifierFlags.numericPad.rawValue))] {
            var actual: [String] = []
            XCTAssertTrue(MacArchiveEnglishInsertion.insertIfEligible(text, keyCode: key, flags: flags, state: eligible()) { actual.append($0) })
            XCTAssertEqual(actual, [text])
        }
    }
    func testAllPrintableASCIIIsPreservedWithoutNormalizationOrAddedSpace() {
        var output = ""
        for byte in 32...126 {
            let text = String(UnicodeScalar(byte)!)
            XCTAssertTrue(MacArchiveEnglishInsertion.insertIfEligible(text, keyCode: 0, flags: 0, state: eligible()) { output += $0 })
        }
        XCTAssertEqual(Array(output.utf8), Array(32...126).map(UInt8.init))
    }
    func testAuthorizationSafetyLanguageAndCompositionEachBlockFallback() {
        let cases: [(String, (inout MacArchiveEnglishInsertion.State) -> Void)] = [
            ("archive off", {$0.archiveEnabled = false}), ("secure input", {$0.secureInput = true}),
            ("Chinese mode", {$0.english = false}), ("already consumed", {$0.sessionHandled = true}),
            ("composition before", {$0.preeditBeforeEmpty = false}), ("composition after", {$0.preeditAfterEmpty = false}),
            ("original insertion", {$0.insertedDuringSession = true}), ("original mark", {$0.markedDuringSession = true}),
            ("native mark before", {$0.hostMarkedBefore = true}), ("native mark after", {$0.hostMarkedAfter = true})
        ]
        for (name, configure) in cases {
            var state = eligible(), insertions = 0; configure(&state)
            XCTAssertFalse(MacArchiveEnglishInsertion.insertIfEligible("a", keyCode: 0, flags: 0, state: state) { _ in insertions += 1 }, name)
            XCTAssertEqual(insertions, 0, name)
        }
    }
    func testShortcutsFnHelpAndCombinationsStayNative() {
        for modifier in [NSEvent.ModifierFlags.command, .control, .option, .function, .help,
                         [.command, .shift], [.control, .option], [.function, .shift]] {
            var count = 0
            XCTAssertFalse(MacArchiveEnglishInsertion.insertIfEligible("A", keyCode: 0, flags: Int(modifier.rawValue), state: eligible()) { _ in count += 1 })
            XCTAssertEqual(count, 0)
        }
    }
    func testControlNavigationFunctionAndModeKeysCannotBecomePrintableFallback() {
        for key in [36, 48, 51, 53, 57, 63, 64, 71, 76, 96, 102, 104, 109, 114, 115, 116, 117, 119, 120, 121, 122, 123, 124, 125, 126, -1, 1000] {
            var count = 0
            XCTAssertFalse(MacArchiveEnglishInsertion.insertIfEligible("a", keyCode: key, flags: 0, state: eligible()) { _ in count += 1 }, String(key))
            XCTAssertEqual(count, 0)
        }
    }
    func testNonASCIIAccentsDeadKeyOrMultipleCharacterResultsStayNative() {
        for text: String? in [nil, "", "\t", "\n", "\r", "\u{0000}", "\u{007f}", "é", "e\u{301}", "´", "你好", "👨‍👩‍👧‍👦", "apple"] {
            var count = 0
            XCTAssertFalse(MacArchiveEnglishInsertion.insertIfEligible(text, keyCode: 0, flags: 0, state: eligible()) { _ in count += 1 })
            XCTAssertEqual(count, 0)
        }
    }
    func testMutationTrackerForwardsExactlyAndNeverRetainsTextForLogging() {
        let client = ArchiveEnglishFixtureClient(), tracker = MacArchiveMutationTrackingClient(base: client)
        tracker.insert("synthetic")
        XCTAssertTrue(tracker.inserted); XCTAssertFalse(tracker.marked); XCTAssertEqual(client.insertions, ["synthetic"])
        tracker.mark(""); tracker.mark("draft", cursor: 2)
        XCTAssertTrue(tracker.marked); XCTAssertEqual(client.marks, ["", "draft"])
        tracker.insertPair("()", caretBack: 1)
        XCTAssertEqual(client.paired.count, 1); XCTAssertEqual(client.paired[0].0, "()")
        XCTAssertEqual(tracker.surroundingText()?.before, "synthetic before")
    }
}
