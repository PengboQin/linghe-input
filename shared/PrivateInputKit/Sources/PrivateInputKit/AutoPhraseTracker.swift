import Foundation

/// Pairs a committed phrase with its full reading across segmented selections
/// (e.g. 灵 then 鹤) within one composition. Mirrors Android `AutoPhrase.Tracker`.
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
        guard !text.isEmpty, !trimmed.isEmpty else { broken = true; return }
        texts.append(text); readings.append(trimmed)
    }
    /// Full reading when `commit` is exactly the tracked selections; always resets.
    public mutating func committed(_ commit: String) -> String? {
        guard !commit.isEmpty else { return nil }
        defer { reset() }
        return !broken && !texts.isEmpty && commit == texts.joined() ? readings.joined(separator: " ") : nil
    }
    public mutating func reset() { texts = []; readings = []; broken = false }
}
