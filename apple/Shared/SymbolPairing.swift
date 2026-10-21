import Foundation

/// Call only for a deliberate symbol keystroke/tap. Committed candidates,
/// clipboard/shared text and pasted strings must use their existing raw path.
enum SymbolPairing {
    struct Plan: Equatable {
        let insertedText: String
        /// UTF-16 units after the desired caret; the supported closers are BMP.
        let caretBack: Int
    }
    static let pairs: [String: String] = [
        "(": ")", "（": "）", "[": "]", "【": "】", "{": "}",
        "《": "》", "〈": "〉", "「": "」", "『": "』",
        "“": "”", "‘": "’", "\"": "\""
    ]
    static func plan(for symbol: String, autoPair: Bool = true, caretInside: Bool = true) -> Plan {
        // Exact lookup also keeps multi-character strings and apostrophes raw.
        guard autoPair, let closing = pairs[symbol] else { return .init(insertedText: symbol, caretBack: 0) }
        return .init(insertedText: symbol + closing, caretBack: caretInside ? closing.utf16.count : 0)
    }
}
