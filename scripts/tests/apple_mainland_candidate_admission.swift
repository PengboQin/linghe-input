import Foundation
import Darwin
import PrivateInputKit

@main struct AppleMainlandCandidateAdmissionRegression {
    static func main() throws {
        var checks=[String]()
        func require(_ value:Bool,_ name:String) throws {
            guard value else {
                print(String(decoding:try JSONSerialization.data(withJSONObject:["failed":name,"actualAppleAdmission":true,"nativeSessionCreated":false],options:[.sortedKeys]),as:UTF8.self))
                exit(1)
            }
            checks.append(name)
        }
        for text in ["有","猫猫","淘宝","天猫","吕明","深圳","GPT-5.2","apple","你好\n世界","☀️"] {
            try require(AppleCandidateAdmission.allows(text,displayable:{_ in true}),"allows-\(text)")
        }
        for text in ["貓貓","臺灣","𨈖","","\u{323B0}","\u{3FFFD}","一\u{E0101}"] {
            var renderCalls=0
            let allowed=AppleCandidateAdmission.allows(text,displayable:{_ in renderCalls+=1;return true})
            try require(!allowed,"rejects-\(text)")
            try require(renderCalls==0,"unsupported-suggestion-never-reaches-renderer-\(text)")
        }
        try require(!AppleCandidateAdmission.allows("猫猫",displayable:{_ in false}),"system-glyph-failure-remains-an-independent-veto")
        let rows=CandidateVisibilityPage<String>()
        var page=rows
        let raw=["貓貓","𨈖","猫猫","apple","臺灣","淘宝"]
        let visible=page.slice(offset:0,limit:3,accept:{AppleCandidateAdmission.allows($0,displayable:{_ in true})},source:{offset,limit in Array(raw.dropFirst(offset).prefix(limit))})
        try require(visible==["猫猫","apple","淘宝"],"filtered-source-still-fills-three-visible-slots-without-renumbering-source")
        let historical=LearningEntry(reading:"xiao han",text:"小厂",counts:["synthetic-owner":9],pinned:true,
            pinVersion:.init(sequence:1,device:"synthetic-owner"))
        try historical.validate()
        let recordEncoder=JSONEncoder();recordEncoder.outputFormatting=[.sortedKeys]
        let historicalBytes=try recordEncoder.encode(historical)
        let candidates=[
            InputCandidate(text:"小厂",comment:"xiao han",index:0),
            InputCandidate(text:historical.text,comment:historical.reading,index:1,learnedPreference:true),
            InputCandidate(text:"小厂",comment:"xiao han",index:-30,assemblyID:7),
            InputCandidate(text:"小厂",comment:"xiao han",index:-40,replacementInput:"xiaohan"),
            InputCandidate(text:"小厂",comment:"xiao chang",index:4),
            InputCandidate(text:"小寒",comment:"xiao han",index:5),
            InputCandidate(text:"小厂",comment:"xiao han",index:-60,personalID:UUID()),
            InputCandidate(text:"apple",comment:"xiao han",index:-70,latinInput:"apple"),
            InputCandidate(text:"小厂",comment:"xiao han",index:-80,supplementaryTrigger:"xiaohan"),
            InputCandidate(text:"小厂",comment:"xiao han",index:-90,continuationContext:"天气"),
            InputCandidate(text:"小厂",comment:"",index:-2),
            InputCandidate(text:"小厂",comment:"xiao",index:11),
            InputCandidate(text:"小厂",comment:"未提供读音",index:12)]
        func fields(_ rows:[InputCandidate])->[[String]] {
            rows.map{[$0.text,$0.comment,String($0.index),String($0.learnedPreference),String($0.assemblyID ?? -1),
                $0.replacementInput ?? "",$0.personalID?.uuidString ?? "",$0.latinInput ?? "",$0.supplementaryTrigger ?? "",$0.continuationContext ?? ""]}
        }
        let originalFields=fields(candidates)
        func accepts(_ row:InputCandidate)->Bool {
            AppleCandidateAdmission.allows(row,candidateIsDisplayable:{AppleCandidateAdmission.allows($0,displayable:{_ in true})})
        }
        try require(!accepts(candidates[0]),"ordinary-native-reading-pollution-is-rejected")
        try require(!accepts(candidates[1]),"old-learned-or-pinned-automatic-row-cannot-bypass-reading-policy")
        try require(!accepts(candidates[2]),"automatic-assembly-reading-pollution-is-rejected")
        try require(!accepts(candidates[3]),"automatic-prediction-reading-pollution-is-rejected")
        for index in 4..<candidates.count {try require(accepts(candidates[index]),"retains-correct-explicit-or-unknown-row-\(index)")}
        try require(!AppleCandidateAdmission.allows(candidates[6],candidateIsDisplayable:{_ in false}),"personal-alias-still-respects-existing-display-veto")
        let hiddenPersonal=InputCandidate(text:"貓貓",comment:"mao mao",index:-61,personalID:UUID())
        try require(!accepts(hiddenPersonal),"explicit-reading-bypass-does-not-bypass-existing-text-admission")
        var candidatePage=CandidateVisibilityPage<InputCandidate>()
        let candidateRows=candidatePage.slice(offset:0,limit:9,accept:accepts,source:{offset,limit in Array(candidates.dropFirst(offset).prefix(limit))})
        try require(candidateRows.map(\.index)==candidates.dropFirst(4).map(\.index),"production-visibility-filter-fills-holes-and-preserves-source-IDs")
        try require(fields(candidates)==originalFields,"filter-does-not-rewrite-source-rows-or-learnt-records")
        try require(historical.pinned && historical.counts["synthetic-owner"]==9,"historical-pin-and-counter-remain-intact-after-admission")
        try require(try recordEncoder.encode(historical)==historicalBytes,"historical-learning-record-bytes-are-not-rewritten")
        print(String(decoding:try JSONSerialization.data(withJSONObject:["passed":checks.count,"checks":checks,"actualCoreABI":true,"actualAppleAdmission":true,"nativeSessionCreated":false,"realDevice":false,"fullNativeEngineIntegration":false],options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
    }
}
