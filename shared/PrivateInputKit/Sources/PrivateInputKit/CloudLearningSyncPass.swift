import Foundation

public struct CloudLearningSyncResult {
    public let uploadedEvents, pulledPages: Int
    public let stagedModelVersion: UInt64
    public let hasMore: Bool
}

/// Explicit background work, not a timer or an enablement API. Platforms supply
/// the current independently consented scope and schedule a bounded pass after
/// an update hint/reconnect/idle opportunity. It never mutates a live engine.
public enum CloudLearningSyncPass {
    public static func run(store: CloudLearningReplicaStore, client: CloudLearningClient,
                           policy: CloudLearningTextPolicy, identity: DeviceIdentity, now: UInt64,
                           maxUploadBatches: Int = 2, maxPullPages: Int = 4) async throws -> CloudLearningSyncResult {
        guard (0...4).contains(maxUploadBatches), (1...8).contains(maxPullPages) else { throw CloudLearningError.invalid }
        var uploaded = 0, pages = 0, more = false
        for _ in 0..<maxUploadBatches {
            let state = try store.read()
            guard state.device == identity.device else { throw CloudLearningError.staleModel }
            let batch = state.pendingUpload()
            if batch.isEmpty { break }
            let receipt = try await client.ingest(batch, generation: state.generation, consentVersion: state.consentVersion,
                                                  installation: state.installation, policy: policy, group: state.group, identity: identity, now: now)
            // Persist before considering a received event delivered. Keep the
            // local overlay until a later model's aggregation watermark covers it.
            try store.transaction { try $0.receive(receipt, batch: batch) }
            uploaded += batch.count
        }
        for _ in 0..<maxPullPages {
            let state = try store.read()
            guard state.device == identity.device else { throw CloudLearningError.staleModel }
            let delta = try await client.pull(generation: state.generation, fromVersion: state.modelVersion,
                                               group: state.group, identity: identity, now: now)
            try store.transaction { try $0.stage(delta, policy: policy) }
            pages += 1; more = delta.hasMore
            if !more { break }
        }
        return .init(uploadedEvents: uploaded, pulledPages: pages, stagedModelVersion: try store.read().modelVersion, hasMore: more)
    }
}
