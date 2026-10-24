import Foundation

@main struct LearningMaintenanceBoundaryRegression {
    static func main() throws {
        var checks = [String]()
        func require(_ value:Bool,_ name:String) throws {
            guard value else {throw NSError(domain:"LearningMaintenanceBoundary",code:1,userInfo:[NSLocalizedDescriptionKey:name])}
            checks.append(name)
        }
        var boundary=LearningMaintenanceBoundary()
        try require(!boundary.permits(0,hasComposition:false,interacting:false),"initial-state-is-not-a-hidden-grant")
        boundary.willAppear()
        try require(!boundary.permits(0,hasComposition:false,interacting:false),"visible-empty-keyboard-never-grants-maintenance")
        boundary.willDisappear()
        try require(!boundary.permits(2,hasComposition:false,interacting:false),"dismissal-animation-is-not-a-maintenance-window")
        guard let first=boundary.didDisappear() else {throw NSError(domain:"LearningMaintenanceBoundary",code:2)}
        try require(boundary.permits(first,hasComposition:false,interacting:false),"completed-dismissal-can-checkpoint-empty-session")
        try require(!boundary.permits(first,hasComposition:true,interacting:false),"hidden-draft-is-never-cleared-for-maintenance")
        try require(!boundary.permits(first,hasComposition:false,interacting:true),"held-control-blocks-hidden-maintenance")
        boundary.willAppear()
        try require(!boundary.permits(first,hasComposition:false,interacting:false),"reveal-cancels-background-preparation-token")
        boundary.willDisappear()
        guard let next=boundary.didDisappear() else {throw NSError(domain:"LearningMaintenanceBoundary",code:3)}
        try require(next != first,"second-dismissal-has-new-token")
        try require(!boundary.permits(first,hasComposition:false,interacting:false),"late-first-preflight-cannot-run-in-next-dismissal")
        try require(boundary.permits(next,hasComposition:false,interacting:false),"new-hidden-session-can-retry-deferred-work")
        try require(boundary.didDisappear()==nil,"duplicate-dismissal-cannot-start-another-job")
        boundary.willAppear();boundary.willDisappear();boundary.willAppear()
        try require(boundary.didDisappear()==nil,"cancelled-dismissal-cannot-override-a-new-reveal")

        // Actual iOS88 trace: one owner completes dismissal, schedules work,
        // then receives another willDisappear without an intervening reveal.
        // Exercise the production boundary, with no clock/sleep or UIKit mock.
        var observed=LearningMaintenanceBoundary(), control=LearningMaintenanceBoundary()
        observed.willAppear();control.willAppear()
        let firstTeardown=observed.willDisappear()
        try require(firstTeardown,"visible-dismissal-owns-teardown-once")
        try require(control.willDisappear(),"control-visible-dismissal-is-admitted")
        try require(!observed.willDisappear(),"duplicate-will-disappear-before-did-disappear-does-not-own-teardown")
        guard let observedToken=observed.didDisappear(),let controlToken=control.didDisappear() else {
            throw NSError(domain:"LearningMaintenanceBoundary",code:4)
        }
        try require(observedToken==controlToken,"pre-completion-duplicate-does-not-advance-hidden-token")
        let queuedToken=observedToken
        try require(observed.permits(queuedToken,hasComposition:false,interacting:false),"completed-dismissal-grants-queued-maintenance")
        try require(!observed.willDisappear(),"observed-post-completion-duplicate-does-not-own-teardown")
        try require(observed.permits(queuedToken,hasComposition:false,interacting:false),"observed-duplicate-preserves-already-queued-maintenance")
        try require(observed.didDisappear()==nil,"duplicate-did-disappear-cannot-queue-another-maintenance")
        try require(observed.permits(queuedToken,hasComposition:false,interacting:false),"duplicate-did-disappear-also-preserves-existing-grant")
        for _ in 0..<3 {
            try require(!observed.willDisappear(),"repeated-hidden-callbacks-never-repeat-controller-teardown")
        }
        try require(observed.permits(queuedToken,hasComposition:false,interacting:false),"all-hidden-duplicates-leave-preparation-eligible")
        observed.willAppear()
        try require(!observed.permits(queuedToken,hasComposition:false,interacting:false),"actual-reveal-invalidates-old-queued-token")
        try require(observed.willDisappear(),"new-real-dismissal-again-owns-controller-teardown")
        guard let laterToken=observed.didDisappear() else {throw NSError(domain:"LearningMaintenanceBoundary",code:5)}
        try require(laterToken != queuedToken,"new-real-dismissal-gets-new-hidden-token")
        try require(!observed.permits(queuedToken,hasComposition:false,interacting:false),"old-preflight-stays-invalid-in-new-hidden-period")
        try require(observed.permits(laterToken,hasComposition:false,interacting:false),"new-hidden-token-remains-usable")
        try require(!observed.permits(laterToken,hasComposition:true,interacting:false),"idempotence-does-not-allow-hidden-draft-destruction")
        try require(!observed.permits(laterToken,hasComposition:false,interacting:true),"idempotence-does-not-bypass-interaction-gate")
        // Physical93 completed export, then its weak controller disappeared
        // before pure preparation returned. Retaining that owner must not let
        // a different controller's reveal reuse the old hidden grant.
        var process=LearningPresentationFence(), retained=LearningMaintenanceBoundary()
        process.advance();retained.willAppear();retained.willDisappear()
        let hidden=try { () throws -> UInt64 in guard let value=retained.didDisappear() else {throw NSError(domain:"LearningMaintenanceBoundary",code:6)};return value }()
        let captured=process.generation
        try require(process.permits(captured) && retained.permits(hidden,hasComposition:false,interacting:false),"admitted-owner-can-finish-while-still-hidden")
        try require(!retained.willDisappear() && process.permits(captured),"duplicate-hide-does-not-revoke-process-generation")
        process.advance() // Another controller's loadView, before native startup.
        try require(!process.permits(captured),"new-controller-cancels-retained-hidden-owner")
        try require(retained.permits(hidden,hasComposition:false,interacting:false),"old-owner-local-boundary-alone-is-insufficient")
        let nextProcess=process.generation
        process.advance() // Its subsequent viewWillAppear also fences old work.
        try require(!process.permits(nextProcess),"revealing-any-controller-invalidates-older-work")
        let currentProcess=process.generation
        try require(process.permits(currentProcess),"new-current-generation-remains-usable")
        try require(!retained.permits(hidden,hasComposition:true,interacting:false),"process-fence-cannot-authorize-an-uncommitted-draft")
        try require(!retained.permits(hidden,hasComposition:false,interacting:true),"process-fence-cannot-authorize-held-touch")
        print(String(decoding:try JSONSerialization.data(withJSONObject:["passed":checks.count,"checks":checks,"realRime":false,"realUIKitLifecycle":false,"realDevice":false],options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
    }
}
