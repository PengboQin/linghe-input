import Foundation

/// Read-only projection for the "learned vocabulary" settings page.
///
/// This never opens a native engine, copies a running Rime database, writes a
/// learning archive, or performs network work. Sources are merged with the
/// existing CRDT rules so a newer deletion is never resurrected by an older
/// snapshot, and the same device counter is not added twice.
public enum LearnedVocabularyProjection {
    public static func rows(shared: Data?, checkpoint: Data? = nil,
                            query: String = "",
                            capacityProfile: LearningCapacityProfile = LearningCapacityProfiles.expanded10000) throws -> [LearningEntry] {
        var model = try LearningModel(capacityProfile: capacityProfile)
        if let shared { try model.merge(shared) }
        if let checkpoint { try model.merge(checkpoint) }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.entries.values
            .filter { !$0.deleted && ($0.frequency > 0 || $0.pinned) }
            .filter { entry in
                guard !needle.isEmpty else { return true }
                return entry.text.localizedCaseInsensitiveContains(needle)
                    || entry.reading.localizedCaseInsensitiveContains(needle)
            }
            .sorted {
                if $0.frequency != $1.frequency { return $0.frequency > $1.frequency }
                return $0.id < $1.id
            }
    }
}
