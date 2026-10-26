import Foundation
import PrivateInputKit
import CryptoKit
import Darwin

struct DeviceSyncInfo:Equatable {
    var ticket: QuickPairTicket?
    var quickInvitation: URL?
    var quickJoining = false
    var configured = false
    var canManage = false
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
    var cloudLearning = false
    var cloudPhase = "未迁移"
}
private struct SyncConfiguration: Codable {
    var endpoint: URL?
    var group: UUID?
    var learning = false
    var clipboard = false
    var automaticClipboard:Bool?
    var automaticClipboardGeneration:String?
    var newGroupSharingDefaultsPending:Bool?
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
    var lastLearningPublishAt: UInt64?
    var lastFullLearningRepairAt: UInt64?
    var lastRecencyDigest: Data?
    var lastRecencyGroup: UUID?
    var lastRecencyEpoch: UInt64?
    var lastRecencyPublishAt: UInt64?
    var conditionalRecencyEndpoint: URL?
    var recencyCacheGroup: UUID?
    var recencyCacheEpoch: UInt64?
    var recencyOwnEvent: String?
    var recencyPeerEvents: [String: String]?
    var cloudMigrationRequested: Bool?
    var cloudInstallation: UUID?
    var cloudRevocationPending: Bool?
    var lastCloudModelVerifiedAt: UInt64?
    var cloudVerifiedGroup: UUID?
    var cloudVerifiedEpoch: UInt64?
    var cloudVerifiedInstallation: UUID?
    var lastRecencyCompatibilitySuccessAt: UInt64?
    var recencyCompatibilityGroup: UUID?
    var recencyCompatibilityEpoch: UInt64?
}

actor DeviceSyncSession {
    private let base: URL
    private let configFile: URL
    private let learningDeltaFile: URL
    private let identityAccount: String
    private var configuration: SyncConfiguration
    private var learningDeltaCheckpoint: LearningDeltaCheckpoint?
    private var learningDeltaLoaded = false
    private var cloudMigration: CloudLearningComponentMigration?
    private var cloudSyncRunning = false
    private var cloudRevokeRunning = false
    private var cloudRevokeRetryAfter: UInt64 = 0
    private var cloudRetryAfter: UInt64 = 0
    private var cloudPhase = "未迁移"
    private var deviceStatuses:[GroupDeviceStatus]=[]
    private var recencySyncRunning = false
    private var recencyCloudMode: Bool?
    private var recencyAttemptEpoch: UInt64?
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
        learningDeltaFile = base.appendingPathComponent("learning-delta-checkpoint-v2.json")
        if FileManager.default.fileExists(atPath: configFile.path) {
            configuration = try JSONDecoder().decode(SyncConfiguration.self, from: Data(contentsOf: configFile))
        } else { configuration = SyncConfiguration() }
        authorization = SyncConsentGate(.init(learning: configuration.learning, clipboard: configuration.clipboard))
        if configuration.cloudMigrationRequested == true { cloudPhase = "待同步" }
    }
    private var now: UInt64 { UInt64(Date().timeIntervalSince1970) }
    private var permitsGroupControl:Bool {
        #if os(iOS)
        return true
        #else
        // Offline phones still own control until server-reported departure.
        return !deviceStatuses.isEmpty && deviceStatuses.allSatisfy {
            $0.inactive || $0.kind == "macos" || $0.kind == "windows"
        }
        #endif
    }
    private func applyNewGroupSharingDefaults() throws {
        // This entry runs only after creation/acceptance of a new group, never
        // while loading an existing session or refreshing its preferences.
        guard configuration.newGroupSharingDefaultsPending == true else {return}
        try consent(learning:true,clipboard:true,newGroupDefault:true)
        try setAutomaticClipboard(true,newGroupDefault:true)
        configuration.newGroupSharingDefaultsPending=nil
        try save()
    }
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
        prefs?.set(configuration.learning && configuration.cloudMigrationRequested == true, forKey: "cloud-learning-enabled")
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
        info.cloudLearning = configuration.cloudMigrationRequested == true; info.cloudPhase = cloudPhase
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
            info.canManage = (try setup.membership.member(identity.device).permissions == .all) && permitsGroupControl
            if info.canManage, let endpoint = configuration.endpoint { info.invitation = try DeviceInvitation(endpoint: endpoint, anchor: setup.membership.anchor).link(allowLoopbackHTTP: Self.loopback) }
            if configuration.clipboard {
                let legacy=try store.clipboard(group:group,now:now)
                let snapshot=try? AppleClipboardLiveStorage.store().snapshot(now:now)
                let live=snapshot?.configuration.certificate.group==group && snapshot?.configuration.certificate.epoch==setup.membership.statement.epoch ? snapshot?.received ?? []:[]
                info.clips=ClipboardLiveProjection.merge(legacy,live,group:group,epoch:setup.membership.statement.epoch,now:now)
            }
            if permitsGroupControl, let request = configuration.ownerRequest {
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
        if permitsGroupControl,let ticket=configuration.ticket,ticket.expiresAt>now,let qr=configuration.quickQR {
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
        let newGroup = configuration.group == nil
        if newGroup {
            let setup = try GroupSetup.create(owner: identity); try store.initializeGroup(setup)
            configuration.group = setup.membership.anchor.group
            configuration.newGroupSharingDefaultsPending=true
        }
        configuration.endpoint = endpoint; try save()
        guard let group = configuration.group else { throw ReplicaStoreError.missingGroup }
        try await client.register(store.group(group).membership)
        try applyNewGroupSharingDefaults()
    }
    func makeQuickInvitation() async throws {
        guard let group=configuration.group else { throw ReplicaStoreError.missingGroup }
        try await refreshDeviceStatus()
        guard configuration.group==group,permitsGroupControl else {throw MembershipError.notMember}
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
        if !permitsGroupControl {
            configuration.ticket=nil;configuration.quickQR=nil;configuration.ticketEpoch=nil;try save();return
        }
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
        await flushCloudLearningRevocation()
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
        guard try setup.membership.member(identity.device).permissions == .all,permitsGroupControl else {return}
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
            configuration.newGroupSharingDefaultsPending=true
            try applyNewGroupSharingDefaults()
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
        try applyNewGroupSharingDefaults()
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
        guard permitsGroupControl else {throw MembershipError.notMember}
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
        for name in ["Database","Identity","CloudMigrationSeeds"] {
            let url=base.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath:url.path) {try FileManager.default.removeItem(at:url)}
        }
        if FileManager.default.fileExists(atPath:learningDeltaFile.path) { try FileManager.default.removeItem(at:learningDeltaFile) }
        learningDeltaCheckpoint=nil;learningDeltaLoaded=false
        cloudMigration=nil;cloudRetryAfter=0;cloudPhase="未迁移"
        try? FileManager.default.removeItem(at:base.appendingPathComponent("cloud-learning-components-v1.json"))
        try? FileManager.default.removeItem(at:base.appendingPathComponent("cloud-migration-status-v1.json"))
        let endpoint=configuration.endpoint
        configuration=SyncConfiguration();configuration.endpoint=endpoint;configuration.departed=reason
        configuration.personalEpoch=PersonalDataReset.generation;deviceStatuses=[];try save()
    }
    func consent(learning: Bool, clipboard: Bool,newGroupDefault:Bool=false) throws {
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
            if !newGroupDefault {configuration.newGroupSharingDefaultsPending=nil}
            if !learning, configuration.cloudMigrationRequested == true {
                configuration.cloudMigrationRequested = false; configuration.cloudRevocationPending = true
                configuration.lastCloudModelVerifiedAt = nil
            }
            configuration.learning = learning; configuration.clipboard = clipboard
            if !clipboard {configuration.automaticClipboard=false;configuration.automaticClipboardGeneration=nil}
            do { try save() } catch { configuration = previous; throw error }
        }
        #if os(iOS)
        if !clipboard { try ClipboardCacheCoordinator.cache().clear();ClipboardCacheCoordinator.clearPreview() }
        #endif
        if !learning { retireCloudRanking() }
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
            try store.migrateLearningCapacity(group: group)
            var outgoing=try LearningModel(capacityProfile: LearningCapacityProfiles.expanded10000)
            try outgoing.merge(store.learningArchive(group: group))
            if let archive=try SharedLearningSnapshot(directory:shared).read() { try outgoing.merge(archive) }
            if let directory=PersonalLexiconLocation.directory {
                try outgoing.mergePersonalLexicon(PersonalLexiconStore(directory:directory).syncSnapshot())
            }
            let archive=try outgoing.export(),digest = Data(SHA256.hash(data: archive))
            let epoch=try store.group(group).membership.statement.epoch
            // The legacy relay expires events after seven days. A bounded
            // daily repair snapshot prevents a missed delta becoming permanent.
            let repairDue = configuration.lastFullLearningRepairAt.map { now < $0 || now - $0 >= 86400 } ?? true
            if repairDue || LearningPublication.needed(digest:digest,group:group,epoch:epoch,
                                          previousDigest:configuration.lastLearningDigest,
                                          previousGroup:configuration.lastLearningGroup,previousEpoch:configuration.lastLearningEpoch) {
                // Keep the large baseline out of the frequently saved session
                // preferences. Only dirty learning publication reads/writes it.
                if !learningDeltaLoaded {
                    if FileManager.default.fileExists(atPath:learningDeltaFile.path) {
                        let handle=try FileHandle(forReadingFrom:learningDeltaFile);defer{try? handle.close()}
                        let data=try handle.read(upToCount:2*1024*1024+1) ?? Data()
                        // This is a disposable publication index. Missing/bad
                        // metadata forces full repair, never drops word data.
                        if data.count<=2*1024*1024 {learningDeltaCheckpoint=try? JSONDecoder().decode(LearningDeltaCheckpoint.self,from:data)}
                    }
                    learningDeltaLoaded=true
                }
                let publication:LearningDeltaPublication
                do {publication=try LearningDeltaPublication.prepare(archive:archive,group:group,epoch:epoch,
                                                                      previous:repairDue ? nil:learningDeltaCheckpoint)}
                catch InputDataError.invalidRecord {
                    publication=try LearningDeltaPublication.prepare(archive:archive,group:group,epoch:epoch,previous:nil)
                }
                if let delta = publication.payload {
                    _ = try store.enqueue(delta, domain: .learning, group: group, sharingEnabled: true, now: now)
                }
                let previous = configuration
                configuration.lastLearningPublishAt = now
                if publication.bootstrap { configuration.lastFullLearningRepairAt = now }
                configuration.lastLearningDigest = digest;configuration.lastLearningGroup=group;configuration.lastLearningEpoch=epoch
                do {
                    let checkpoint=try JSONEncoder().encode(publication.checkpoint)
                    guard checkpoint.count<=2*1024*1024 else{throw InputDataError.oversized}
                    try checkpoint.write(to:learningDeltaFile,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
                    try save();learningDeltaCheckpoint=publication.checkpoint
                } catch { configuration = previous; throw error }
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
        await synchronizeCloudLearning(group: group, lease: lease)
        return result
    }

    private func synchronizeRecentLearning(group: UUID, store: SecureReplicaStore, lease: SyncConsentGate.Lease) async {
        guard !recencySyncRunning else { return }
        let currentEpoch = (try? store.group(group).membership.statement.epoch)
        if recencyAttemptGroup != group || recencyAttemptEpoch != currentEpoch {
            recencyAttemptGroup = group; recencyAttemptEpoch = currentEpoch; recencyRetryAfter = 0
        }
        let cloudCurrent = LearningTransportPolicy.cloudIsCurrent(now: now, verifiedAt: configuration.lastCloudModelVerifiedAt,
            scopeMatches: configuration.cloudVerifiedGroup == group && configuration.cloudVerifiedEpoch == currentEpoch &&
                configuration.cloudVerifiedInstallation == configuration.cloudInstallation,
            enabled: configuration.learning && configuration.cloudMigrationRequested == true &&
                UserDefaults(suiteName: LocalLearningCoordinator.groupID)?.bool(forKey: "cloud-learning-enabled") == true)
        if recencyCloudMode != cloudCurrent { recencyCloudMode = cloudCurrent; recencyRetryAfter = 0 }
        guard now >= recencyRetryAfter else { return }
        if !LearningTransportPolicy.legacyCompatibilityDue(now: now,
            lastSuccess: configuration.recencyCompatibilityGroup == group && configuration.recencyCompatibilityEpoch == currentEpoch ? configuration.lastRecencyCompatibilitySuccessAt : nil,
            cloudCurrent: cloudCurrent) {
            recencyRetryAfter = now + 600; return
        }
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
            let epoch = setup.membership.statement.epoch
            let cacheUsable = try configuration.recencyCacheGroup == group && configuration.recencyCacheEpoch == epoch &&
                              (try bridge.archive(group: group, epoch: epoch)) != nil
            let conditional = configuration.conditionalRecencyEndpoint == endpoint
            let timed = try await recent.hello(setup: setup, identity: identity, roles: roles, now: now,
                                               knownEvent: conditional && cacheUsable ? configuration.recencyOwnEvent : nil)
            guard timed.status.ready else { recencyRetryAfter = now + 30; try? bridge.suspend(); return }
            let policy = try timed.status.policy
            try authorization.withLease(lease) { consent in
                guard consent.learning, configuration.group == group,
                      try store.group(group).membership.statement.epoch == epoch else { throw ReplicaStoreError.changedState }
                try bridge.acceptAuthenticated(group: group, epoch: epoch, policy: policy,
                                               unixSeconds: Double(timed.status.serverTime), uptime: timed.responseUptime)
                if let own = timed.status.envelope {
                    try bridge.merge(own.open(group: setup, now: now, policy: policy), group: group, epoch: epoch)
                }
                if !cacheUsable { configuration.recencyOwnEvent = nil; configuration.recencyPeerEvents = [:] }
                configuration.recencyCacheGroup = group; configuration.recencyCacheEpoch = epoch
                configuration.conditionalRecencyEndpoint = timed.status.conditionalSnapshots == true ? endpoint : nil
                if timed.status.envelope != nil { configuration.recencyOwnEvent = timed.status.publishedEvent }
                try save()
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
                        configuration.lastRecencyEpoch = epoch; configuration.lastRecencyPublishAt = now
                        configuration.recencyOwnEvent = envelope.event.uuidString; try save()
                    }
                }
            }
            var cursor = ""
            for _ in 0..<64 {
                try authorization.withLease(lease) { consent in
                    guard consent.learning, configuration.group == group else { throw ReplicaStoreError.changedState }
                }
                let page = try await recent.pull(after: cursor, setup: setup, identity: identity, now: now,
                                                knownSnapshots: timed.status.conditionalSnapshots == true ? configuration.recencyPeerEvents : nil)
                guard page.status.ready else { throw RecentLearningSyncError.notReady }
                guard page.status.referenceDay == policy.referenceDay else { throw RecentLearningSyncError.invalidTime }
                guard let envelope = page.status.envelope else { break }
                let payload = try envelope.open(group: setup, now: now, policy: policy)
                try authorization.withLease(lease) { consent in
                    guard consent.learning, configuration.group == group,
                          try store.group(group).membership.statement.epoch == epoch else { throw ReplicaStoreError.changedState }
                    try bridge.merge(payload, group: group, epoch: epoch)
                    configuration.recencyPeerEvents?[envelope.sender.uuidString] = envelope.event.uuidString
                    try save()
                }
                cursor = page.status.next ?? ""
            }
            configuration.lastRecencyCompatibilitySuccessAt = now
            configuration.recencyCompatibilityGroup = group; configuration.recencyCompatibilityEpoch = epoch; try save()
            recencyRetryAfter = now + 600
        } catch {
            // Unsupported service, stale capability, bad time, cancellation or
            // malformed new data only disable this optional scoring source.
            if configuration.group == group {
                if case RecentLearningSyncError.httpStatus(400) = error {
                    // A downgraded endpoint may no longer accept optional
                    // conditional fields. Re-negotiate with legacy hello.
                    configuration.conditionalRecencyEndpoint = nil; try? save()
                }
                recencyRetryAfter = now + ((error as? RecentLearningSyncError).map { if case .unsupported = $0 { return UInt64(300) }; return UInt64(30) } ?? 30)
                try? bridge.suspend()
            }
        }
    }
    /// One user-facing choice, retaining the two existing authorization layers.
    /// A legacy manual-sharing grant alone is never upgraded merely by viewing UI.
    func setClipboardSynchronization(_ enabled: Bool) throws {
        let learning = configuration.learning
        if !enabled { try consent(learning: learning, clipboard: false); return }
        if configuration.clipboard && configuration.automaticClipboard == true { return }
        try setAutomaticClipboard(false)
        try consent(learning: learning, clipboard: true)
        do { try setAutomaticClipboard(true) }
        catch {
            // An incomplete enable must not leave automatic observation authorized.
            try? consent(learning: learning, clipboard: false)
            throw error
        }
    }
    func setAutomaticClipboard(_ enabled:Bool,newGroupDefault:Bool=false) throws {
        guard !enabled || configuration.clipboard else {throw ReplicaStoreError.sharingDisabled}
        if !enabled {
            let liveIdentity=try? context().2
            try? AppleClipboardLiveStorage.revokeAndClear(identity:liveIdentity,now:now)
            Task {await AppleClipboardLiveStorage.sendPendingRevocations()}
        }
        let previous=configuration
        if !newGroupDefault {configuration.newGroupSharingDefaultsPending=nil}
        configuration.automaticClipboard=enabled
        configuration.automaticClipboardGeneration=enabled ? UUID().uuidString:nil
        if enabled {UserDefaults(suiteName:LocalLearningCoordinator.groupID)?.removeObject(forKey:"automatic-clipboard-read-paused")}
        do {try save()}catch{configuration=previous;throw error}
        if !enabled {AutomaticClipboardOrigin.clear()}
        #if os(iOS)
        if !enabled {ClipboardCacheCoordinator.clearPreview()}
        #endif
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
    /// Explicit migration entry used by the app's settings and the local
    /// deployment command. It never invents a server or enrolls a new device.
    func enableCloudLearningMigration() async throws {
        guard configuration.learning, let group = configuration.group, let endpoint = configuration.endpoint else { throw ReplicaStoreError.missingGroup }
        _ = try await archiveConnection()
        let (_, _, identity) = try context()
        let client = CloudLearningClient(transport: try CloudLearningHTTPTransport(endpoint: endpoint, allowLoopbackHTTP: Self.loopback))
        var status = try await client.status(group: group, identity: identity, now: now)
        if !status.enabled { status = try await client.configureGroup(expectedVersion: status.policyVersion, enabled: true, group: group, identity: identity, now: now) }
        let installation = configuration.cloudInstallation ?? status.consent?.installationID ?? UUID()
        if status.consent?.enabled != true || status.consent?.installationID != installation {
            status = try await client.configureDevice(expectedVersion: status.consent?.version ?? 0, enabled: true,
                installation: installation, group: group, identity: identity, now: now)
        }
        guard configuration.group == group, configuration.endpoint == endpoint, configuration.learning,
              status.enabled, status.consent?.enabled == true, status.consent?.installationID == installation else { throw ReplicaStoreError.changedState }
        configuration.cloudInstallation = installation; configuration.cloudMigrationRequested = true; configuration.cloudRevocationPending = false
        try save(); cloudRetryAfter = 0
        await synchronizeCloudLearning(group: group, lease: authorization.lease())
    }
    private func retireCloudRanking() {
        cloudMigration = nil; cloudRetryAfter = 0; cloudPhase = "已关闭"
        let preferences = UserDefaults(suiteName: LocalLearningCoordinator.groupID)
        preferences?.set(false, forKey: "cloud-learning-enabled")
        for key in ["cloud-learning-group", "cloud-learning-epoch", "cloud-learning-model-token"] { preferences?.removeObject(forKey: key) }
        if let directory = LocalLearningCoordinator.sharedDirectory() {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(AppleCloudLearningRankState.filename))
        }
    }
    func disableCloudLearningMigration() async throws {
        // Commit local stop before any network await. Offline revocation is
        // durable and retried by the app's ordinary pairing/background owner.
        configuration.cloudMigrationRequested = false; configuration.cloudRevocationPending = true
        configuration.lastCloudModelVerifiedAt = nil
        try save(); retireCloudRanking()
        await flushCloudLearningRevocation()
    }
    private func flushCloudLearningRevocation() async {
        guard !cloudRevokeRunning, now >= cloudRevokeRetryAfter,
              configuration.cloudRevocationPending == true, configuration.cloudMigrationRequested != true,
              let group = configuration.group, let endpoint = configuration.endpoint,
              let installation = configuration.cloudInstallation else { return }
        cloudRevokeRunning = true; cloudRevokeRetryAfter = now + 60
        defer { cloudRevokeRunning = false }
        do {
            let (_, store, identity) = try context()
            let epoch = try store.group(group).membership.statement.epoch
            let client = CloudLearningClient(transport: try CloudLearningHTTPTransport(endpoint: endpoint, allowLoopbackHTTP: Self.loopback))
            let status = try await client.status(group: group, identity: identity, now: now)
            guard configuration.group == group, configuration.endpoint == endpoint, configuration.cloudMigrationRequested != true,
                  try store.group(group).membership.statement.epoch == epoch else { throw ReplicaStoreError.changedState }
            if let consent = status.consent, consent.enabled, consent.installationID == installation {
                _ = try await client.configureDevice(expectedVersion: consent.version, enabled: false, installation: installation,
                                                      group: group, identity: identity, now: now)
            }
            guard configuration.group == group, configuration.cloudMigrationRequested != true else { throw ReplicaStoreError.changedState }
            configuration.cloudRevocationPending = false; try save()
        } catch { /* Local stop remains effective; keep the durable retry flag. */ }
    }
    private func writeCloudMigrationStatus() {
        struct Status: Encodable {
            let version = 1
            let build: String
            let recordedAt: UInt64
            let enabled, modelAndWatermarksVerified: Bool
            let phase: String
            let modelVersion: UInt64
            let producerCount, acceptedComponents, representedComponents: Int
            let lastLegacyCompatibilitySuccessAt: UInt64?
            let network: [InputNetworkUsage]
        }
        let producers = cloudMigration?.producers.values
        let report = Status(build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            recordedAt: now, enabled: configuration.cloudMigrationRequested == true,
            modelAndWatermarksVerified: cloudMigration?.ready == true, phase: cloudPhase,
            modelVersion: cloudMigration?.model.modelVersion ?? 0, producerCount: cloudMigration?.producers.count ?? 0,
            acceptedComponents: producers?.reduce(0) { $0 + $1.accepted.count } ?? 0,
            representedComponents: producers?.reduce(0) { $0 + $1.represented.count } ?? 0,
            lastLegacyCompatibilitySuccessAt: configuration.lastRecencyCompatibilitySuccessAt,
            network: InputNetworkMetrics.snapshot())
        if let data = try? JSONEncoder().encode(report), data.count < 16384 {
            try? data.write(to: base.appendingPathComponent("cloud-migration-status-v1.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
    private func synchronizeCloudLearning(group: UUID, lease: SyncConsentGate.Lease) async {
        guard !cloudSyncRunning, configuration.cloudMigrationRequested == true, configuration.learning,
              configuration.group == group, let endpoint = configuration.endpoint, let installation = configuration.cloudInstallation,
              let directory = LocalLearningCoordinator.sharedDirectory(), now >= cloudRetryAfter else { return }
        cloudSyncRunning = true; cloudRetryAfter = now + 60
        defer { cloudSyncRunning = false; writeCloudMigrationStatus() }
        // One bounded process owns this lane (daily IME/app or deployment CLI).
        // The native keyboard never takes this lock. Reload inside the lease.
        let descriptor = Darwin.open(base.appendingPathComponent("cloud-learning-components-v1.lock").path,
                                     O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return }; defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return }; defer { flock(descriptor, LOCK_UN) }
        do {
            let (_, store, identity) = try context()
            let membershipEpoch = try store.group(group).membership.statement.epoch
            let personalEpoch = PersonalDataReset.generation
            func check() throws {
                try authorization.withLease(lease) { consent in
                    guard consent.learning, configuration.group == group, configuration.endpoint == endpoint,
                          configuration.cloudMigrationRequested == true, PersonalDataReset.generation == personalEpoch,
                          UserDefaults(suiteName: LocalLearningCoordinator.groupID)?.bool(forKey: "cloud-learning-enabled") == true,
                          try store.group(group).membership.statement.epoch == membershipEpoch else { throw ReplicaStoreError.changedState }
                }
            }
            let client = CloudLearningClient(transport: try CloudLearningHTTPTransport(endpoint: endpoint, allowLoopbackHTTP: Self.loopback))
            let status = try await client.status(group: group, identity: identity, now: now); try check()
            guard status.enabled, status.algorithmVersion == "shared-lexeme-decay-v2", let consent = status.consent,
                  consent.enabled, consent.installationID == installation else {
                configuration.lastCloudModelVerifiedAt = nil; configuration.cloudMigrationRequested = false
                try save(); retireCloudRanking(); throw CloudLearningError.unsupported
            }
            let file = base.appendingPathComponent("cloud-learning-components-v1.json")
            if FileManager.default.fileExists(atPath: file.path) {
                let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
                let data = try handle.read(upToCount: 12 * 1024 * 1024 + 1) ?? Data()
                // The publication index is recoverable: op7 reconciles the
                // complete server-owned producer set before a replay. Native
                // journals/archives stay authoritative and are never removed.
                cloudMigration = try? CloudLearningComponentMigration.restore(data)
            }
            if let old = cloudMigration {
                if old.model.group != group || old.model.device != identity.device || old.model.installation != installation ||
                    old.model.generation != status.generation || old.model.consentVersion != consent.version {
                    // Explicit current opt-in established a new scope. Recover
                    // server-owned cumulative components with op7 before any
                    // new publication; never guess away a remote watermark.
                    cloudMigration = try .init(model: .init(group: group, device: identity.device, installation: installation,
                                                           generation: status.generation, consentVersion: consent.version))
                }
            } else {
                cloudMigration = try .init(model: .init(group: group, device: identity.device, installation: installation,
                                                       generation: status.generation, consentVersion: consent.version))
            }
            guard let table = Bundle.main.url(forResource: "rime", withExtension: nil)?.appendingPathComponent("charset/standard-8105.txt") else { throw CloudLearningError.invalid }
            let policy = try CloudLearningTextPolicy(standardCharacters: Data(contentsOf: table))
            _ = try AppleCloudMigrationSeed.consume(inbox: base.appendingPathComponent("CloudMigrationSeeds", isDirectory: true),
                group: group, device: identity.device, personalEpoch: personalEpoch, shared: directory, policy: policy)
            try AppleCloudProducerSnapshot.seedCommittedProducer(base: base.deletingLastPathComponent(), directory: directory)
            try AppleCloudProducerSnapshot.migrateCurrent(directory: directory)
            let snapshots = try AppleCloudProducerSnapshot.read(directory: directory)
            func persist() throws {
                try check()
                guard let state = cloudMigration else { throw CloudLearningError.invalid }
                try state.data().write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            var uploads = 0
            let uploadLimit = cloudMigration?.ready == true ? 2 : 40
            for producer in snapshots {
                if cloudMigration?.producers[producer.producer.uuidString] == nil {
                    let recovered = try await client.componentSnapshot(producer: producer.producer, generation: status.generation,
                        consentVersion: consent.version, installation: installation, group: group, identity: identity, now: now)
                    try check(); try cloudMigration?.bootstrap(recovered); try persist()
                }
                let records = CloudLearningComponents.project(producer.entries, producer: producer.producer, policy: policy)
                while uploads < uploadLimit {
                    guard let publication = try cloudMigration?.prepare(producer: producer.producer, records: records) else { break }
                    try persist() // exact publication durable BEFORE HTTP
                    let receipt = try await client.publishComponents(publication, group: group, identity: identity, now: now); try check()
                    try cloudMigration?.receive(receipt); try persist(); uploads += 1
                }
            }
            for _ in 0..<4 {
                guard let model = cloudMigration?.model else { throw CloudLearningError.invalid }
                let delta = try await client.pull(generation: status.generation, fromVersion: model.modelVersion, group: group, identity: identity, now: now); try check()
                try cloudMigration?.stage(delta, policy: policy); try persist()
                if !delta.hasMore { break }
            }
            // P5 personal records: isolated so an older server or one failed
            // record batch never blocks the model publication below.
            do { try await synchronizePersonalRecords(client: client, generation: status.generation, consentVersion: consent.version,
                     installation: installation, group: group, identity: identity, check: check) }
            catch CloudLearningError.http(let code) where code == 400 || code == 404 {}
            catch { cloudPhase = "个人词条待重试" }
            if let state = cloudMigration, state.ready {
                try AppleCloudLearningRankState.publish(state, membershipEpoch: membershipEpoch, directory: directory, now: now)
                let preferences = UserDefaults(suiteName: LocalLearningCoordinator.groupID)
                preferences?.set(group.uuidString, forKey: "cloud-learning-group")
                preferences?.set(membershipEpoch, forKey: "cloud-learning-epoch")
                preferences?.set("\(group.uuidString):\(membershipEpoch):\(state.model.modelVersion):\(now / 3600)", forKey: "cloud-learning-model-token")
                configuration.lastCloudModelVerifiedAt = now; configuration.cloudVerifiedGroup = group
                configuration.cloudVerifiedEpoch = membershipEpoch; configuration.cloudVerifiedInstallation = installation
                try save()
                cloudPhase = "已迁移 · 模型 \(state.model.modelVersion)"; cloudRetryAfter = now + 600
            } else { cloudPhase = "迁移中 · 等待聚合对账"; cloudRetryAfter = now + 30 }
        } catch {
            // Optional model transport cannot break a successful clipboard/v1
            // exchange or erase the last usable native learning state.
            cloudPhase = "迁移待重试"
            cloudRetryAfter = now + 60
        }
    }
    /// Pull first (CRDT merge never overwrites a newer local record), then upload
    /// only records whose content the server has not acknowledged yet.
    private func synchronizePersonalRecords(client: CloudLearningClient, generation: UInt64, consentVersion: UInt64, installation: UUID,
                                            group: UUID, identity: DeviceIdentity, check: () throws -> Void) async throws {
        guard let directory = PersonalLexiconLocation.directory else { return }
        let file = base.appendingPathComponent("cloud-personal-v1.json")
        let scope = "\(group.uuidString)/\(identity.device.uuidString)/\(installation.uuidString)/\(generation)/\(consentVersion)/\(PersonalDataReset.generation)"
        var progress = (try? JSONDecoder().decode(CloudPersonalProgress.self, from: Data(contentsOf: file))) ?? CloudPersonalProgress(scope: scope)
        if progress.scope != scope { progress = CloudPersonalProgress(scope: scope) }
        func persist() throws { try check(); try JSONEncoder().encode(progress).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        let lexicon = PersonalLexiconStore(directory: directory)
        for _ in 0..<16 {
            let page = try await client.pullPersonal(after: progress.pulled, generation: generation, consentVersion: consentVersion,
                                                     installation: installation, group: group, identity: identity, now: now); try check()
            if !page.records.isEmpty {
                let before = try lexicon.load(), after = try lexicon.mergeSynchronized(try CloudPersonalProgress.incoming(page.records))
                if before.entries != after.entries { NotificationCenter.default.post(name: .init("PrivateInputPersonalLexiconChanged"), object: nil) }
                for row in page.records { progress.acked[row.entry.id.uuidString] = try CloudPersonalProgress.digest(row.record) }
            }
            progress.pulled = page.nextVersion; try persist()
            if !page.hasMore { break }
        }
        let pending = try progress.pending(lexicon.syncSnapshot())
        for start in stride(from: 0, to: pending.count, by: 256) {
            let batch = Array(pending[start..<min(start + 256, pending.count)])
            _ = try await client.putPersonal(batch, generation: generation, consentVersion: consentVersion, installation: installation,
                                             group: group, identity: identity, now: now); try check()
            for row in batch { progress.acked[row.id] = try CloudPersonalProgress.digest(row.record) }
            try persist()
        }
    }

}
