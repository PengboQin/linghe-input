import Foundation
import CryptoKit
import PrivateInputKit

struct LearningRefreshSource {
    let name: String
    let url: URL
    let maximum: Int
    let runtime: Bool
}
struct LearningRefreshStamp: Equatable {
    let exists: Bool
    let size: UInt64
    let inode: UInt64
    let modified: Date?
    static func read(_ url: URL) throws -> Self {
        do {
            let a = try FileManager.default.attributesOfItem(atPath:url.path)
            guard a[.type] as? FileAttributeType == .typeRegular else {throw InputDataError.invalidRecord}
            return .init(exists:true,size:(a[.size] as? NSNumber)?.uint64Value ?? 0,
                         inode:(a[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,modified:a[.modificationDate] as? Date)
        } catch let e as NSError where e.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError,NSFileReadNoSuchFileError].contains(e.code) {
            return .init(exists:false,size:0,inode:0,modified:nil)
        }
    }
}
struct LearningRefreshRequest {
    let owner: UUID
    let generation: UInt64
    var validationGeneration: UInt64 = 0
    let context: String
    let sources: [LearningRefreshSource]
}
struct LearningRefreshPreparation {
    let request: LearningRefreshRequest
    let fingerprint: String?
    let externalFingerprint: String?
    let stamps: [LearningRefreshStamp]?
    let pending: Bool
    let validUntilUptime: Double?
    /// An unreadable/invalid source is never accepted as an empty clean source.
    static func unavailable(_ request: LearningRefreshRequest) -> Self {
        .init(request:request,fingerprint:nil,externalFingerprint:nil,stamps:nil,pending:true,validUntilUptime:nil)
    }
}
enum LearningRefreshReader {
    private struct Runtime: Decodable {
        let version: Int
        let journal: Data
        let recency: RecencyCoordinator.Persisted
        let group: UUID?
        let membershipEpoch: UInt64?
    }
    static func evaluate(_ request: LearningRefreshRequest) -> LearningRefreshPreparation {
        do {
            var stamps:[LearningRefreshStamp]=[],all=[request.context],external=[request.context]
            var pending=false,hasRuntime=false,validUntil:Double?
            for source in request.sources {
                let before=try LearningRefreshStamp.read(source.url)
                let digest:String
                if before.exists {
                    guard before.size <= UInt64(source.maximum) else {throw InputDataError.oversized}
                    let data=try Data(contentsOf:source.url)
                    guard data.count <= source.maximum else {throw InputDataError.oversized}
                    if source.runtime {
                        let runtime=try JSONDecoder().decode(Runtime.self,from:data)
                        guard runtime.version==2 else {throw InputDataError.incompatibleSchema}
                        pending = try LearningImportJournal.restore(runtime.journal).pending != nil
                        _ = try RecencyCoordinator(persisted:runtime.recency)
                        hasRuntime=true
                    }
                    if source.name == "shared-v2" {
                        let state=try JSONDecoder().decode(AppleRecencyBridge.State.self,from:data)
                        guard state.version==1 else {throw InputDataError.incompatibleSchema}
                        let policy=try state.policy
                        if let archive=state.archive {var model=RecentLearningModel();try model.merge(archive,policy:policy)}
                        let uptime=ProcessInfo.processInfo.systemUptime
                        var valid=false
                        if let anchor=state.anchor,let boot=AppleRecencyBridge.bootSession,boot==anchor.boot,
                           uptime>=anchor.uptime,uptime<=anchor.uptime+7*86400 {
                            var clock=try RecentLearningClock(authenticatedUnixSeconds:anchor.unixSeconds,uptime:anchor.uptime,bootSession:anchor.boot)
                            valid=clock.day(wallUnixSeconds:Date().timeIntervalSince1970,uptime:uptime,bootSession:boot) != nil
                            if valid {validUntil=anchor.uptime+7*86400}
                        }
                        all.append("authenticated-clock-current:\(valid)");external.append("authenticated-clock-current:\(valid)")
                    }
                    digest=SHA256.hash(data: data).map{String(format:"%02x",$0)}.joined()
                } else {digest="absent"}
                let after=try LearningRefreshStamp.read(source.url)
                guard before==after else {throw SnapshotStoreError.busy}
                stamps.append(after);all.append(source.name+":"+digest)
                if !source.runtime && source.name != "legacy-local" {external.append(source.name+":"+digest)}
            }
            let hash:([String])->String = { SHA256.hash(data:Data($0.joined(separator:"\n").utf8)).map{String(format:"%02x",$0)}.joined() }
            return .init(request:request,fingerprint:hash(all),externalFingerprint:hash(external),stamps:stamps,pending:pending || !hasRuntime,validUntilUptime:validUntil)
        } catch {return .unavailable(request)}
    }
    static func unchangedFiles(_ preparation: LearningRefreshPreparation) -> Bool {
        guard let stamps=preparation.stamps,stamps.count==preparation.request.sources.count else {return false}
        return zip(preparation.request.sources,stamps).allSatisfy { (try? LearningRefreshStamp.read($0.0.url)) == $0.1 }
    }
}
