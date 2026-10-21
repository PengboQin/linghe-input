import AppKit
import PrivateInputKit

/// Gate only the original session's unconsumed, plain-ASCII English path.
/// It does not infer committed text from a key: the supplied insert closure
/// performs the normal IMK insertion, which owns the existing archive callback.
enum MacArchiveEnglishInsertion {
    struct State {
        var archiveEnabled: Bool
        var secureInput: Bool
        var english: Bool
        var sessionHandled: Bool
        var preeditBeforeEmpty: Bool
        var preeditAfterEmpty: Bool
        var insertedDuringSession: Bool
        var markedDuringSession: Bool
        var hostMarkedBefore: Bool
        var hostMarkedAfter: Bool
    }
    static func insertIfEligible(_ text: String?, keyCode: Int, flags: Int, state: State,
                                 insert: (String) -> Void) -> Bool {
        guard state.archiveEnabled, !state.secureInput, state.english, !state.sessionHandled,
              state.preeditBeforeEmpty, state.preeditAfterEmpty, !state.insertedDuringSession,
              !state.markedDuringSession, !state.hostMarkedBefore, !state.hostMarkedAfter else { return false }
        let modifiers = NSEvent.ModifierFlags(rawValue: UInt(bitPattern: flags))
        let native = NSEvent.ModifierFlags([.command, .control, .option, .function, .help])
        guard modifiers.intersection(native).isEmpty, printablePhysicalKey(keyCode),
              let text, text.utf8.count == 1, let byte = text.utf8.first, (32...126).contains(byte) else { return false }
        // Preserve the event's actual case/Shift/Caps/keyboard-layout output.
        // No normalization, predicted replacement, extra space, or separate log write.
        insert(text)
        return true
    }
    private static func printablePhysicalKey(_ key: Int) -> Bool {
        // ANSI/ISO printable positions, space, and keypad printable positions.
        // Return/Tab/Escape/Delete/arrows/Home/End/Page/F-keys/modifiers/input-mode
        // keys are deliberately absent, even if an unexpected ASCII string arrives.
        (0...35).contains(key) || (37...47).contains(key) || key == 49 || key == 50 ||
        [65, 67, 69, 75, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92, 93, 94, 95].contains(key)
    }
}

/// Track effects, not text. A session that inserted a commit or touched marked
/// composition must never receive a second fallback insertion for the same event.
final class MacArchiveMutationTrackingClient: MacInputClient {
    let base: any MacInputClient
    private(set) var inserted = false
    private(set) var marked = false
    init(base: any MacInputClient) { self.base = base }
    func insert(_ text: String) { inserted = true; base.insert(text) }
    func insertPair(_ text: String, caretBack: Int) { inserted = true; base.insertPair(text, caretBack: caretBack) }
    func mark(_ text: String) { marked = true; base.mark(text) }
    func mark(_ text: String, cursor: Int) { marked = true; base.mark(text, cursor: cursor) }
    func surroundingText() -> SurroundingText? { base.surroundingText() }
    func correctionAnchor(expectedSuffix: String) -> MacInputAnchor? { base.correctionAnchor(expectedSuffix: expectedSuffix) }
}
