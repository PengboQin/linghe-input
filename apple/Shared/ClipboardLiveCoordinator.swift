import Foundation
import PrivateInputKit

extension Notification.Name {static let clipboardLiveUpdated=Notification.Name("PrivateInputClipboardLiveUpdated")}

/// A visible keyboard and the containing app use the same encrypted store and
/// short lease. No input callback waits for Keychain, disk, DNS or a network call.
@MainActor final class ClipboardLiveCoordinator {
    static let shared=ClipboardLiveCoordinator()
    private var bridge=AutomaticClipboardBridge()
    private var task:Task<Void,Never>?
    private var epoch=UUID()
    private var nextPoll=Date.distantPast
    private var retryAfter=Date.distantPast
    private var observedVersion:Int?
    private var currentScope:String?
    private var failures=0
    private var supportedEndpoint:URL?
    private var pendingReadRetryScope:String?
    private var observedReadRetry=UserDefaults(suiteName:LocalLearningCoordinator.groupID)?.string(forKey:"clipboard-live-read-retry-generation")
    private(set) var isActive=false
    private func authorized(scope:String,validating:()->Bool)->Bool {
        let p=UserDefaults(suiteName:LocalLearningCoordinator.groupID)
        return validating() && p?.bool(forKey:"clipboard-sharing-enabled")==true &&
            p?.bool(forKey:"automatic-clipboard-enabled")==true &&
            p?.string(forKey:"automatic-clipboard-scope")==scope &&
            p?.string(forKey:"clipboard-live-ready-scope")==scope
    }
    func suspend() {
        epoch=UUID();task?.cancel();task=nil;isActive=false
        bridge.pause()
    }
    /// A normal explicit UI retry applies before the next prepare/begin, never
    /// by mutating arbitration while an authenticated network pass is in flight.
    func requestReadRetry(preferences:UserDefaults?=nil) {
        let p=preferences ?? UserDefaults(suiteName:LocalLearningCoordinator.groupID)
        guard let scope=p?.string(forKey:"automatic-clipboard-scope") else{return}
        let token=UUID().uuidString
        p?.set(token,forKey:"clipboard-live-read-retry-generation")
        observedReadRetry=token;pendingReadRetryScope=scope
        nextPoll = .distantPast;retryAfter = .distantPast
    }
    @discardableResult func tick(fullAccess:Bool,sensitive:Bool=false,validating:@escaping @MainActor ()->Bool={true})->Bool {
        let p=UserDefaults(suiteName:LocalLearningCoordinator.groupID)
        guard fullAccess,!sensitive,let scope=p?.string(forKey:"automatic-clipboard-scope"),validating(),
              p?.bool(forKey:"clipboard-sharing-enabled")==true,p?.bool(forKey:"automatic-clipboard-enabled")==true else {suspend();return false}
        if p?.string(forKey:"clipboard-live-ready-scope") != scope {
            // Do not turn a brief parent credential replacement into a second
            // clipboard producer. Initial unsupported installs may still use v1.
            if currentScope==scope,isActive {epoch=UUID();task?.cancel();task=nil;bridge.pause();return true}
            suspend();return false
        }
        if let generation=p?.string(forKey:"clipboard-live-grant-generation"),
           p?.string(forKey:"clipboard-live-authority-blocked-generation")==generation {
            epoch=UUID();task?.cancel();task=nil;bridge.pause();isActive=true;return true
        }
        if currentScope != scope {
            suspend();currentScope=scope;supportedEndpoint=nil;nextPoll = .distantPast;retryAfter = .distantPast;observedVersion=nil;failures=0
        }
        let readRetry=p?.string(forKey:"clipboard-live-read-retry-generation")
        if readRetry != observedReadRetry {
            observedReadRetry=readRetry
            if readRetry != nil {pendingReadRetryScope=scope;nextPoll = .distantPast;retryAfter = .distantPast}
        }
        let version=NativeAutomaticClipboardBoard().version,changed=version != observedVersion
        guard task==nil,Date()>=retryAfter,changed || Date()>=nextPoll else {return isActive}
        observedVersion=version
        let token=UUID();epoch=token
        task=Task { [weak self] in
            guard let self else{return}
            var requestedGeneration:UUID?
            defer {if self.epoch==token {self.task=nil}}
            do {
                let loaded=try await Task.detached(priority:.utility) { ()throws->ClipboardLiveSnapshot? in
                    try AppleClipboardLiveStorage.store().snapshot(scope:scope,now:UInt64(Date().timeIntervalSince1970))
                }.value
                guard !Task.isCancelled,self.epoch==token,self.authorized(scope:scope,validating:validating),let loaded else {return}
                let config=loaded.configuration;requestedGeneration=config.certificate.generation
                if self.supportedEndpoint != config.endpoint {
                    guard try await ClipboardLiveClient(endpoint:config.endpoint,allowLoopbackHTTP:Self.loopback).supported() else {throw ClipboardLiveError.unavailable}
                    guard !Task.isCancelled,self.epoch==token,self.authorized(scope:scope,validating:validating) else{return}
                    self.supportedEndpoint=config.endpoint
                }
                self.isActive=true
                if self.pendingReadRetryScope==scope {self.bridge.requestReadRetry();self.pendingReadRetryScope=nil}
                let before=AutomaticClipboardSession(scope:scope,device:config.certificate.parent,clips:ClipboardLiveProjection.merge(loaded.received,[],group:config.certificate.group,epoch:config.certificate.epoch,now:UInt64(Date().timeIntervalSince1970)),outgoingPending:!loaded.pending.isEmpty)
                if let upload=self.bridge.prepare(before,importPending:false) {
                    let boardVersion=NativeAutomaticClipboardBoard().version
                    _ = try await Task.detached(priority:.utility) {
                        try AppleClipboardLiveStorage.store().enqueue(upload.text,scope:scope,version:boardVersion,now:UInt64(Date().timeIntervalSince1970))
                    }.value
                    guard !Task.isCancelled,self.epoch==token,self.authorized(scope:scope,validating:validating) else{return}
                    self.bridge.queued(upload,clearSharedPending:false)
                }
                let claimed=try await Task.detached(priority:.utility) { ()throws->ClipboardLiveSnapshot? in
                    try AppleClipboardLiveStorage.store().claim(scope:scope,now:UInt64(Date().timeIntervalSince1970))
                }.value
                guard let request=claimed else {self.nextPoll=Date().addingTimeInterval(1);return}
                defer {
                    if let lease=request.lease {Task.detached(priority:.utility) {try? AppleClipboardLiveStorage.store().release(lease,scope:scope)}}
                }
                guard !Task.isCancelled,self.epoch==token,self.authorized(scope:scope,validating:validating) else{return}
                self.bridge.begin()
                let response=try await ClipboardLiveClient(endpoint:config.endpoint,allowLoopbackHTTP:Self.loopback).batch(request,now:UInt64(Date().timeIntervalSince1970))
                guard !Task.isCancelled,self.epoch==token,self.authorized(scope:scope,validating:validating) else{return}
                let latest=try await Task.detached(priority:.utility) { ()throws->ClipboardLiveSnapshot? in
                    let store=try AppleClipboardLiveStorage.store(),now=UInt64(Date().timeIntervalSince1970)
                    _ = try store.apply(response,request:request,published:request.pending.first?.id,now:now)
                    return try store.snapshot(scope:scope,now:now)
                }.value
                guard !Task.isCancelled,self.epoch==token,self.authorized(scope:scope,validating:validating),let latest else{return}
                let now=UInt64(Date().timeIntervalSince1970),clips=ClipboardLiveProjection.merge(latest.received,[],group:config.certificate.group,epoch:config.certificate.epoch,now:now)
                #if os(iOS)
                ClipboardCacheCoordinator.recordMarkerReceipts(clips)
                #endif
                await self.bridge.finish(.init(scope:scope,device:config.certificate.parent,clips:clips,outgoingPending:!latest.pending.isEmpty),received:response.items.count,now:now,validating:{self.epoch==token && self.authorized(scope:scope,validating:validating)})
                guard !Task.isCancelled,self.epoch==token,self.authorized(scope:scope,validating:validating) else{return}
                // Only actual new receipt/cursor state changes wake candidate UI.
                let fingerprint=String(latest.cursor ?? 0)+":"+clips.map{$0.id.uuidString}.joined(separator:":")
                if p?.string(forKey:"clipboard-live-cache-generation") != fingerprint {
                    p?.set(fingerprint,forKey:"clipboard-live-cache-generation")
                    NotificationCenter.default.post(name:.clipboardLiveUpdated,object:nil)
                }
                self.failures=0;self.retryAfter = .distantPast
                self.nextPoll=Date().addingTimeInterval(latest.pending.isEmpty ? 3+Double.random(in:0...0.25):0.05)
            } catch {
                guard self.epoch==token else{return}
                self.bridge.pause();self.failures=min(self.failures+1,5)
                if case ClipboardLiveError.unavailable=error {
                    self.supportedEndpoint=nil;self.retryAfter=Date().addingTimeInterval(60)
                } else if case ClipboardLiveHTTPError.status(let status,let reason)=error,
                    status==401 || status==403 || (status==409 && reason=="live_grant_conflict") ||
                    (status==410 && ["live_certificate_expired","device_removed","device_inactive"].contains(reason)) {
                    // Parent app refreshes grant/epoch; a keyboard cannot mint
                    // authorization or recover a group root on its own.
                    if let generation=requestedGeneration,p?.string(forKey:"clipboard-live-grant-generation")==generation.uuidString {
                        p?.set(generation.uuidString,forKey:"clipboard-live-authority-blocked-generation")
                        p?.set(true,forKey:"clipboard-live-needs-refresh")
                    }
                    self.retryAfter=Date().addingTimeInterval(10)
                } else {self.retryAfter=Date().addingTimeInterval(min(60,pow(2,Double(self.failures))))}
            }
        }
        return isActive
    }
    private static var loopback:Bool {
        #if DEBUG || targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
}
