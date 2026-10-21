import Foundation

/// One containing-app session owns this gate. Synchronous state effects and
/// permission persistence use the same lock; network awaits never hold it.
/// Changing consent invalidates an old pass even if it is enabled again.
public final class SyncConsentGate {
    public struct Lease { fileprivate let revision: UUID }
    private let lock = NSLock()
    private var revision = UUID()
    private var consent: SyncConsent

    public init(_ consent: SyncConsent) { self.consent = consent }
    public func lease() -> Lease {
        lock.lock(); defer { lock.unlock() }
        return Lease(revision: revision)
    }
    public func update(_ value: SyncConsent, persist: () throws -> Void = {}) throws {
        lock.lock(); defer { lock.unlock() }
        try persist()
        consent = value; revision = UUID()
    }
    public func withLease<T>(_ lease: Lease, _ action: (SyncConsent) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard revision == lease.revision, consent.learning || consent.clipboard else {
            throw ReplicaStoreError.sharingDisabled
        }
        return try action(consent)
    }
}
