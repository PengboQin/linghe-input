import Foundation

/// A new device group or membership-key epoch needs the cumulative snapshot
/// again, even when the local words themselves have not changed.
public enum LearningPublication {
    public static func needed(digest:Data,group:UUID,epoch:UInt64,
                              previousDigest:Data?,previousGroup:UUID?,previousEpoch:UInt64?) -> Bool {
        previousDigest != digest || previousGroup != group || previousEpoch != epoch
    }
}
