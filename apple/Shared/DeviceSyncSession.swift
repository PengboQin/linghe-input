import Foundation
import PrivateInputKit
import CryptoKit

struct DeviceSyncInfo:Equatable {
    var ticket: QuickPairTicket?
    var quickInvitation: URL?
    var quickJoining = false
    var configured = false
    var owner = false
    var count = 0
    var endpoint = ""
    var invitation: URL?
    var learning = false
    var clipboard = false
    var automaticClipboard = false
    var automaticClipboardReadPaused=false
    var code: String?
    var ownerPending = false
    var joining = false
    var clips: [ReceivedClipboard] = []
    var devices:[GroupDeviceStatus]=[]
    var joiningExpiresAt:UInt64=0
    var joiningExpired=false
    var departed:String?
}
private struct SyncConfiguration: Codable {
    var endpoint: URL?
    var group: UUID?
    var learning = false
    var clipboard = false
    var automaticClipboard:Bool?
    var automaticClipboardGeneration:String?
    var joining: DeviceInvitation?
    var request: PairRequest?
    var challenge: PairingChallenge?
    var ownerRequest: PairRequest?
    var ticket: QuickPairTicket?
    var quickQR: QuickPairQR?
    var ticketEpoch:UInt64?
    var pendingQuickCode:String?
    var pendingQuickURL:URL?
    var quickJoining: Bool?
    var quickDeadline:UInt64?
    var profileRegistered:Bool?
    var lastActivity:UInt64?
    var idleDays:Int?
    var personalEpoch:String?
    var wipePending:Bool?
    var departed:String?
    var lastLearningDigest: Data?
    var lastLearningGroup: UUID?
    var lastLearningEpoch: UInt64?
    var lastRecencyDigest: Data?
    var lastRecencyGroup: UUID?
    var lastRecencyEpoch: UInt64?
    var lastRecencyPublishAt: UInt64?
}

actor DeviceSyncSession {
    private let base: URL
    private let configFile: URL
    private let identityAccount: String
    private var configuration: SyncConfiguration
    private var deviceStatuses:[GroupDeviceStatus]=[]
    private var recencySyncRunning = false
    private var recencyRetryAfter: UInt64 = 0
    private var recencyAttemptGroup: UUID?
    private let authorization: SyncConsentGate
    private var vault: DeviceIdentityVault?
    private var store: SecureReplicaStore?
    private static var loopback: Bool {
        #if DEBUG || targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
    init() throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if targetEnvironment(simulator)
        if let scope=ProcessInfo.processInfo.environment["PRIVATE_INPUT_SIM_SYNC_SCOPE"],
           scope.hasPrefix("shared35-"),scope.count<=64,
           scope.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) {
            base=support.appendingPathComponent("PrivateInput/SyntheticSync").appendingPathComponent(scope)
            identityAccount="synthetic-"+scope
        } else {
            base=support.appendingPathComponent("PrivateInput/SyncClient");identityAccount="primary"
        }
        #else
        base=support.appendingPathComponent("PrivateInput/SyncClient");identityAccount="primary"
        #endif
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        configFile = base.appendingPathComponent("session-config-v1.json")
        if FileManager.default.fileExists(atPath: configFile.path) {
            configuration = try JSONDecoder().decode(SyncConfiguration.self, from: Data(contentsOf: configFile))
        } else { configuration = SyncConfiguration() }
        authorization = SyncConsentGate(.init(learning: configuration.learning, clipboard: configuration.clipboard))
    }
    private var now: UInt64 { UInt64(Date().timeIntervalSince1970) }
    private func context(create: Bool = false) throws -> (DeviceIdentityVault, SecureReplicaStore, DeviceIdentity) {
        if vault == nil {
            #if os(iOS)
            guard let group = Bundle.main.object(forInfoDictionaryKey: "PrivateInputIdentityKeychainGroup") as? String, !group.contains("$(") else { throw IdentityStoreError.corrupt }
            let secrets = try KeychainIdentityStore(account: identityAccount, accessGroup: group)
            #else
            let secrets = try KeychainIdentityStore(account: identityAccount)
            #endif
            vault = try DeviceIdentityVault(store: secrets, directory: base.appendingPathComponent("Identity"))
        }
        guard let vault else { throw IdentityStoreError.absent }
        let identity: DeviceIdentity
        do { identity = try vault.load() }
        catch IdentityStoreError.absent { guard create else { throw IdentityStoreError.absent }; identity = try vault.create() }
        if store == nil { store = try SecureReplicaStore(directory: base.appendingPathComponent("Database"), vault: vault) }
        guard let store else { throw ReplicaStoreError.corrupt }; return (vault, store, identity)
    }
    private func save() throws {
        try JSONEncoder().encode(configuration).write(to: configFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let prefs = UserDefaults(suiteName: LocalLearningCoordinator.groupID)
        prefs?.set(configuration.learning, forKey: "learning-sharing-enabled")
        prefs?.set(configuration.clipboard, forKey: "clipboard-sharing-enabled")
        prefs?.set(configuration.clipboard && configuration.automaticClipboard==true,forKey:"automatic-clipboard-enabled")
        if prefs?.string(forKey:"automatic-clipboard-consent-generation") != configuration.automaticClipboardGeneration {
            prefs?.removeObject(forKey:"automatic-clipboard-scope");prefs?.removeObject(forKey:"automatic-clipboard-device")
            prefs?.set(false,forKey:"automatic-clipboard-receive-ready")
        }
        prefs?.set(configuration.automaticClipboardGeneration,forKey:"automatic-clipboard-consent-generation")
        if !configuration.clipboard || configuration.automaticClipboard != true {
            prefs?.removeObject(forKey:"automatic-clipboard-scope");prefs?.removeObject(forKey:"automatic-clipboard-device")
            prefs?.set(false,forKey:"automatic-clipboard-receive-ready")
            prefs?.set(false,forKey:"automatic-clipboard-outgoing-pending")
            #if os(iOS)
            ClipboardCacheCoordinator.clearAutomaticPending()
            #endif
        }
        if configuration.clipboard, let group = configuration.group { prefs?.set(group.uuidString, forKey: "clipboard-group-id") }
        else { prefs?.removeObject(forKey: "clipboard-group-id") }
    }
    private func client() throws -> RelayClient {
        guard let endpoint = configuration.endpoint else { throw RelayClientError.invalidEndpoint }
        return try RelayClient(endpoint: endpoint, allowLoopbackHTTP: Self.loopback)
    }
    /// Archive management receives only this session's independently verified group.
    /// Its identity remains in memory; the extension receives a separate write-only key.
    func archiveConnection(refresh: Bool = true) async throws -> ActivityArchiveLiveConnection {
        guard let group = configuration.group, let endpoint = configuration.endpoint else { throw ReplicaStoreError.missingGroup }
        if refresh {
            try await refreshDeviceStatus()
            guard configuration.group == group else { throw MembershipError.notMember }
            try await refreshMembership()
        }
        guard configuration.group == group, configuration.wipePending != true else { throw MembershipError.notMember }
        let (_, store, identity) = try context(), membership = try store.group(group).membership
        let member = try membership.member(identity.device)
        guard member.signingPublic == identity.signingKey.publicKey.rawRepresentation else { throw MembershipError.notMember }
        let descriptor = ActivityArchiveConnection(relayEndpoint: endpoint, group: group, device: identity.device,
                                                   anchor: membership.anchor, membership: membership.statement,
                                                   personalEpoch: PersonalDataReset.generation)
        return ActivityArchiveLiveConnection(publicConnection: descriptor, identity: identity)
    }
    func info() throws -> DeviceSyncInfo {
        if configuration.wipePending==true {try resetForDeparture(reason:configuration.departed ?? "removed")}
        if configuration.group != nil,configuration.personalEpoch != nil,PersonalDataReset.generation != "initial",configuration.personalEpoch != PersonalDataReset.generation {try resetForDeparture(reason:"inactive")}
        var info = DeviceSyncInfo(endpoint: configuration.endpoint?.absoluteString ?? "", learning: configuration.learning, clipboard: configuration.clipboard)
        info.automaticClipboard=configuration.clipboard && configuration.automaticClipboard==true
        #if os(iOS)
        info.automaticClipboardReadPaused=UserDefaults(suiteName:LocalLearningCoordinator.groupID)?.bool(forKey:"automatic-clipboard-read-paused")==true
        #endif
        if let group = configuration.group {
            let (_, store, identity) = try context(), setup = try store.group(group)
            info.configured = true; info.count = setup.membership.statement.members.count
            if let ticket=configuration.ticket, ticket.expiresAt<=now || configuration.ticketEpoch != setup.membership.statement.epoch {
                configuration.ticket=nil;configuration.quickQR=nil;configuration.ticketEpoch=nil;try save()
            }
            info.owner = setup.membership.anchor.ownerID == identity.ownerID
            if info.owner, let endpoint = configuration.endpoint { info.invitation = try DeviceInvitation(endpoint: endpoint, anchor: setup.membership.anchor).link(allowLoopbackHTTP: Self.loopback) }
            if configuration.clipboard {
                let legacy=try store.clipboard(group:group,now:now)
                let snapshot=try? AppleClipboardLiveStorage.store().snapshot(now:now)
                let live=snapshot?.configuration.certificate.group==group && snapshot?.configuration.certificate.epoch==setup.membership.statement.epoch ? snapshot?.received ?? []:[]
                info.clips=ClipboardLiveProjection.merge(legacy,live,group:group,epoch:setup.membership.statement.epoch,now:now)
            }
            if let request = configuration.ownerRequest {
                info.ownerPending = true; info.code = try? store.pendingApproval(session: request.session, now: now).code
            }
        }
        if let request = configuration.request, let invitation = configuration.joining {
            info.joining = true; info.endpoint = invitation.endpoint.absoluteString
            if let challenge = configuration.challenge, challenge.expiresAt > now, request.expiresAt > now {
                let (_, _, identity) = try context()
                info.code = try DevicePairing.authenticationCode(challenge, request: request, recipient: identity, now: now)
            }
        }
        if let ticket=configuration.ticket,ticket.expiresAt>now,let qr=configuration.quickQR {
            info.ticket=ticket;info.quickInvitation=try qr.link()
        }
        info.devices=deviceStatuses;info.departed=configuration.departed
        info.joiningExpiresAt=configuration.quickDeadline ?? configuration.request?.expiresAt ?? 0
        info.joiningExpired=info.joining && info.joiningExpiresAt<=now
        info.quickJoining=configuration.quickJoining ?? false
        return info
    }
    func create(endpoint text: String) async throws {
        guard let endpoint = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw RelayClientError.invalidEndpoint }
        let client = try RelayClient(endpoint: endpoint, allowLoopbackHTTP: Self.loopback)
        let (_, store, identity) = try context(create: true)
        if configuration.group == nil {
            let setup = try GroupSetup.create(owner: identity); try store.initializeGroup(setup)
            configuration.group = setup.membership.anchor.group
        }
        configuration.endpoint = endpoint; try save()
        guard let group = configuration.group else { throw ReplicaStoreError.missingGroup }
        try await client.register(store.group(group).membership)
    }
    func makeQuickInvitation() async throws {
        guard let group=configuration.group else { throw ReplicaStoreError.missingGroup }
        let (_,store,identity)=try context()
        let setup=try store.group(group)
        guard let endpoint=configuration.endpoint else { throw RelayClientError.invalidEndpoint }
        let invitation=DeviceInvitation(endpoint:endpoint,anchor:setup.membership.anchor)
        let secret=SymmetricKey(size:.bits256).withUnsafeBytes{Data($0)},id=UUID(),expires=now+290
        let ticket=try await client().createTicket(invitation:invitation,ticket:id,secretHash:Data(SHA256.hash(data:secret)),expiresAt:expires,identity:identity,now:now)
        configuration.ticket=ticket;configuration.ticketEpoch=setup.membership.statement.epoch;configuration.quickQR=QuickPairQR(invitation:invitation,ticket:id,secret:secret,expiresAt:ticket.expiresAt);try save()
    }
    func closeQuickInvitation() async throws {
        guard let ticket=configuration.ticket,let group=configuration.group else {return}
        let (_,_,identity)=try context()
        try await client().cancelTicket(ticket.ticket,group:group,identity:identity,now:now)
        if configuration.ticket?.ticket==ticket.ticket {configuration.ticket=nil;configuration.quickQR=nil;configuration.ticketEpoch=nil;try save()}
    }
    func joinQuick(code:String,endpoint:String) async throws {
        guard code.count==6,code.utf8.allSatisfy({$0>=48 && $0<=57}),configuration.group==nil,
              let url=URL(string:endpoint.trimmingCharacters(in:.whitespacesAndNewlines)) else { throw PairingError.malformed }
        let transport=try RelayClient(endpoint:url,allowLoopbackHTTP:Self.loopback)
        let (_,_,identity)=try context(create:true)
        let request:PairRequest
        if configuration.pendingQuickCode==code,configuration.endpoint==url,let old=configuration.request,old.expiresAt>now {request=old}
        else {request=try PairRequest.create(identity:identity,now:now)}
        configuration.endpoint=url;configuration.request=request;configuration.pendingQuickCode=code;try save()
        let invitation=try await transport.claimTicket(code:code,request:request)
        configuration.endpoint=url;configuration.joining=invitation;configuration.request=request;configuration.challenge=nil;configuration.quickJoining=true;configuration.quickDeadline=min(request.expiresAt,now+120);configuration.departed=nil;try save()
    }
    func joinQuick(link:URL) async throws {
        guard configuration.group==nil else { throw ReplicaStoreError.changedState }
        let qr=try QuickPairQR.decode(link,now:now),transport=try RelayClient(endpoint:qr.invitation.endpoint,allowLoopbackHTTP:Self.loopback)
        let (_,_,identity)=try context(create:true)
        let request:PairRequest
        if configuration.pendingQuickURL==link,let old=configuration.request,old.expiresAt>now {request=old}
        else {request=try PairRequest.create(identity:identity,now:now)}
        configuration.endpoint=qr.invitation.endpoint;configuration.request=request;configuration.pendingQuickURL=link;try save()
        let invitation=try await transport.claimTicket(qr:qr,request:request)
        guard invitation.anchor==qr.invitation.anchor else { throw MembershipError.wrongOwner }
        configuration.endpoint=invitation.endpoint;configuration.joining=invitation;configuration.request=request;configuration.challenge=nil;configuration.quickJoining=true;configuration.quickDeadline=min(request.expiresAt,now+120);configuration.departed=nil;try save()
    }
    func pollPairing() async throws {
        if configuration.quickJoining==true,let request=configuration.request {
            guard (configuration.quickDeadline ?? request.expiresAt)>now else {throw PairingError.expired}
            do { try await fetchJoiningCode();try await confirmPair() }
            catch RelayClientError.httpStatus(let code) where code==404 || code==403 { return }
            return
        }
        guard let group=configuration.group else { return }
        try await refreshDeviceStatus()
        guard configuration.group==group else {return}
        let (_,store,identity)=try context()
        try await refreshMembership()
        var setup=try store.group(group)
        guard try setup.membership.member(identity.device).permissions == .all else {return}
        let expired=Set(deviceStatuses.filter{$0.inactive && !$0.isSelf}.map(\.device))
        if !expired.isEmpty {
            let change=try store.prepareMemberChange(group:group,members:setup.membership.statement.members.filter{!expired.contains($0.device)},now:now)
            try await client().publishMemberChange(change)
            if let own=change.localPackage {try store.applyRotation(own,now:now)}
            setup=try store.group(group)
        }
        // A persisted owner request must finish publishing before another grant
        // can rotate the group again (including a retry after network failure).
        if let pending=configuration.ownerRequest {
            if pending.expiresAt<=now {try store.discardAdmission(session:pending.session);configuration.ownerRequest=nil;try save()}
            else {
                if setup.membership.statement.members.contains(where:{$0.device==pending.member.device}) {try store.discardAdmission(session:pending.session);configuration.ownerRequest=nil;try save()}
                else {do {try await confirmPair()} catch ReplicaStoreError.changedState {try store.discardAdmission(session:pending.session);configuration.ownerRequest=nil;try save()};return}
            }
        }
        let claims=try await client().quickClaims(group:group,owner:identity,now:now)
        guard let claim=claims.first else { return }
        let sponsor=try setup.membership.member(claim.sponsor)
        guard claim.sponsor==identity.device,sponsor.permissions == .all else { throw MembershipError.wrongOwner }
        let approval=try store.beginPairing(claim.request,group:group,permissions:.all,now:now)
        configuration.ownerRequest=claim.request;try save()
        _ = approval
        try await confirmPair()
    }
    func startJoining(link: URL) async throws {
        guard configuration.group == nil else { throw ReplicaStoreError.changedState }
        if link.host=="pair" { try await joinQuick(link:link);return }
        let invitation = try DeviceInvitation.decode(link, allowLoopbackHTTP: Self.loopback)
        let (_, _, identity) = try context(create: true)
        let request: PairRequest
        if configuration.joining?.anchor == invitation.anchor, let old = configuration.request, old.expiresAt > now { request = old }
        else { request = try PairRequest.create(identity: identity, now: now) }
        configuration.endpoint = invitation.endpoint; configuration.joining = invitation; configuration.request = request; configuration.challenge = nil; try save()
        try await client().submitPair(request, group: invitation.anchor.group, identity: identity, now: now)
    }
    func approveNextRequest() async throws {
        guard let group = configuration.group else { throw ReplicaStoreError.missingGroup }
        let (_, store, identity) = try context()
        let requests = try await client().pendingPairs(group: group, owner: identity, now: now)
        guard let request = requests.first else { return }
        let approval = try store.beginPairing(request, group: group, permissions: .all, now: now)
        configuration.ownerRequest = request; try save()
        try await client().publishChallenge(approval.challenge, session: request.session)
    }
    func fetchJoiningCode() async throws {
        guard let request = configuration.request, let invitation = configuration.joining else { throw PairingError.malformed }
        let (_, _, identity) = try context()
        let challenge = try await client().pairChallenge(group: invitation.anchor.group, session: request.session, identity: identity, now: now)
        guard challenge.anchor == invitation.anchor else { throw MembershipError.wrongOwner }
        _ = try DevicePairing.authenticationCode(challenge, request: request, recipient: identity, now: now)
        configuration.challenge = challenge; try save()
    }
    func retryJoining() async throws {
        guard let invitation = configuration.joining else { throw PairingError.malformed }
        try await startJoining(link: invitation.link(allowLoopbackHTTP: Self.loopback))
    }
    func cancelJoining() throws {
        guard configuration.group == nil else { throw ReplicaStoreError.changedState }
        configuration.joining = nil; configuration.request = nil; configuration.challenge = nil; configuration.quickJoining=nil;configuration.pendingQuickCode=nil;configuration.pendingQuickURL=nil
        try save()
    }
    func confirmPair() async throws {
        let (_, store, identity) = try context(), client = try client()
        if let request = configuration.ownerRequest, let group = configuration.group {
            do {
                let bundle=try store.stageAdmission(session:request.session,now:now)
                try await client.publishAdmission(bundle)
                try store.commitAdmission(session:request.session,now:now)
                configuration.ownerRequest=nil
            } catch RelayClientError.httpStatus(409) {
                try store.discardAdmission(session:request.session);configuration.ownerRequest=nil;try save()
                try await refreshMembership()
                return
            }
        } else if let request = configuration.request, let challenge = configuration.challenge, let invitation = configuration.joining {
            guard challenge.anchor == invitation.anchor else { throw MembershipError.wrongOwner }
            let code = try DevicePairing.authenticationCode(challenge, request: request, recipient: identity, now: now)
            let package = try await client.keyPackage(group: invitation.anchor.group, identity: identity, now: now)
            try store.acceptPairing(package, challenge: challenge, request: request, confirmedCode: code, now: now)
            configuration.profileRegistered=nil;configuration.personalEpoch=PersonalDataReset.generation;configuration.departed=nil
            configuration.group = invitation.anchor.group; configuration.joining = nil; configuration.request = nil; configuration.challenge = nil; configuration.quickJoining=nil;configuration.pendingQuickCode=nil;configuration.pendingQuickURL=nil
        } else { throw PairingError.malformed }
        try save()
    }
    private var platformKind:String {
        #if os(iOS)
        return "ios"
        #else
        return "macos"
        #endif
    }
    private func refreshMembership() async throws {
        guard let group=configuration.group else {return}
        let (_,store,identity)=try context(),old=try store.group(group)
        let remote=try await client().membership(group:group,identity:identity,now:now)
        let checked=try old.membership.anchor.verify(remote,replacing:old.membership)
        if checked.digest != old.membership.digest {
            let key=try await client().keyPackage(group:group,identity:identity,now:now)
            guard try old.membership.anchor.verify(key.membership,replacing:old.membership).digest==checked.digest else {throw MembershipError.equivocation}
            try store.applyRotation(key,now:now)
        }
    }
    func refreshDeviceStatus() async throws {
        guard let group=configuration.group else {return}
        let (_,_,identity)=try context()
        if configuration.profileRegistered != true {
            let previous=try await client().deviceStatus(group:group,identity:identity,now:now)
            if previous.departed {try resetForDeparture(reason:previous.reason ?? "removed");return}
            try await client().registerProfile(group:group,identity:identity,kind:platformKind,now:now)
            configuration.profileRegistered=true;configuration.personalEpoch=PersonalDataReset.generation;try save()
        }
        let status=try await client().deviceStatus(group:group,identity:identity,now:now)
        if status.departed {try resetForDeparture(reason:status.reason ?? "removed");return}
        deviceStatuses=status.devices
        let persist=configuration.lastActivity==nil || now<(configuration.lastActivity ?? now) || now-(configuration.lastActivity ?? now)>=60 || configuration.idleDays != status.devices.first(where:{$0.isSelf})?.idleDays
        if persist {configuration.lastActivity=now}
        if let own=status.devices.first(where:{$0.isSelf}) {configuration.idleDays=own.idleDays
            #if os(iOS)
            UserDefaults(suiteName:LocalLearningCoordinator.groupID)?.set(Double(now)+Double(own.idleDays)*86400,forKey:"mobile-group-expiry")
            #endif
        }
        if persist {try save()}
    }
    func setIdleDays(_ days:Int) async throws {
        guard let group=configuration.group else {throw ReplicaStoreError.missingGroup}
        let (_,_,identity)=try context();try await client().setIdleDays(days,group:group,identity:identity,now:now)
        try await refreshDeviceStatus()
    }
    func removeDevice(_ device:UUID) async throws {
        guard let group=configuration.group else {throw ReplicaStoreError.missingGroup}
        try await refreshDeviceStatus();guard configuration.group==group else {return}
        let (_,store,identity)=try context()
        guard let target=deviceStatuses.first(where:{$0.device==device}) else {throw MembershipError.notMember}
        if platformKind=="ios",device != identity.device,target.kind != "macos" && target.kind != "windows" {throw MembershipError.notMember}
        try await refreshMembership()
        let current=try store.group(group)
        let bundle=try store.prepareMemberChange(group:group,members:current.membership.statement.members.filter{$0.device != device},now:now)
        try await client().publishMemberChange(bundle)
        if device==identity.device {try resetForDeparture(reason:"left")}
        else if let own=bundle.localPackage {try store.applyRotation(own,now:now);try await refreshDeviceStatus()}
    }
    private func resetForDeparture(reason:String) throws {
        // Retire delegated authorization before deleting this device identity.
        let liveIdentity=try? context().2
        try? AppleClipboardLiveStorage.revokeAndClear(identity:liveIdentity,now:now)
        Task {await AppleClipboardLiveStorage.sendPendingRevocations()}
        configuration.wipePending=true;configuration.departed=reason;try save()
        AutomaticClipboardOrigin.clear()
        try authorization.update(.init(learning:false,clipboard:false)) {
            configuration.learning=false;configuration.clipboard=false;try save()
        }
        if configuration.personalEpoch==PersonalDataReset.generation || PersonalDataReset.generation=="initial" {try PersonalDataReset.request(reason:reason)}
        store=nil;vault=nil
        #if os(iOS)
        let group=Bundle.main.object(forInfoDictionaryKey:"PrivateInputIdentityKeychainGroup") as? String
        let secrets=try KeychainIdentityStore(account:identityAccount,accessGroup:group)
        try ClipboardCacheCoordinator.clearForDeparture()
        #else
        let secrets=try KeychainIdentityStore(account:identityAccount)
        #endif
        try secrets.removeForConfirmedDeparture()
        for name in ["Database","Identity"] {
            let url=base.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath:url.path) {try FileManager.default.removeItem(at:url)}
        }
        let endpoint=configuration.endpoint
        configuration=SyncConfiguration();configuration.endpoint=endpoint;configuration.departed=reason
        configuration.personalEpoch=PersonalDataReset.generation;deviceStatuses=[];try save()
    }
    func consent(learning: Bool, clipboard: Bool) throws {
        if !clipboard {
            let liveIdentity=try? context().2
            try? AppleClipboardLiveStorage.revokeAndClear(identity:liveIdentity,now:now)
            Task {await AppleClipboardLiveStorage.sendPendingRevocations()}
        }
        #if os(iOS)
        if clipboard { _ = try ClipboardCacheCoordinator.key(create: true) }
        #endif
        let previous = configuration
        try authorization.update(.init(learning: learning, clipboard: clipboard)) {
            configuration.learning = learning; configuration.clipboard = clipboard
            if !clipboard {configuration.automaticClipboard=false;configuration.automaticClipboardGeneration=nil}
            do { try save() } catch { configuration = previous; throw error }
        }
        #if os(iOS)
        if !clipboard { try ClipboardCacheCoordinator.cache().clear() }
        #endif
        if !learning, let directory = LocalLearningCoordinator.sharedDirectory() {
            try? AppleRecencyBridge(directory: directory).suspend()
        }
    }
    func disconnect() async throws {
        if let group=configuration.group {
            let (_,_,identity)=try context();try await client().leaveGroup(group:group,identity:identity,now:now)
        }
        try resetForDeparture(reason:"left")
    }
    func synchronize() async throws -> SyncPassResult {
        try await refreshDeviceStatus()
        let lease = authorization.lease()
        guard let group = configuration.group else { throw ReplicaStoreError.missingGroup }
        let (vault, store, identity) = try context()
        // New-feed compatibility is appended through the original durable FIFO.
        // A full legacy queue leaves these exact event/expiry rows for later.
        try? AppleClipboardLiveStorage.refreshPendingRevocations(identity:identity,now:now)
        Task {await AppleClipboardLiveStorage.sendPendingRevocations()}
        if configuration.clipboard {
            try authorization.withLease(lease) { current in
                guard current.clipboard,configuration.group==group else {throw ReplicaStoreError.changedState}
                if let automatic=try? automaticClipboardSession(),
                   let liveStore=try? AppleClipboardLiveStorage.store(),
                   let live=try? liveStore.snapshot(scope:automatic.scope,now:now) {
                    for clip in live.compat where clip.expiresAt>now {
                        do {
                            _ = try store.enqueue(Data(clip.text.utf8),domain:.clipboard,group:group,sharingEnabled:true,now:now,event:clip.eventID,expiresAt:clip.expiresAt)
                            try liveStore.acknowledgeCompatibility(clip.eventID,scope:automatic.scope)
                        } catch {break}
                    }
                }
            }
        }
        if configuration.learning, let shared = LocalLearningCoordinator.sharedDirectory() {
            var outgoing=LearningModel()
            if let archive=try SharedLearningSnapshot(directory:shared).read() { try outgoing.merge(archive) }
            if let directory=PersonalLexiconLocation.directory {
                try outgoing.mergePersonalLexicon(PersonalLexiconStore(directory:directory).syncSnapshot())
            }
            let archive=try outgoing.export(),digest = Data(SHA256.hash(data: archive))
            let epoch=try store.group(group).membership.statement.epoch
            if LearningPublication.needed(digest:digest,group:group,epoch:epoch,
                                          previousDigest:configuration.lastLearningDigest,
                                          previousGroup:configuration.lastLearningGroup,previousEpoch:configuration.lastLearningEpoch) {
                _ = try store.enqueue(archive, domain: .learning, group: group, sharingEnabled: true, now: now)
                configuration.lastLearningDigest = digest;configuration.lastLearningGroup=group;configuration.lastLearningEpoch=epoch;try save()
            }
        }
        let result = try await RelaySyncPass.run(group: group, store: store, vault: vault, client: client(),
                                                consent: .init(learning: configuration.learning, clipboard: configuration.clipboard), now: now,
                                                authorization: authorization, authorizationLease: lease)
        try authorization.withLease(lease) { current in
            guard configuration.group == group else { throw ReplicaStoreError.changedState }
            if current.learning, let shared = LocalLearningCoordinator.sharedDirectory() {
                let archive=try store.learningArchive(group:group)
                let decoded=try JSONDecoder().decode(LearningArchive.self,from:archive)
                if let personal=decoded.personalLexicon,let directory=PersonalLexiconLocation.directory {
                    let lexicon=PersonalLexiconStore(directory:directory),before=try lexicon.load()
                    let after=try lexicon.mergeSynchronized(personal)
                    if before.entries != after.entries {NotificationCenter.default.post(name:.init("PrivateInputPersonalLexiconChanged"),object:nil)}
                }
                try SharedLearningSnapshot(directory: shared).publish(archive, by: .containingApp)
            }
        #if os(iOS)
        if current.clipboard {
            let clips=try store.clipboard(group:group,now:now)
            try ClipboardCacheCoordinator.cache().publish(clips,group:group,key:ClipboardCacheCoordinator.key(),now:now)
            let prefs=UserDefaults(suiteName:LocalLearningCoordinator.groupID)
            let generation=clips.map{$0.id.uuidString}.joined(separator:":")
            if prefs?.string(forKey:"automatic-clipboard-cache-generation") != generation {prefs?.set(generation,forKey:"automatic-clipboard-cache-generation")}
        }
        #endif
        }
        // A missing/newer optional endpoint must never turn a successful v1
        // word/clipboard sync into an error, nor block the typing process.
        await synchronizeRecentLearning(group: group, store: store, lease: lease)
        return result
    }

    private func synchronizeRecentLearning(group: UUID, store: SecureReplicaStore, lease: SyncConsentGate.Lease) async {
        guard !recencySyncRunning else { return }
        if recencyAttemptGroup != group { recencyAttemptGroup = group; recencyRetryAfter = 0 }
        guard now >= recencyRetryAfter else { return }
        recencySyncRunning = true
        defer { recencySyncRunning = false }
        guard let directory = LocalLearningCoordinator.sharedDirectory() else { return }
        let bridge = AppleRecencyBridge(directory: directory)
        do {
            try authorization.withLease(lease) { consent in
                guard consent.learning, configuration.group == group else { throw ReplicaStoreError.changedState }
            }
            let (_, _, identity) = try context(), setup = try store.group(group)
            guard let endpoint = configuration.endpoint else { return }
            let recent = RecentLearningClient(transport: try RecentLearningHTTPTransport(endpoint: endpoint, allowLoopbackHTTP: Self.loopback))
            #if os(iOS)
            let roles = ["app", "keyboard"]
            #else
            let roles = ["desktop", "ime"]
            #endif
            let timed = try await recent.hello(setup: setup, identity: identity, roles: roles, now: now)
            guard timed.status.ready else { recencyRetryAfter = now + 30; try? bridge.suspend(); return }
            let policy = try timed.status.policy, epoch = setup.membership.statement.epoch
            try authorization.withLease(lease) { consent in
                guard consent.learning, configuration.group == group,
                      try store.group(group).membership.statement.epoch == epoch else { throw ReplicaStoreError.changedState }
                try bridge.acceptAuthenticated(group: group, epoch: epoch, policy: policy,
                                               unixSeconds: Double(timed.status.serverTime), uptime: timed.responseUptime)
                if let own = timed.status.envelope {
                    try bridge.merge(own.open(group: setup, now: now, policy: policy), group: group, epoch: epoch)
                }
            }
            if let outgoing = try bridge.archive(group: group, epoch: epoch) {
                let digest = Data(SHA256.hash(data: outgoing))
                let due = timed.status.publishedEvent.isEmpty || (configuration.lastRecencyPublishAt.map { now < $0 || now - $0 >= 86400 } ?? true)
                if due || LearningPublication.needed(digest: digest, group: group, epoch: epoch,
                                                     previousDigest: configuration.lastRecencyDigest,
                                                     previousGroup: configuration.lastRecencyGroup, previousEpoch: configuration.lastRecencyEpoch) {
                    try authorization.withLease(lease) { consent in
                        guard consent.learning, configuration.group == group else { throw ReplicaStoreError.changedState }
                    }
                    let envelope = try RecentLearningEnvelope.seal(outgoing, group: setup, identity: identity, now: now, policy: policy)
                    let pushed = try await recent.push(envelope, expectedEvent: timed.status.publishedEvent, setup: setup, identity: identity, now: now)
                    guard pushed.status.ready, pushed.status.referenceDay == policy.referenceDay else { throw RecentLearningSyncError.invalidTime }
                    try authorization.withLease(lease) { consent in
                        guard consent.learning, configuration.group == group else { throw ReplicaStoreError.changedState }
                        configuration.lastRecencyDigest = digest; configuration.lastRecencyGroup = group
                        configuration.lastRecencyEpoch = epoch; configuration.lastRecencyPublishAt = now; try save()
                    }
                }
            }
            var cursor = ""
            for _ in 0..<64 {
                try authorization.withLease(lease) { consent in
                    guard consent.learning, configuration.group == group else { throw ReplicaStoreError.changedState }
                }
                let page = try await recent.pull(after: cursor, setup: setup, identity: identity, now: now)
                guard page.status.ready else { throw RecentLearningSyncError.notReady }
                guard page.status.referenceDay == policy.referenceDay else { throw RecentLearningSyncError.invalidTime }
                guard let envelope = page.status.envelope else { break }
                let payload = try envelope.open(group: setup, now: now, policy: policy)
                try authorization.withLease(lease) { consent in
                    guard consent.learning, configuration.group == group,
                          try store.group(group).membership.statement.epoch == epoch else { throw ReplicaStoreError.changedState }
                    try bridge.merge(payload, group: group, epoch: epoch)
                }
                cursor = page.status.next ?? ""
            }
            recencyRetryAfter = 0
        } catch {
            // Unsupported service, stale capability, bad time, cancellation or
            // malformed new data only disable this optional scoring source.
            if configuration.group == group {
                recencyRetryAfter = now + ((error as? RecentLearningSyncError).map { if case .unsupported = $0 { return UInt64(300) }; return UInt64(30) } ?? 30)
                try? bridge.suspend()
            }
        }
    }
    func setAutomaticClipboard(_ enabled:Bool) throws {
        guard !enabled || configuration.clipboard else {throw ReplicaStoreError.sharingDisabled}
        if !enabled {
            let liveIdentity=try? context().2
            try? AppleClipboardLiveStorage.revokeAndClear(identity:liveIdentity,now:now)
            Task {await AppleClipboardLiveStorage.sendPendingRevocations()}
        }
        let previous=configuration
        configuration.automaticClipboard=enabled
        configuration.automaticClipboardGeneration=enabled ? UUID().uuidString:nil
        if enabled {UserDefaults(suiteName:LocalLearningCoordinator.groupID)?.removeObject(forKey:"automatic-clipboard-read-paused")}
        do {try save()}catch{configuration=previous;throw error}
        if !enabled {AutomaticClipboardOrigin.clear()}
    }
    func automaticClipboardSession() throws -> AutomaticClipboardSession? {
        guard configuration.automaticClipboard==true,configuration.clipboard,configuration.wipePending != true,
              let group=configuration.group,let consentGeneration=configuration.automaticClipboardGeneration else{return nil}
        let (_,store,identity)=try context(),setup=try store.group(group)
        let member=try setup.membership.member(identity.device)
        guard member.permissions.contains(.clipboard),member.signingPublic==identity.signingKey.publicKey.rawRepresentation else{return nil}
        let scope=group.uuidString+":"+String(setup.membership.statement.epoch)+":"+PersonalDataReset.generation+":"+consentGeneration
        let prefs=UserDefaults(suiteName:LocalLearningCoordinator.groupID)
        let changedScope=prefs?.string(forKey:"automatic-clipboard-scope") != scope
        prefs?.set(scope,forKey:"automatic-clipboard-scope")
        if changedScope {
            prefs?.set(false,forKey:"automatic-clipboard-receive-ready")
            #if os(iOS)
            ClipboardCacheCoordinator.clearAutomaticPending()
            #endif
        }
        prefs?.set(identity.device.uuidString,forKey:"automatic-clipboard-device")
        if let endpoint=configuration.endpoint {
            // Optional feature failure does not fail the established v1 session.
            try? AppleClipboardLiveStorage.provision(scope:scope,endpoint:endpoint,identity:identity,setup:setup,now:now)
        }
        let live=(try? AppleClipboardLiveStorage.store().snapshot(scope:scope,now:now))
        let pending = !(try store.pendingMessages(group:group,domains:[.clipboard],now:now)).isEmpty || live?.pending.isEmpty==false
        prefs?.set(pending,forKey:"automatic-clipboard-outgoing-pending")
        let clips=ClipboardLiveProjection.merge(try store.clipboard(group:group,now:now),live?.received ?? [],group:group,epoch:setup.membership.statement.epoch,now:now)
        return AutomaticClipboardSession(scope:scope,device:identity.device,clips:clips,outgoingPending:pending)
    }
    func enqueueAutomaticClipboard(text:String,scope:String) throws {
        guard let live=try automaticClipboardSession(),live.scope==scope,!text.isEmpty,!text.contains("\0"),text.utf8.count<=65536,
              let group=configuration.group else{throw ReplicaStoreError.sharingDisabled}
        let (_,store,_)=try context()
        _ = try store.enqueue(Data(text.utf8),domain:.clipboard,group:group,sharingEnabled:true,now:now)
        UserDefaults(suiteName:LocalLearningCoordinator.groupID)?.set(true,forKey:"automatic-clipboard-outgoing-pending")
    }
    func send(text: String) async throws {
        guard let group = configuration.group else { throw ReplicaStoreError.missingGroup }
        let (_, store, _) = try context()
        _ = try store.enqueue(Data(text.utf8), domain: .clipboard, group: group, sharingEnabled: configuration.clipboard, now: now)
        _ = try await synchronize()
    }
}
