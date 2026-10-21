import Foundation
import XCTest

final class SymbolPairingTests: XCTestCase {
    func testSupportedOpenersPairAndCenterOrKeepCaretAfterCloser() {
        for (opening, closing) in SymbolPairing.pairs {
            XCTAssertEqual(SymbolPairing.plan(for: opening), .init(insertedText: opening + closing, caretBack: closing.utf16.count))
            XCTAssertEqual(SymbolPairing.plan(for: opening, autoPair: true, caretInside: false), .init(insertedText: opening + closing, caretBack: 0))
        }
    }
    func testDisablingPairingAlwaysPreservesTheOriginalSymbol() {
        for opening in SymbolPairing.pairs.keys {
            for caret in [false, true] {
                XCTAssertEqual(SymbolPairing.plan(for: opening, autoPair: false, caretInside: caret), .init(insertedText: opening, caretBack: 0))
            }
        }
    }
    func testApostropheClosersAndMultiCharacterContentStayUntouched() {
        let raw = ["'", "don't", "it's", ")", "）", "]", "】", "}", "》", "〉", "」", "』", "”", "’", "()", "“文字”", "(共享文本)", "\n", "", "abc", "🙂"]
        for text in raw {
            XCTAssertEqual(SymbolPairing.plan(for: text), .init(insertedText: text, caretBack: 0), text)
        }
    }
}
