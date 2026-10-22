import Foundation
import PrivateInputKit

enum PersonalDataReset { static let generation = "initial"; static let marker = "privacy-reset-generation-v1.txt" }
struct LearningRefreshSource { let name: String; let url: URL; let maximum: Int; let runtime: Bool }
@main enum Check {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("linghe-cloud-seed-" + UUID().uuidString)
        let inbox = root.appendingPathComponent("Inbox"), shared = root.appendingPathComponent("Shared")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let policy = try CloudLearningTextPolicy(standardCharacters: Data(contentsOf: URL(fileURLWithPath: "resources/rime/charset/standard-8105.txt")))
        let source = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let seed = try JSONDecoder().decode(AppleCloudMigrationSeed.self, from: source)
        let file = inbox.appendingPathComponent(seed.producer.uuidString + ".json")
        try source.write(to: file)
        let count = try AppleCloudMigrationSeed.consume(inbox: inbox, group: seed.group, device: seed.device, personalEpoch: "initial", shared: shared, policy: policy)
        guard count == seed.entries.count, !FileManager.default.fileExists(atPath: file.path) else { throw InputDataError.invalidRecord }
        let rows = try AppleCloudProducerSnapshot.read(directory: shared)
        guard rows.count == 1, rows[0].entries.count == count,
              try CloudLearningComponents.digest(producer: seed.producer, records: rows[0].entries) == seed.componentDigest else { throw CloudLearningError.badHash }
        var assertions = 4
        func rejected(_ object: AppleCloudMigrationSeed) throws {
            try JSONEncoder().encode(object).write(to: file)
            do {
                _ = try AppleCloudMigrationSeed.consume(inbox: inbox, group: seed.group, device: seed.device, personalEpoch: "initial", shared: shared, policy: policy)
                throw NSError(domain: "unexpected-seed-acceptance", code: 1)
            } catch InputDataError.invalidRecord { assertions += 1 }
            guard FileManager.default.fileExists(atPath: file.path) else { throw InputDataError.invalidRecord }
        }
        try rejected(.init(version: 1, group: UUID(), device: seed.device, producer: seed.producer, personalEpoch: "initial", componentDigest: seed.componentDigest, entries: seed.entries))
        try rejected(.init(version: 1, group: seed.group, device: UUID(), producer: seed.producer, personalEpoch: "initial", componentDigest: seed.componentDigest, entries: seed.entries))
        try rejected(.init(version: 1, group: seed.group, device: seed.device, producer: seed.producer, personalEpoch: UUID().uuidString, componentDigest: seed.componentDigest, entries: seed.entries))
        try rejected(.init(version: 1, group: seed.group, device: seed.device, producer: seed.producer, personalEpoch: "initial", componentDigest: String(repeating: "0", count: 64), entries: seed.entries))
        var foreign = seed.entries
        if !foreign.isEmpty {
            foreign[0].counts[UUID().uuidString] = 5
            try rejected(.init(version: 1, group: seed.group, device: seed.device, producer: seed.producer, personalEpoch: "initial", componentDigest: CloudLearningComponents.digest(producer: seed.producer, records: foreign), entries: foreign))
        }
        // A late bootstrap cannot reduce a newer committed local component.
        if var latest = seed.entries.first {
            let original = latest.counts[seed.producer.uuidString] ?? 0
            latest.counts[seed.producer.uuidString] = original + 1
            try AppleCloudProducerSnapshot.publish([latest], producer: seed.producer, directory: shared)
            try AppleCloudProducerSnapshot.publish(seed.entries, producer: seed.producer, directory: shared)
            let actual = try AppleCloudProducerSnapshot.read(directory: shared)[0].entries.first { $0.id == latest.id }!
            guard actual.counts[seed.producer.uuidString] == original + 1 else { throw InputDataError.invalidRecord }; assertions += 1
        }
        print("{\"assertions\":\(assertions),\"entries\":\(count),\"onlyOwnCounter\":true,\"networkUsed\":false,\"originalSourceModified\":false,\"temporaryDerivedCopyRemoved\":true}")
    }
}
