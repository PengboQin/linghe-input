import Foundation

/// Ephemeral permission to reopen only our own most recent complete commit.
/// Anchors are hashes computed by the platform adapter, never host paragraphs.
public struct RecentCommit {
    public struct Draft: Equatable {
        public let text, input, context: String
        public let nineKey: Bool
    }
    private var draft: Draft?
    private var document = "", before = "", after = ""
    private var timestamp: TimeInterval = 0
    public init() {}
    public mutating func invalidate() { draft = nil }
    public mutating func stage(document: String?, before: String?, after: String?, text: String, input: String, context: String, nineKey: Bool, time: TimeInterval) {
        invalidate()
        guard let document, !document.isEmpty, let before,
              !text.isEmpty, text.count <= 64, !input.isEmpty, input.count <= 128,
              input.utf8.allSatisfy({ (97...122).contains($0) || (50...57).contains($0) || $0 == 39 }) else { return }
        self.document = document; self.before = before; self.after = after ?? "unavailable"; timestamp = time
        draft = Draft(text: text, input: input, context: context, nineKey: nineKey)
    }
    public func available(document: String?, before: String?, after: String?, suffix: String?, hasSelection: Bool, time: TimeInterval) -> Draft? {
        guard let draft, document == self.document, before == self.before, (after ?? "unavailable") == self.after,
              suffix == draft.text, !hasSelection, time >= timestamp, time - timestamp <= 120 else { return nil }
        return draft
    }
    public var text: String? { draft?.text }
}
