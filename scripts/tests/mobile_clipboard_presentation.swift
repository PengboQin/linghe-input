import Foundation
@main enum MobileClipboardChecks {
    static func main() throws {
        let vectors=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [String:Any]
        var assertions=0,covered=0
        func check(_ ok:Bool,_ name:String) {precondition(ok,name);assertions+=1}
        for row in vectors["cases"] as! [[String:Any]] {
            // Remote/local-copy race and persistent HMAC receipts are validated
            // by their own bridge/store tests, not inferred by this UI policy.
            if row["localCopyVersion"] != nil || (row["reason"] as? String)?.hasPrefix("persistent content") == true {continue}
            let name=row["name"] as! String
            var activity=ClipboardCandidateActivity(),state=ClipboardCandidateState()
            let time:Double
            if let milliseconds=row["recentInputMsAgo"] as? Double {activity.noteInput(at:0);time=milliseconds/1000}else{time=0}
            let hasComposition=(row["hasComposition"] as? Bool==true)||(row["englishWord"] as? Bool==true)
            let interaction=(row["pressed"] as? Bool==true)||(row["deleteHeld"] as? Bool==true)||(row["queuedInput"] as? Int ?? 0)>0
            let idle=activity.mayPresent(at:time,hasComposition:hasComposition,hasInteraction:interaction)
            state.observe(version:1,automaticEligible:idle)
            if row["copyConsumed"] as? Bool==true {state.dismiss()}
            let visible=state.available(version:1,allowed:row["safe"] as? Bool==true,hasPrimary:hasComposition,deleting:!idle)
            check(visible==row["present"] as? Bool,name)
            if !idle {
                state.observe(version:1,automaticEligible:true)
                check(!state.available(version:1,allowed:true,hasPrimary:false,deleting:false),"busy copy never pops up later: "+name)
            }
            covered+=1
        }
        var state=ClipboardCandidateState(),language=DeletionPredictionLatch()
        state.observe(version:1);state.dismiss();language.beginClear()
        state.observe(version:1)
        check(!state.available(version:1,allowed:true,hasPrimary:false,deleting:false),"dismissed copy stays consumed")
        state.observe(version:2,automaticEligible:true)
        check(language.suppressed && state.available(version:2,allowed:true,hasPrimary:false,deleting:false),"new idle copy independent of suppressed language predictions")
        print("MOBILE_CLIPBOARD_VECTOR_CASES=\(covered) ASSERTIONS=\(assertions)")
    }
}
