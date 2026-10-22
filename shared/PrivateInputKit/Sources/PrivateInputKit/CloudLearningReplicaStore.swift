import Foundation
import Darwin

/// Use from a utility owner, never a key/touch callback. One shared file lock
/// serializes containing-app / extension transactions; network awaits stay out.
public struct CloudLearningReplicaStore {
    private let file, lock: URL
    private let scope: CloudLearningReplica
    private let epoch: PersonalDataEpoch
    public init(directory: URL, activatedReplica: CloudLearningReplica) {
        file = directory.appendingPathComponent("cloud-learning-replica-v1.json")
        lock = directory.appendingPathComponent("cloud-learning-replica-v1.lock")
        scope = activatedReplica; epoch = PersonalDataEpoch(directory: directory)
    }
    private func matches(_ other: CloudLearningReplica) -> Bool {
        other.group == scope.group && other.device == scope.device && other.installation == scope.installation &&
            other.generation == scope.generation && other.consentVersion == scope.consentVersion
    }
    public func read() throws -> CloudLearningReplica {
        try epoch.requireCurrent()
        guard FileManager.default.fileExists(atPath: file.path) else { return scope }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        let data = try handle.read(upToCount: 4 * 1024 * 1024 + 1) ?? Data()
        let result = try CloudLearningReplica.restore(data)
        guard matches(result) else { throw CloudLearningError.staleModel }; return result
    }
    /// No silent migration across a group, installation or consent change.
    /// Explicit activation/retirement is owned by the platform coordinator.
    @discardableResult
    public func transaction<T>(_ change: (inout CloudLearningReplica) throws -> T) throws -> T {
        try epoch.requireCurrent()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw SnapshotStoreError.busy }; defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw SnapshotStoreError.busy }
        defer { flock(descriptor, LOCK_UN) }
        var state = try read(); let result = try change(&state)
        guard matches(state) else { throw CloudLearningError.staleModel }
        let data = try state.persistedData(); try epoch.requireCurrent()
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: file, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return result
    }
}
