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
        print(String(decoding:try JSONSerialization.data(withJSONObject:["passed":checks.count,"checks":checks,"realRime":false,"realUIKitLifecycle":false,"realDevice":false],options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
    }
}
