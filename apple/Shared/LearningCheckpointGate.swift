import Foundation

/// A successful native transaction is reusable only for the same complete
/// source token and local native generation. This helper owns no I/O or Rime.
struct LearningCheckpointGate {
    private(set) var mutation: UInt64 = 0
    private(set) var validationGeneration: UInt64 = 0
    private var clean: (generation: UInt64, fingerprint: String)?
    mutating func changed() { mutation &+= 1; invalidate() }
    mutating func invalidate() { validationGeneration &+= 1; clean = nil }
    func canReuse(fingerprint: String?, generation: UInt64, pending: Bool, forced: Bool) -> Bool {
        guard !pending,!forced,let fingerprint,let clean else {return false}
        return mutation == generation && clean.generation == generation && clean.fingerprint == fingerprint
    }
    /// Background postflight may race new input. It cannot make that input clean,
    /// nor acknowledge remote data which changed during the native transaction.
    mutating func checkpointSucceeded(generation: UInt64, validation: UInt64, beforeExternal: String?, afterExternal: String?, afterFingerprint: String?, pending: Bool) {
        guard validation == validationGeneration else {return}
        guard generation == mutation,!pending,let beforeExternal,let afterExternal,
              beforeExternal == afterExternal,let afterFingerprint else {invalidate();return}
        clean = (generation,afterFingerprint)
    }
}
