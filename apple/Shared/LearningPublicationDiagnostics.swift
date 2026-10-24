import Foundation
import PrivateInputKit

/// Explicit containing-app diagnostic, never a keyboard/startup/timer job.
/// Fixed app-owned locations; output contains sizes/counts/check results only.
enum LearningPublicationDiagnostics {
    private static func failure(_ error: Error) -> String {
        switch error {
        case InputDataError.invalidRecord: return "invalidRecord"
        case InputDataError.incompatibleSchema: return "incompatibleSchema"
        case InputDataError.oversized: return "oversized"
        case InputDataError.duplicateEntry: return "duplicateEntry"
        case is DecodingError: return "decoding"
        default: return "unavailable"
        }
    }
    private static func bounded(_ url: URL, maximum: Int) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw InputDataError.invalidRecord }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw InputDataError.oversized }
        return data
    }
    static func report(directory: URL, epoch: String, build: String) -> [String: Any] {
        var output: [String: Any] = ["version": 1, "build": build, "countsAndValidationOnly": true,
                                     "networkOrNativeCalls": false, "sharedFilesModified": false, "readOnlyOnlineNotAtomic": true]
        var shared: [LearningEntry] = []
        do {
            let bytes = try bounded(directory.appendingPathComponent("learning-v1.json"), maximum: 2 * 1024 * 1024)
            var model = try LearningModel(capacityProfile: LearningCapacityProfiles.expanded10000); try model.merge(bytes); shared = Array(model.entries.values)
            output["shared"] = ["valid": true, "entries": shared.count, "bytes": bytes.count]
        } catch { output["shared"] = ["valid": false, "failure": failure(error)] }
        do {
            let value = try AppleRecencyBridge(directory: directory).read()
            output["recency"] = ["valid": true, "present": value != nil, "archiveBytes": value?.archive?.count ?? 0,
                                 "membershipEpoch": value?.epoch ?? 0, "anchorPresent": value?.anchor != nil,
                                 "anchorBootCurrent": value?.anchor.map { $0.boot == AppleRecencyBridge.bootSession } ?? false]
        } catch { output["recency"] = ["valid": false, "failure": failure(error)] }
        do {
            let folder = directory.appendingPathComponent("CloudLearningProducers")
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
            guard files.count <= 64 else { throw InputDataError.oversized }
            var reports: [[String: Any]] = []
            for file in files {
                var row: [String: Any] = [:]
                do {
                    let bytes = try bounded(file, maximum: 4 * 1024 * 1024)
                    let old = try JSONDecoder().decode(AppleCloudProducerSnapshot.self, from: bytes)
                    let owner = old.producer.uuidString
                    row["bytes"] = bytes.count; row["entries"] = old.entries.count
                    row["versionValid"] = (old.version == 1 || old.version == 2)
                    row["epochMatches"] = old.personalEpoch == epoch
                    row["fileOwnerMatches"] = UUID(uuidString: file.deletingPathExtension().lastPathComponent) == old.producer
                    row["withinEntryCapacity"] = old.entries.count <= LearningCapacityProfiles.expanded10000.producerTermRows
                    row["uniqueIDs"] = Set(old.entries.map(\.id)).count == old.entries.count
                    row["ownCounterShapeValid"] = old.entries.allSatisfy { $0.counts.count == 1 && $0.counts[owner] != nil }
                    var invalid = 0
                    for entry in old.entries { do { try entry.validate() } catch { invalid += 1 } }
                    row["invalidRows"] = invalid
                    func neutral(_ entry: LearningEntry) -> Bool {
                        entry.counts[owner, default: 0] == 0 && entry.generation == 0 && !entry.deleted && !entry.pinned &&
                            entry.pinVersion.sequence == 0 && entry.pinVersion.device.isEmpty
                    }
                    row["neutralZeroRows"] = old.entries.filter(neutral).count
                    if invalid == 0, Set(old.entries.map(\.id)).count == old.entries.count {
                        var merged = Dictionary(uniqueKeysWithValues: old.entries.map { ($0.id, $0) })
                        for entry in shared {
                            var own = entry; own.counts = [owner: entry.counts[owner, default: 0]]
                            merged[own.id] = try merged[own.id].map { try $0.merging(own) } ?? own
                        }
                        row["prospectiveUnionEntries"] = merged.count
                        row["prospectiveNeutralZeroRows"] = merged.values.filter(neutral).count
                        row["prospectiveNonNeutralEntries"] = merged.values.filter { !neutral($0) }.count
                    }
                } catch { row["failure"] = failure(error) }
                reports.append(row)
            }
            output["producers"] = reports
        } catch { output["producersFailure"] = failure(error) }
        return output
    }
    static func exportToContainingApp() throws {
        guard let directory = LocalLearningCoordinator.sharedDirectory() else { throw LearningSyncFailure.engineUnavailable }
        let payload = report(directory: directory, epoch: PersonalDataReset.generation,
                             build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")
        let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard bytes.count <= 65536 else { throw InputDataError.oversized }
        let output = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PrivateInputDiagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try bytes.write(to: output.appendingPathComponent("learning-publication-health-v1.json"),
                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
