import Foundation

/// Cache work has its own lifetime. A cache refresh must not invalidate a
/// visible button's copy/document identity or let an old completion cancel a
/// newer load. This policy performs no I/O and is independent of UIKit.
struct ClipboardCandidateLoadState {
    struct Observation:Equatable {
        let version:Int,scope:String,generation:String
    }
    struct Ticket:Equatable {
        let id:UUID,request:ClipboardCandidateState.Request
    }
    private let maximumAttempts:Int
    private var observation:Observation?
    private var active:Ticket?
    private(set) var attempts=0
    init(maximumAttempts:Int=3) {
        precondition(maximumAttempts>0);self.maximumAttempts=maximumAttempts
    }
    /// Return whether a prior text snapshot belongs to a different copy/scope.
    mutating func observe(version:Int,scope:String,generation:String)->Bool {
        let next=Observation(version:version,scope:scope,generation:generation)
        let changedCopy=observation?.version != version || observation?.scope != scope
        if observation != next {observation=next;active=nil;attempts=0}
        return changedCopy
    }
    mutating func begin(request:ClipboardCandidateState.Request,eligible:Bool)->Ticket? {
        guard eligible,active==nil,attempts<maximumAttempts,
              observation?.version==request.version,observation?.scope==request.scope else{return nil}
        let ticket=Ticket(id:UUID(),request:request);active=ticket;attempts+=1;return ticket
    }
    mutating func finish(_ ticket:Ticket)->Bool {
        guard active==ticket else{return false};active=nil;return true
    }
    mutating func cancel() {active=nil}
    mutating func leavePresentation() {active=nil;observation=nil;attempts=0}
}
