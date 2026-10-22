import Foundation

@main struct AppleMainlandCandidateAdmissionRegression {
    static func main() throws {
        var checks=[String]()
        func require(_ value:Bool,_ name:String) throws {
            guard value else {throw NSError(domain:"AppleMainlandCandidateAdmission",code:1,userInfo:[NSLocalizedDescriptionKey:name])}
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
        print(String(decoding:try JSONSerialization.data(withJSONObject:["passed":checks.count,"checks":checks,"actualCoreABI":true,"actualAppleAdmission":true,"nativeSessionCreated":false,"realDevice":false,"fullNativeEngineIntegration":false],options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
    }
}
