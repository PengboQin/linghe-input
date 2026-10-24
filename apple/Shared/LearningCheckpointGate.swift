import Foundation

/// Effective authorization state, not a renewable lease's timestamp.
/// Each validation still computes expiry against the current wall clock.
enum LearningRefreshConsentContext {
    static func make(sharing:Bool,departed:String,deadline:Double,now:Double,
                     cloud:Bool,group:String,epoch:UInt64)->String {
        "\(sharing)|\(departed)|leased:\(deadline>0)|expired:\(deadline>0 && now>=deadline)|cloud:\(cloud)|\(group)|\(epoch)"
    }
}

/// Process-wide UI generations are held by the keyboard controller on main.
/// A retained hidden owner cannot commit across another controller appearing.
/// This is an additional cancellation fence, never a maintenance grant itself.
struct LearningPresentationFence {
    private(set) var generation: UInt64 = 0
    mutating func advance() { generation &+= 1 }
    func permits(_ captured: UInt64) -> Bool { generation == captured }
}

/// Native dictionary export/import cannot be interrupted safely. An empty
/// composition while the keyboard is visible is not a maintenance window: the
/// next touch may already be on its way. Only a completed dismissal grants a
/// token, and revealing the keyboard invalidates every outstanding token.
struct LearningMaintenanceBoundary {
    private enum Phase { case visible, dismissing, hidden }
    private var phase = Phase.visible
    private var generation: UInt64 = 0
    mutating func willAppear() { generation &+= 1; phase = .visible }
    /// UIKit may repeat this callback before or after didDisappear. Only an
    /// actual visible-to-dismissing transition owns teardown; duplicates must
    /// not invalidate a completed hidden grant or its queued preparation.
    @discardableResult mutating func willDisappear() -> Bool {
        guard phase == .visible else { return false }
        generation &+= 1; phase = .dismissing; return true
    }
    mutating func didDisappear() -> UInt64? {
        guard phase == .dismissing else {return nil}
        phase = .hidden; return generation
    }
    func permits(_ token: UInt64, hasComposition: Bool, interacting: Bool) -> Bool {
        phase == .hidden && token == generation && !hasComposition && !interacting
    }
}

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
