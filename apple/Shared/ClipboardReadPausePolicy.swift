/// A nil programmatic read does not expose the OS permission state. Pause only
/// a stable board which still advertises text; a cleared/changed board is not
/// evidence that the user should have to retry.
enum ClipboardReadPausePolicy {
    static func shouldPause(textIsNil:Bool,hasStringsBefore:Bool,versionBefore:Int,
                            versionAfter:Int,hasStringsAfter:Bool) -> Bool {
        textIsNil && hasStringsBefore && hasStringsAfter && versionBefore==versionAfter
    }
}
