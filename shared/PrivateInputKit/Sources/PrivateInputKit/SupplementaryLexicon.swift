import Foundation

/// OS-provided supplements remain in RAM. They are never exported or learned
/// as personal entries merely by being offered as candidates.
public struct SupplementaryLexicon {
    public struct Entry: Equatable {
        public let trigger, text: String
        public init(trigger: String, text: String) { self.trigger = trigger; self.text = text }
    }
    public let entries: [Entry]
    private let letters: [String:[Entry]]
    private let numbers: [String:[Entry]]
    public init(pairs: [(input: String, text: String)]) {
        var seen = Set<String>(), result: [Entry] = []
        for pair in pairs.prefix(4096) {
            guard !pair.input.isEmpty, pair.input.count <= 128, !pair.text.isEmpty, pair.text.count <= 256,
                  !pair.text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }) else { continue }
            let latin = pair.input.applyingTransform(.toLatin, reverse: false) ?? pair.input
            let normalized = latin.lowercased().decomposedStringWithCanonicalMapping
                .replacingOccurrences(of: "u\u{0308}", with: "v", options: .literal)
                .applyingTransform(.stripDiacritics, reverse: false) ?? latin.lowercased()
            let parts = normalized.split(whereSeparator: { $0.isWhitespace || $0 == "'" }).map(String.init)
            let trigger = parts.joined(separator: " ")
            guard (2...64).contains(trigger.count), parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (97...122).contains($0) }) }),
                  seen.insert(trigger + "\u{0}" + pair.text).inserted else { continue }
            result.append(Entry(trigger: trigger, text: pair.text))
        }
        entries = result
        letters=Dictionary(grouping:result,by:{$0.trigger.replacingOccurrences(of:" ",with:"")})
        numbers=Dictionary(grouping:result,by:{NineKeySpelling.encode($0.trigger) ?? ""})
    }
    public func matches(input: String, nineKey: Bool) -> [Entry] {
        let source = input.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: " ", with: "").lowercased()
        guard !source.isEmpty else { return [] }
        let locked = input.split(separator: "'").prefix { $0.utf8.allSatisfy({ (97...122).contains($0) }) }.map(String.init)
        let pool = nineKey ? (numbers[NineKeySpelling.rawCode(source) ?? ""] ?? []):(letters[source] ?? [])
        return Array(pool.lazy.filter { entry in
            if nineKey {
                guard NineKeySpelling.rawCode(source) == NineKeySpelling.encode(entry.trigger) else { return false }
                return locked.isEmpty || Array(entry.trigger.split(separator: " ").prefix(locked.count).map(String.init)) == locked
            }
            return source == entry.trigger.replacingOccurrences(of: " ", with: "")
        }.prefix(16))
    }
}
