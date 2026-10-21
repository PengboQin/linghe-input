import Foundation

/// A small, hand-authored vocabulary of ordinary words and technical names.
/// No imported third-party corpus, personal history, network, or system learning.
/// 26-key callers may supplement this list with public OS dictionary results.
public enum MixedEnglishLexicon {
    public static let words: [String] = """
    API AI UI UX ID IP IT OK PDF URL USB CPU GPU SQL HTML HTTP HTTPS JSON XML CSS SDK IDE
    App WiFi iPhone iPad iOS macOS Mac Xcode Swift GitHub GitLab WeChat QQ
    Excel Word PowerPoint Office Chrome Safari Docker Linux Windows Python Java JavaScript TypeScript
    OpenAI ChatGPT Notion Markdown Unicode UTF VPN DNS TCP UDP LAN WAN RAM ROM SSD HDD NFC GPS QR
    review meeting hello world thanks thank please sorry welcome goodbye morning afternoon evening
    today tomorrow yesterday online offline email mail message chat call video audio photo image
    file folder document text code data database server client cloud local backup restore update
    upload download install uninstall build debug test release version feature issue bug fix TODO
    design layout color style keyboard input output space enter delete clear copy paste save cancel
    open close start stop pause resume restart refresh search find select edit add remove import export
    share sync link address account password token key login logout sign support help feedback
    project product plan task work team office home school friend family time date week month year
    good great nice happy ready done yes no true false first next last new old small large fast slow
    application apple about after again also back before between change check click connect continue
    default detail device different display example information language list model name network
    number option page phone position result screen service setting simple system table value view
    """.split(whereSeparator: { $0.isWhitespace }).map(String.init)

    public static func validWord(_ value: String) -> Bool {
        (2...32).contains(value.utf8.count) && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) }
    }

    public static func suggestions(input:String,nineKey:Bool,systemWords:[String]=[]) -> [String] {
        guard !input.isEmpty,input.count<=32 else { return [] }
        let lower=input.lowercased()
        if nineKey {
            // A chosen pinyin syllable or apostrophe is an explicit constraint.
            guard NineKeySpelling.isCode(input),input.count>=2 else { return [] }
            var seen=Set<String>()
            return Array(words.filter { word in
                guard input.count>=5 || word.contains(where:{$0.isUppercase}) else { return false }
                return NineKeySpelling.encode(word)==input && seen.insert(word.lowercased()).inserted
            }.prefix(4))
        }
        guard lower.utf8.allSatisfy({ (97...122).contains($0) }),lower.count>=2 else { return [] }
        let exact=words.filter{$0.lowercased()==lower}
        let exactSystem=systemWords.filter{$0.lowercased()==lower}
        let proposed=EnglishWordSuggestions.suggestions(prefix:input,completions:systemWords,guesses:systemWords,limit:4).map{value in words.first{$0.lowercased()==value.lowercased()} ?? value}
        var seen=Set<String>()
        return Array((exact+exactSystem+proposed).filter { word in
            guard validWord(word),seen.insert(word.lowercased()).inserted else { return false }
            return word.lowercased()==lower || lower.count>=3
        }.prefix(4))
    }
}
