import Foundation

/// Once the user can read a candidate, a background result must not move it or
/// replace its action. The next edit/document starts a fresh ranked snapshot.
/// Keeping the complete published prefix also makes later pagination monotonic.
struct StableCandidatePublication<Row, Identity: Hashable> {
    private var revision: Int?
    private var document: UUID?
    private(set) var rows: [Row] = []
    private var identities: Set<Identity> = []

    func matches(revision: Int, document: UUID?) -> Bool {
        self.revision == revision && self.document == document
    }
    mutating func reset() {
        revision = nil; document = nil; rows = []; identities = []
    }
    mutating func publish(_ incoming: [Row], revision: Int, document: UUID?, identity: (Row) -> Identity) -> [Row] {
        if !matches(revision: revision, document: document) {
            reset(); self.revision = revision; self.document = document
        }
        for row in incoming where identities.insert(identity(row)).inserted {
            rows.append(row)
        }
        return rows
    }
}

/// Explicit deletion or clear is an editing mode, not one engine revision.
/// Idle renders and cache updates cannot undo the user's cancellation.
struct DeletionPredictionLatch {
    enum CandidateSource: Equatable {case primary,continuation,none}
    private(set) var suppressed=false
    private(set) var generation:UInt64=0
    private var lastKnownDocument:UUID?
    private mutating func interrupt() {suppressed=true;generation &+= 1}
    mutating func beginDeletion() {interrupt()}
    mutating func beginClear() {interrupt()}
    mutating func beginUserInput() {suppressed=false;generation &+= 1}
    mutating func observeDocument(_ document:UUID?) {
        guard let document else{return}
        if let prior=lastKnownDocument,prior != document {suppressed=false;generation &+= 1}
        lastKnownDocument=document
    }
    func acceptsPrediction(generation:UInt64)->Bool {!suppressed && self.generation==generation}
    func source(hasComposition:Bool)->CandidateSource {
        hasComposition ? .primary:(suppressed ? .none:.continuation)
    }
}

/// Clipboard dismissal belongs to a copy, not to an input-engine revision.
/// A fresh keystroke may restore language prediction without reviving this copy.
struct ClipboardCandidateState {
    struct Request: Equatable {
        let version:Int, document:UUID, presentation:UInt64, deletion:UInt64, scope:String
    }
    private(set) var version:Int?
    private(set) var dismissedVersion:Int?
    mutating func observe(version:Int) { self.version=version }
    mutating func dismiss() { dismissedVersion=version }
    func available(version:Int, allowed:Bool, hasPrimary:Bool, deleting:Bool)->Bool {
        allowed && !hasPrimary && !deleting && self.version==version && dismissedVersion != version
    }
    func accepts(_ request:Request, current:Request?, allowed:Bool, hasPrimary:Bool, deleting:Bool)->Bool {
        current==request && available(version:request.version,allowed:allowed,hasPrimary:hasPrimary,deleting:deleting)
    }
    static func validText(_ text:String)->Bool {
        text.contains(where:{!$0.isWhitespace}) && !text.contains("\0") && text.utf8.count<=65536
    }
    static func preview(_ text:String)->String {
        String(text.split(whereSeparator:{$0.isWhitespace}).joined(separator:" ").prefix(120))
    }
}

/// Text, visible preview and action identity are one immutable publication.
/// A clipboard refresh cannot replace only the action under a held finger.
struct ClipboardCandidatePresentation {
    struct Snapshot:Equatable {
        let request:ClipboardCandidateState.Request,text:String
        var preview:String {ClipboardCandidateState.preview(text)}
    }
    private(set) var snapshot:Snapshot?
    private(set) var request:ClipboardCandidateState.Request?
    @discardableResult mutating func publish(_ next:Snapshot?,request:ClipboardCandidateState.Request?=nil,tracking:Bool)->Bool {
        guard !tracking else{return false}
        snapshot=next;self.request=next?.request ?? request;return true
    }
}
