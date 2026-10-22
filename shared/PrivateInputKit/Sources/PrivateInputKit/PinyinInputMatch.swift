import Foundation

/// Matches real pinyin, initial abbreviations and an unfinished final syllable.
/// It never expands arbitrary Latin text or changes the supplied spelling.
public enum PinyinInputMatch {
    /// Alphabetic presentation tiers match core/pinyin_text.h. Context and
    /// personal scores cannot move an edited spelling above an unedited path.
    /// Digit codes deliberately retain their independent nine-key policy.
    public static func candidatePriority(_ input:String,reading:String,corrected:Bool=false)->Int {
        let raw=input.lowercased().replacingOccurrences(of:"ü",with:"v").replacingOccurrences(of:"'",with:"").replacingOccurrences(of:" ",with:"")
        guard !raw.isEmpty,raw.utf8.allSatisfy({(97...122).contains($0)}) else{return 0}
        if corrected {return 1}
        if isFullSpelling(raw,reading:reading) {return 3}
        let mostlyFull=raw.count>=7 && raw.contains(where:{"aeiouv".contains($0)})
        return covers(raw,reading:reading,maxAbbreviations:mostlyFull ? 1:Int.max) ? 2:0
    }
    public static func canonicalSyllable(_ value:String)->String {
        let value=value.lowercased().replacingOccurrences(of:"ü",with:"v")
        return value=="lue" ? "lve":(value=="nue" ? "nve":value)
    }
    private static func fullForms(_ syllable:String)->Set<String> {
        let value=canonicalSyllable(syllable)
        return value=="lve" ? [value,"lue"]:(value=="nve" ? [value,"nue"]:[value])
    }
    public static func isFullSpelling(_ input:String,reading:String)->Bool {
        let raw=input.lowercased().replacingOccurrences(of:"ü",with:"v").replacingOccurrences(of:"'",with:"").replacingOccurrences(of:" ",with:"")
        let parts=reading.split(whereSeparator:{$0==" " || $0=="'"}).map(String.init)
        guard !raw.isEmpty,raw.count<=128,!parts.isEmpty else{return false}
        var positions:Set<Int>=[0]
        for part in parts {
            var next=Set<Int>()
            for start in positions {for form in fullForms(part) where raw.dropFirst(start).hasPrefix(form) {next.insert(start+form.count)}}
            positions=next
        }
        return positions.contains(raw.count)
    }
    /// Longest prefix consumed by these syllables, including initials mixed
    /// with full spellings. Unmatched trailing keys always remain editable.
    public static func consumedPrefix(_ input:String,reading:String,nineKey:Bool)->Int? {
        let raw=input.lowercased().replacingOccurrences(of:"ü",with:"v")
        let parts=reading.lowercased().split(whereSeparator:{$0==" " || $0=="'"}).map(String.init)
        guard !raw.isEmpty,raw.count<=128,!parts.isEmpty,parts.count<=64,
              raw.utf8.allSatisfy({nineKey ? (50...57).contains($0):(97...122).contains($0)}) else{return nil}
        var positions:Set<Int>=[0]
        for (index,part) in parts.enumerated() {
            guard part.utf8.allSatisfy({(97...122).contains($0)}) else{return nil}
            func encode(_ text:String)->String {nineKey ? (NineKeySpelling.encode(text) ?? ""):text}
            let full=encode(part)
            var forms=Set(fullForms(part).map(encode));forms.insert(encode(String(part.prefix(1))))
            if part.hasPrefix("zh") || part.hasPrefix("ch") || part.hasPrefix("sh") {forms.insert(encode(String(part.prefix(2))))}
            var next=Set<Int>()
            for position in positions where position<raw.count {
                let suffix=String(raw.dropFirst(position))
                if index==parts.count-1,full.hasPrefix(suffix) {next.insert(raw.count)}
                for form in forms where !form.isEmpty && suffix.hasPrefix(form) {next.insert(position+form.count)}
            }
            positions=next;if positions.isEmpty{return nil}
        }
        return positions.max()
    }
    public static func covers(_ input:String,reading:String,maxAbbreviations:Int=Int.max)->Bool {
        let raw=input.lowercased().replacingOccurrences(of:"ü",with:"v").replacingOccurrences(of:"'",with:"").replacingOccurrences(of:" ",with:"")
        let parts=reading.lowercased().split(whereSeparator:{$0==" " || $0=="'"}).map(String.init)
        guard !raw.isEmpty,raw.count<=96,!parts.isEmpty,parts.count<=32 else{return false}
        var positions:[Int:Int]=[0:0]
        for (index,part) in parts.enumerated() {
            var next:[Int:Int]=[:]
            for (position,abbreviations) in positions where position<raw.count {
                let suffix=String(raw.dropFirst(position))
                var forms=fullForms(part);forms.insert(String(part.prefix(1)))
                if part.hasPrefix("zh") || part.hasPrefix("ch") || part.hasPrefix("sh") {forms.insert(String(part.prefix(2)))}
                if index==parts.count-1,part.hasPrefix(suffix) {
                    let cost=abbreviations+(suffix==part ? 0:1)
                    if cost<=maxAbbreviations {next[raw.count]=min(next[raw.count] ?? Int.max,cost)}
                }
                for form in forms where suffix.hasPrefix(form) {
                    let cost=abbreviations+(fullForms(part).contains(form) ? 0:1),end=position+form.count
                    if cost<=maxAbbreviations {next[end]=min(next[end] ?? Int.max,cost)}
                }
            }
            positions=next
            if positions.isEmpty {return false}
        }
        return positions[raw.count] != nil
    }
}

/// Ephemeral model context. Callers must exclude marked/selected text.
public struct SurroundingText:Equatable {
    public let before:String
    public let after:String
    public init(before:String,after:String) {self.before=String(before.suffix(20));self.after=String(after.prefix(20))}
    public static func ranges(selection:NSRange,marked:NSRange,length:Int)->(before:NSRange,after:NSRange)? {
        guard length>=0,length != NSNotFound,selection.location>=0,selection.length>=0,selection.location != NSNotFound,selection.location<=length,
              selection.length<=length-selection.location else{return nil}
        let anchor: NSRange
        if marked.location>=0,marked.length>0,marked.location != NSNotFound,marked.location<=length,marked.length<=length-marked.location {anchor=marked}
        else {anchor=selection}
        // Read at most 80 UTF-16 units per side so emoji are bounded as well.
        let start=max(0,anchor.location-80),end=anchor.location+anchor.length
        return (NSRange(location:start,length:anchor.location-start),NSRange(location:end,length:min(80,length-end)))
    }
}
