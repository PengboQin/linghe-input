import Foundation
import CryptoKit
import PrivateInputKit
#if os(macOS)
import AppKit
import Carbon
#else
import UIKit
#endif

struct AutomaticClipboardSession {
    let scope:String,device:UUID,clips:[ReceivedClipboard]
    let outgoingPending:Bool
}
/// Shared App/keyboard receipt adapter. Permission stays with the caller; the
/// departure generation is checked inside the background transaction as well.
enum AppleClipboardOnce {
    static var generation:String {UserDefaults(suiteName:LocalLearningCoordinator.groupID)?.string(forKey:"clipboard-once-reset-generation") ?? "initial"}
    static func claim(_ kind:ClipboardOnceReceipts.Kind,texts:[String],generation:String)throws->[Bool] {
        guard let root=LocalLearningCoordinator.sharedDirectory() else {throw ClipboardOnceError.unavailable}
        return try ClipboardOnceReceipts(directory:root).claim(kind,texts:texts,validating:{Self.generation==generation})
    }
}
@MainActor protocol AutomaticClipboardBoard {
    var version:Int {get}
    var automaticWriteAllowed:Bool {get}
    var automaticReadAllowed:Bool {get}
    func diagnosticMetadata()->(itemCount:Int,hasStrings:Bool)
    func readText()->String?
    func writeText(_ text:String)->Bool
}
extension AutomaticClipboardBoard {var automaticWriteAllowed:Bool {true};var automaticReadAllowed:Bool {true};func diagnosticMetadata()->(itemCount:Int,hasStrings:Bool) {(-1,false)}}
@MainActor struct NativeAutomaticClipboardBoard:AutomaticClipboardBoard {
    func diagnosticMetadata()->(itemCount:Int,hasStrings:Bool) {
        #if os(iOS)
        let board=UIPasteboard.general;return (board.numberOfItems,board.hasStrings)
        #else
        return (-1,false)
        #endif
    }
    var version:Int {
        #if os(macOS)
        NSPasteboard.general.changeCount
        #else
        UIPasteboard.general.changeCount
        #endif
    }
    var automaticReadAllowed:Bool {
        UserDefaults(suiteName:LocalLearningCoordinator.groupID)?.bool(forKey:"automatic-clipboard-read-paused") != true
    }
    // A paused programmatic read is not a revoked receive consent. Metadata,
    // newer local versions and failed reads of a new local copy remain fenced.
    // Copy-source labels do not veto readable text; OS access and actual text
    // availability still decide whether the native board can participate.
    var automaticWriteAllowed:Bool {
        #if os(macOS)
        guard !IsSecureEventInputEnabled() else{return false}
        let board=NSPasteboard.general
        if #available(macOS 15.4,*),board.accessBehavior == .alwaysDeny {return false}
        let types=board.types ?? []
        // Item-count inspection can itself require access on Mac. Use only
        // existing type/permission metadata here, never readObjects/body access.
        return types.isEmpty || board.availableType(from:[.string]) != nil
        #else
        let board=UIPasteboard.general
        return board.numberOfItems==0 || (board.numberOfItems==1 && board.hasStrings)
        #endif
    }
    func readText()->String? {
        let started=ProcessInfo.processInfo.systemUptime
        defer {KeyboardRuntimeDiagnostics.recordSlow(.clipboardReadSlow,startedUptime:started)}
        #if os(macOS)
        guard !IsSecureEventInputEnabled() else{return nil}
        let board=NSPasteboard.general
        return board.string(forType:.string)
        #else
        let board=UIPasteboard.general
        let prefs=UserDefaults(suiteName:LocalLearningCoordinator.groupID)
        guard prefs?.bool(forKey:"automatic-clipboard-read-paused") != true else{return nil}
        let observedVersion=board.changeCount,hasStrings=board.hasStrings
        guard hasStrings else{return nil}
        let value=board.string
        // There is no public permission-state getter. A stable unavailable
        // string read is paused; a changed/cleared board is not a refusal.
        let hasStringsAfter=board.hasStrings,versionAfter=board.changeCount
        if ClipboardReadPausePolicy.shouldPause(textIsNil:value==nil,hasStringsBefore:hasStrings,versionBefore:observedVersion,versionAfter:versionAfter,hasStringsAfter:hasStringsAfter) {
            prefs?.set(true,forKey:"automatic-clipboard-read-paused")
            ClipboardCacheCoordinator.recordMarkerReadPause(source:"automatic-board",version:observedVersion,hasStrings:hasStringsAfter)
        }
        return value
        #endif
    }
    func writeText(_ text:String)->Bool {
        let started=ProcessInfo.processInfo.systemUptime
        defer {KeyboardRuntimeDiagnostics.recordSlow(.clipboardWriteSlow,startedUptime:started)}
        #if os(macOS)
        guard !IsSecureEventInputEnabled() else{return false}
        NSPasteboard.general.clearContents();return NSPasteboard.general.setString(text,forType:.string)
        #else
        let board=UIPasteboard.general,before=board.changeCount
        board.setItems([["public.utf8-plain-text":text]],options:[.localOnly:true])
        return board.changeCount != before
        #endif
    }
}
/// One MainActor owner arbitrates its real pasteboard and one bounded sync pass.
/// Callers supply OS-active permission; this class never requests broad access.
@MainActor final class AutomaticClipboardBridge {
    struct Upload {let scope:String,text:String,digest:String}
    private let board:any AutomaticClipboardBoard
    private var state=AutomaticClipboardState()
    private var pending:Upload?
    private var token:AutomaticClipboardState.Pass?
    private var currentScope:String?
    private var metadataReadGate=ClipboardMetadataReadGate()
    private var finishEpoch=UUID()
    init(board:(any AutomaticClipboardBoard)?=nil) {self.board=board ?? NativeAutomaticClipboardBoard()}
    private func markerDiagnostic(_ stage:String,session:AutomaticClipboardSession,pass:AutomaticClipboardState.Pass?=nil,selected:UUID?=nil,deliveryFresh:Bool?=nil,writeSucceeded:Bool?=nil,validating:()->Bool={true}) {
        #if os(iOS)
        guard ClipboardCacheCoordinator.markerProbeActive else{return}
        let current=board.version,d=state.diagnosticStatus(version:current),metadata=board.diagnosticMetadata()
        var fields:[String:Any] = ["writeAllowed":board.automaticWriteAllowed,"readAllowed":board.automaticReadAllowed,
            "itemCount":metadata.itemCount,"hasStrings":metadata.hasStrings,"boardVersion":current,
            "stateArmed":d.armed,"currentPassLocalActivity":pass?.diagnosticLocalActivity ?? d.localActivity,
            "changedVersion":pass.map{$0.version != current} ?? !d.versionMatches,"outgoingPending":session.outgoingPending,
            "pendingLocal":d.pendingLocal,"localReadBlocked":d.localReadBlocked,"selectedNil":selected==nil,
            "contextValid":validating() && !Task.isCancelled]
        if let deliveryFresh {fields["deliveryFresh"]=deliveryFresh}
        if let writeSucceeded {fields["writeSucceeded"]=writeSucceeded}
        ClipboardCacheCoordinator.recordMarkerDecision(clips:session.clips,stage:stage,fields:fields)
        #endif
    }
    static func digest(_ text:String)->String {SHA256.hash(data:Data(text.utf8)).map{String(format:"%02x",$0)}.joined()}
    static func valid(_ text:String)->Bool {!text.isEmpty && !text.contains("\0") && text.utf8.count<=65536}
    func requestReadRetry() {state.requestReadRetry()}
    func pause() {token=nil;finishEpoch=UUID()}
    func suspend() {state.configure(scope:nil,version:0);pending=nil;token=nil;currentScope=nil;metadataReadGate=ClipboardMetadataReadGate();finishEpoch=UUID()}
    func prepare(_ session:AutomaticClipboardSession?,importPending:Bool=true)->Upload? {
        guard let session else{suspend();return nil}
        markerDiagnostic("before-prepare",session:session)
        let version=board.version
        if currentScope != session.scope {pending=nil;currentScope=session.scope}
        state.configure(scope:session.scope,version:version)
        let writeAllowed=board.automaticWriteAllowed,readAllowed=board.automaticReadAllowed
        guard board.version==version else{return pending}
        if metadataReadGate.observe(scope:session.scope,version:version,allowed:writeAllowed && readAllowed) {state.requestReadRetry()}
        let claimed=state.claimLocalRead(version:version)
        if !writeAllowed {state.observeLocalRead(version:version,readable:false)}
        else if claimed && !readAllowed {
            // Protect a changed, unread local copy. A pre-existing baseline
            // needs no read and must still accept a later authorized arrival.
            state.observeLocalRead(version:version,readable:false)
        } else if claimed {
            let text=board.readText()
            guard board.version==version else{return pending}
            let readable=text.map(Self.valid) ?? false
            state.observeLocalRead(version:version,readable:readable)
            if let text,readable {
                #if os(iOS)
                ClipboardCacheCoordinator.rememberPreview(text:text,scope:session.scope,version:version,generation:AppleClipboardOnce.generation,now:UInt64(Date().timeIntervalSince1970))
                #endif
                let digest=Self.digest(text)
                if !AutomaticClipboardOrigin.matches(scope:session.scope,version:version,digest:digest),state.stageLocal(digest:digest) {pending=Upload(scope:session.scope,text:text,digest:digest)}
            }
        }
        #if os(iOS)
        if importPending,pending==nil,let queued=try? ClipboardCacheCoordinator.pendingAutomatic(scope:session.scope,version:version,now:UInt64(Date().timeIntervalSince1970)),state.stageLocal(digest:queued.digest) {
            pending=Upload(scope:session.scope,text:queued.text,digest:queued.digest)
        }
        #endif
        markerDiagnostic("after-prepare",session:session)
        return pending
    }
    func queued(_ upload:Upload,clearSharedPending:Bool=true) {
        guard pending?.scope==upload.scope,pending?.digest==upload.digest else{return}
        state.outgoingDurablyQueued(digest:upload.digest);pending=nil
        #if os(iOS)
        if clearSharedPending {ClipboardCacheCoordinator.clearAutomaticPending(scope:upload.scope,digest:upload.digest)}
        #endif
    }
    func begin() {finishEpoch=UUID();token=state.begin(version:board.version)}
    func finish(_ session:AutomaticClipboardSession?,received:Int,now:UInt64,validating:()->Bool={true}) async {
        guard let session,currentScope==session.scope else{suspend();return}
        guard let token else{return}
        self.token=nil
        #if os(iOS)
        defer {UserDefaults(suiteName:LocalLearningCoordinator.groupID)?.set(state.armed,forKey:"automatic-clipboard-receive-ready")}
        #endif
        let currentVersion=board.version
        _ = automaticWriteAllowed(for:currentVersion)
        let rows=session.clips.map{AutomaticClipboardState.Remote(id:$0.id,sender:$0.sender,digest:Self.digest($0.text),expiresAt:$0.expiresAt)}
        markerDiagnostic("before-finish",session:session,pass:token,validating:validating)
        let selected=state.finish(token,currentVersion:board.version,remote:rows,received:received,ownDevice:session.device,now:now,outgoingPending:session.outgoingPending)
        markerDiagnostic("selection",session:session,pass:token,selected:selected,validating:validating)
        // Consume all observed remote contents, including cold-start history,
        // expired or unsafe-to-apply rows. They must not replay after relaunch.
        let observed=session.clips.filter{$0.sender != session.device && Self.valid($0.text)}
        let epoch=finishEpoch,generation=AppleClipboardOnce.generation
        let fresh=await Task.detached(priority:.utility) {
            try? AppleClipboardOnce.claim(.delivery,texts:observed.map(\.text),generation:generation)
        }.value
        let selectedFresh=selected.flatMap{ id in observed.firstIndex(where:{$0.id==id}) }.flatMap{ i in fresh.flatMap{$0.indices.contains(i) ? $0[i]:nil} }
        markerDiagnostic("receipt-gate",session:session,pass:token,selected:selected,deliveryFresh:selectedFresh,validating:validating)
        guard !Task.isCancelled,finishEpoch==epoch,currentScope==session.scope,validating(),AppleClipboardOnce.generation==generation,
              let selected,let index=observed.firstIndex(where:{$0.id==selected}),let fresh,fresh.indices.contains(index),fresh[index],
              automaticWriteAllowed(for:token.version) else{return}
        let clip=observed[index]
        guard clip.expiresAt>UInt64(Date().timeIntervalSince1970) else{return}
        let current=board.version,digest=Self.digest(clip.text)
        if let origin=AutomaticClipboardOrigin.receivedOrigin(version:current,text:clip.text),
           origin.event==clip.eventID,origin.sender==clip.sender {
            // Another authorized owner already applied this exact event. Keep
            // our local arbitration current without writing the board again.
            state.wroteRemote(version:current,digest:digest);return
        }
        guard board.version==current else{return}
        // The receipt is durable before write. A failed write is deliberately
        // not replayed; explicit shared-text history/paste remains available.
        let wrote=board.writeText(clip.text)
        markerDiagnostic("write-result",session:session,pass:token,selected:selected,deliveryFresh:true,writeSucceeded:wrote,validating:validating)
        guard wrote else{return}
        let version=board.version
        state.wroteRemote(version:version,digest:digest)
        AutomaticClipboardOrigin.record(scope:session.scope,version:version,digest:digest,event:clip.eventID,sender:clip.sender)
        #if os(iOS)
        ClipboardCacheCoordinator.rememberPreview(text:clip.text,scope:session.scope,version:version,generation:generation,now:now,source:.receivedWrite)
        ClipboardCacheCoordinator.recordMarkerSystemWrite(text:clip.text,version:version)
        #endif
        ActivityArchiveCapture.shared.noteSyncedClipboardWrite(version:version,event:clip.eventID,sender:clip.sender)
    }
    /// Metadata is sampled between version fences. Persist a stable refusal at
    /// every write checkpoint, including a copy newer than the current pass.
    private func automaticWriteAllowed(for version:Int)->Bool {
        guard board.version==version else{return false}
        let allowed=board.automaticWriteAllowed
        guard board.version==version else{return false}
        if let scope=currentScope,metadataReadGate.observe(scope:scope,version:version,allowed:allowed && board.automaticReadAllowed) {state.requestReadRetry()}
        if !allowed {state.observeLocalRead(version:version,readable:false)}
        return allowed
    }
    var initializing:Bool {currentScope != nil && !state.armed}
}

/// Shared metadata suppresses echoes between containing app and keyboard.
/// It carries no clipboard body, server endpoint, identity key or group key.
enum AutomaticClipboardOrigin {
    private struct Marker:Codable {let scope:String,version:Int,digest:String,event:UUID,sender:UUID}
    private static var file:URL? {LocalLearningCoordinator.sharedDirectory()?.appendingPathComponent("automatic-clipboard-origin-v1.json")}
    static func matches(scope:String,version:Int,digest:String)->Bool {
        guard let file,let data=try? Data(contentsOf:file),data.count<=4096,let marker=try? JSONDecoder().decode(Marker.self,from:data) else{return false}
        return marker.scope==scope && marker.version==version && marker.digest==digest
    }
    static func receivedOrigin(version:Int,text:String)->(event:UUID,sender:UUID)? {
        guard let file,let data=try? Data(contentsOf:file),data.count<=4096,
              let marker=try? JSONDecoder().decode(Marker.self,from:data),marker.version==version,
              let scope=UserDefaults(suiteName:LocalLearningCoordinator.groupID)?.string(forKey:"automatic-clipboard-scope"),marker.scope==scope else{return nil}
        let digest=SHA256.hash(data:Data(text.utf8)).map{String(format:"%02x",$0)}.joined()
        return marker.digest==digest ? (marker.event,marker.sender):nil
    }
    static func record(scope:String,version:Int,digest:String,event:UUID,sender:UUID) {
        guard let file,let data=try? JSONEncoder().encode(Marker(scope:scope,version:version,digest:digest,event:event,sender:sender)) else{return}
        try? data.write(to:file,options:.atomic);try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    static func clear() {if let file {try? FileManager.default.removeItem(at:file)}}
}
