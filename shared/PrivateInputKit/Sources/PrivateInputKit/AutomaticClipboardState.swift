import Foundation

/// Local arbitration only. It neither infers a cross-device clock order nor
/// stores clipboard contents. Authorization and OS reads belong to adapters.
public struct AutomaticClipboardState:Codable {
    public struct Pass { public let scope:String; public let version:Int; fileprivate let serial:UInt64;fileprivate let localActivity:Bool;public var diagnosticLocalActivity:Bool {localActivity} }
    public struct Diagnostic {public let armed:Bool,localReadBlocked:Bool,pendingLocal:Bool,localActivity:Bool,versionMatches:Bool}
    public struct Remote {
        public let id:UUID,sender:UUID,digest:String
        public let expiresAt:UInt64
        public init(id:UUID,sender:UUID,digest:String,expiresAt:UInt64) {self.id=id;self.sender=sender;self.digest=digest;self.expiresAt=expiresAt}
    }
    public private(set) var scope:String?
    public private(set) var armed=false
    public private(set) var pendingDigest:String?
    private var version:Int?
    private var localReadBlocked:Bool?
    private var blockedVersion:Int?
    private var serial:UInt64=0
    private var localActivity=false
    private var lastDigest:String?
    private var echoVersion:Int?
    private var seen:[UUID]=[]
    public init() {}
    public func diagnosticStatus(version:Int)->Diagnostic {.init(armed:armed,localReadBlocked:localReadBlocked==true,pendingLocal:pendingDigest != nil,localActivity:localActivity,versionMatches:self.version==version)}
    public mutating func configure(scope:String?,version:Int) {
        guard self.scope != scope else{return}
        // Group/session cleanup cannot erase what we already know about the
        // system board. A suspend uses a synthetic version; retain the identity
        // so the same physical copy is protected after the next activation.
        let protectedVersion=blockedVersion
        self=Self();self.scope=scope;self.version=version;blockedVersion=protectedVersion
        localReadBlocked=protectedVersion.map{$0==version}
    }
    /// Claims each changed version once, including denied/unsupported reads.
    /// A failed OS read cannot create a repeated paste-permission prompt loop.
    public mutating func claimLocalRead(version:Int)->Bool {
        guard scope != nil,self.version != version else{return false}
        self.version=version;serial &+= 1
        if echoVersion==version {return false}
        localActivity=true;return true
    }
    /// Only an explicit user retry may re-attempt an unchanged denied version.
    /// Preserve armed history, echo suppression, pending uploads and seen IDs.
    public mutating func requestReadRetry() {version=nil}
    /// Call only for a stable metadata or body observation. A failed newer
    /// physical copy must remain protected even before the next read claim.
    /// Successful reads may clear protection only for the currently claimed copy.
    public mutating func observeLocalRead(version:Int,readable:Bool) {
        if !readable {blockedVersion=version;if self.version==version {localReadBlocked=true};return}
        guard self.version==version else{return};localReadBlocked=false;blockedVersion=nil
    }
    public mutating func stageLocal(digest:String)->Bool {
        guard scope != nil,!digest.isEmpty,digest != lastDigest,digest != pendingDigest else{return false}
        pendingDigest=digest;return true
    }
    public mutating func outgoingDurablyQueued(digest:String) {
        guard pendingDigest==digest else{return};pendingDigest=nil;lastDigest=digest
    }
    public func begin(version:Int)->Pass? {
        guard let scope else{return nil};return Pass(scope:scope,version:version,serial:serial,localActivity:localActivity)
    }
    /// New arrivals during cold-start draining are history, not instructions
    /// to overwrite the system clipboard. Arm only after a quiescent pull.
    public mutating func finish(_ pass:Pass,currentVersion:Int,remote:[Remote],received:Int,ownDevice:UUID,now:UInt64,outgoingPending:Bool=false)->UUID? {
        guard scope==pass.scope else{return nil}
        let known=Set(seen)
        let fresh=remote.filter{!known.contains($0.id)}
        for row in fresh {seen.append(row.id)}
        if seen.count>256 {seen.removeFirst(seen.count-256)}
        if serial==pass.serial {localActivity=false}
        guard armed else {if received==0 {armed=true};return nil}
        guard version==currentVersion,localReadBlocked != true,!outgoingPending,pendingDigest==nil,!pass.localActivity,serial==pass.serial,currentVersion==pass.version else{return nil}
        return fresh.last(where:{$0.sender != ownDevice && $0.expiresAt>now && $0.expiresAt-now<=600 && $0.digest != lastDigest})?.id
    }
    public mutating func retryRemote(_ id:UUID) {seen.removeAll{$0==id}}
    public mutating func wroteRemote(version:Int,digest:String) {
        self.version=version;echoVersion=version;lastDigest=digest;pendingDigest=nil;localReadBlocked=false;blockedVersion=nil
    }
}

/// Prevents unchanged visible-keyboard ticks from opening Keychain or
/// decrypting shared cache files. At most one utility pass is admitted.
public struct AutomaticClipboardPollGate {
    private var last:String?
    private var running=false
    public init() {}
    public mutating func begin(_ fingerprint:String)->Bool {
        guard !running,last != fingerprint else{return false};running=true;return true
    }
    public mutating func finish(_ fingerprint:String,succeeded:Bool) {running=false;last=succeeded ? fingerprint:nil}
    public mutating func reset() {self=Self()}
}

/// Metadata can arrive after changeCount has advanced (for example, an OS
/// remote clipboard promise). Retry a body read once when that same copy first
/// becomes readable. An actual denied body read is not a metadata transition.
public struct ClipboardMetadataReadGate {
    private var scope:String?
    private var version:Int?
    private var allowed:Bool?
    public init() {}
    public mutating func observe(scope:String,version:Int,allowed:Bool)->Bool {
        let retry=self.scope==scope && self.version==version && self.allowed==false && allowed
        self.scope=scope;self.version=version;self.allowed=allowed
        return retry
    }
}
