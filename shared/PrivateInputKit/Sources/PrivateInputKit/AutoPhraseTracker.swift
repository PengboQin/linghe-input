import Foundation

/// Pairs a committed phrase with its full reading across segmented selections
/// (e.g. 灵 then 鹤) within one composition. Mirrors Android `AutoPhrase.Tracker`.
public enum PhraseLearningText {
    /// Auto phrase rows must not carry emoji presentation/ZWJ/variation
    /// selectors. The host still commits the original text; only the lexicon
    /// and its cross-device key are kept free of invisible concatenation.
    public static func isStorable(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf16.count <= 256 else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            if value == 0x200D || value == 0xFE0E || value == 0xFE0F || value == 0x20E3 { return false }
            if (0x1F000...0x1FAFF).contains(value) || (0x2600...0x27BF).contains(value) ||
               (0x1F1E6...0x1F1FF).contains(value) || (0x1F3FB...0x1F3FF).contains(value) { return false }
            return !CharacterSet.controlCharacters.contains(scalar)
        }
    }
}

public struct AutoPhraseTracker {
    private var texts: [String] = []
    private var readings: [String] = []
    private var broken = false
    public init() {}
    /// Records one candidate choice; `prefix` is the text already selected before it.
    public mutating func selected(prefix: String, text: String, reading: String) {
        let trimmed = reading.trimmingCharacters(in: .whitespaces)
        if prefix.isEmpty { reset() }
        else if broken || prefix != texts.joined() { broken = true; return }
        guard !text.isEmpty, !trimmed.isEmpty, PhraseLearningText.isStorable(text) else { broken = true; return }
        texts.append(text); readings.append(trimmed)
    }
    /// Full reading when `commit` is exactly the tracked selections; always resets.
    public mutating func committed(_ commit: String) -> String? {
        guard !commit.isEmpty else { return nil }
        defer { reset() }
        guard !broken, !texts.isEmpty, commit == texts.joined(), PhraseLearningText.isStorable(commit) else { return nil }
        return readings.joined(separator: " ")
    }
    public mutating func reset() { texts = []; readings = []; broken = false }
}
