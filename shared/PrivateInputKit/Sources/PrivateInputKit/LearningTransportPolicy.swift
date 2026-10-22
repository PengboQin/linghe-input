import Foundation

/// The new component/model lane replaces frequent v2 full-state exchange after
/// a verified migration. Keep one independent daily compatibility repair. v1
/// word deltas, personal phrases, clipboard and archive use their own budgets.
public enum LearningTransportPolicy {
    public static let compatibilityInterval: UInt64 = 86400
    public static let cloudLease: UInt64 = 7 * 86400
    public static func cloudIsCurrent(now: UInt64, verifiedAt: UInt64?, scopeMatches: Bool, enabled: Bool) -> Bool {
        guard enabled, scopeMatches, let verifiedAt, now >= verifiedAt else { return false }
        return now - verifiedAt < cloudLease
    }
    public static func legacyCompatibilityDue(now: UInt64, lastSuccess: UInt64?, cloudCurrent: Bool) -> Bool {
        guard cloudCurrent, let lastSuccess, now >= lastSuccess else { return true }
        return now - lastSuccess >= compatibilityInterval
    }
}
