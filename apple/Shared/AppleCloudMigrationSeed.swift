import Foundation
import PrivateInputKit

/// An explicit local migration inbox, not a network/import attachment handler.
/// Only the currently verified device/group/reset scope can consume a seed.
/// Developer delivery may bridge this device's committed keyboard journal when
/// iOS does not grant a hidden-extension maintenance window. Originals remain.
struct AppleCloudMigrationSeed: Codable {
    let version: Int
    let group, device, producer: UUID
    let personalEpoch, componentDigest: String
    let entries: [LearningEntry]
    static func consume(inbox: URL, group: UUID, device: UUID, personalEpoch: String,
                        shared: URL, policy: CloudLearningTextPolicy) throws -> Int {
        guard FileManager.default.fileExists(atPath: inbox.path) else { return 0 }
        guard try inbox.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw InputDataError.invalidRecord }
        let files = try FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.isSymbolicLinkKey]).filter { $0.pathExtension == "json" }
        guard files.count <= 8 else { throw InputDataError.oversized }
        var count = 0
        for file in files {
            guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw InputDataError.invalidRecord }
            let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
            let data = try handle.read(upToCount: 4 * 1024 * 1024 + 1) ?? Data()
            guard data.count <= 4 * 1024 * 1024 else { throw InputDataError.oversized }
            let seed = try JSONDecoder().decode(Self.self, from: data)
            guard seed.version == 1, seed.group == group, seed.device == device,
                  seed.personalEpoch == personalEpoch, personalEpoch == PersonalDataReset.generation,
                  file.lastPathComponent == seed.producer.uuidString + ".json", seed.entries.count <= 5000,
                  Set(seed.entries.map(\.id)).count == seed.entries.count,
                  try CloudLearningComponents.digest(producer: seed.producer, records: seed.entries) == seed.componentDigest else { throw InputDataError.invalidRecord }
            for row in seed.entries {
                try row.validate()
                guard row.counts.count == 1, row.counts[seed.producer.uuidString] != nil,
                      policy.allowsTerm(row.text), row.reading.utf8.count <= 96,
                      row.reading.range(of: "^[a-z]+(?:[ '][a-z]+)*\\z", options: .regularExpression) != nil else { throw InputDataError.invalidRecord }
            }
            let barrier = PersonalDataEpoch(directory: shared); try barrier.requireCurrent()
            try AppleCloudProducerSnapshot.publish(seed.entries, producer: seed.producer, directory: shared, onlyIfAbsent: false)
            try barrier.requireCurrent()
            // Remove only this consumed disposable copy. The original Native
            // journal and the operator's verified recovery source are untouched.
            try FileManager.default.removeItem(at: file); count += seed.entries.count
        }
        return count
    }
}
