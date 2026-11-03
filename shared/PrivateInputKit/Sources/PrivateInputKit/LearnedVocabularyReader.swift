import Foundation

/// One saved-vocabulary read with the exact reset credential captured before
/// the read. The UI must validate this same value after the background read;
/// re-capturing a fresh epoch on the main thread would only prove the file is
/// readable now, not that it was unchanged during the read.
public struct LearnedVocabularyReadResult {
    public let rows: [LearningEntry]
    public let published: Bool
    private let epoch: PersonalDataEpoch

    init(rows: [LearningEntry], published: Bool, epoch: PersonalDataEpoch) {
        self.rows = rows; self.published = published; self.epoch = epoch
    }

    public func requireCurrent() throws { try epoch.requireCurrent() }
}

public enum LearnedVocabularyReader {
    public static func read(directory: URL) throws -> LearnedVocabularyReadResult {
        let epoch = PersonalDataEpoch(directory: directory)
        let data = try SharedLearningSnapshot(directory: directory).read()
        let rows = try LearnedVocabularyProjection.rows(shared: data)
        try epoch.requireCurrent()
        return LearnedVocabularyReadResult(rows: rows, published: data != nil, epoch: epoch)
    }
}
