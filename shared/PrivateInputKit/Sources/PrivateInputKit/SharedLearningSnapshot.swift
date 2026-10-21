import Foundation
import Darwin

public enum SnapshotPublisher {
    case containingApp
    case keyboard(fullAccess: Bool)
    var canWrite: Bool {
        switch self { case .containingApp: return true; case .keyboard(let fullAccess): return fullAccess }
    }
}
public enum SnapshotStoreError: Error { case fullAccessRequired, busy }

// The platform supplies its app-owned/App Group directory and the actual
// hasFullAccess value. Reads never create files or write acknowledgment data.
public struct SharedLearningSnapshot {
    private let file: URL
    private let epoch:PersonalDataEpoch
    public init(directory: URL) { file = directory.appendingPathComponent("learning-v1.json");epoch=PersonalDataEpoch(directory:directory) }
    public func read() throws -> Data? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let maximum = 2 * 1024 * 1024
        var data = Data()
        while data.count <= maximum {
            let chunk = try handle.read(upToCount: min(65536, maximum + 1 - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= maximum else { throw InputDataError.oversized }
        var validation = LearningModel(); try validation.merge(data)
        return data
    }
    public func publish(_ data: Data, by publisher: SnapshotPublisher) throws {
        try epoch.requireCurrent()
        guard publisher.canWrite else { throw SnapshotStoreError.fullAccessRequired }
        var validation = LearningModel(); try validation.merge(data)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lock = file.deletingLastPathComponent().appendingPathComponent("learning-publication.lock")
        let descriptor = Darwin.open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw SnapshotStoreError.busy }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw SnapshotStoreError.busy }
        defer { flock(descriptor, LOCK_UN) }
        // Serialized CRDT merge prevents a containing app's late network response
        // from overwriting keyboard learning produced while it was awaiting IO.
        let existing=try read()
        if let existing { try validation.merge(existing) }
        let canonical = try validation.export()
        try epoch.requireCurrent()
        if canonical==existing { return }
        #if os(iOS)
        try canonical.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try canonical.write(to: file, options: .atomic)
        #endif
    }
}

public struct PersonalDataEpoch {
    private let file:URL
    private let captured:Data?
    public init(directory:URL) {file=directory.appendingPathComponent("privacy-reset-generation-v1.txt");captured=try? Data(contentsOf:file)}
    public func requireCurrent() throws {guard captured == (try? Data(contentsOf:file)) else {throw InputDataError.invalidRecord}}
}
