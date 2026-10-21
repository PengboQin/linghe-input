import AppKit
import PrivateInputKit

/// Query only the typed Latin prefix, never the host document.
enum MacEnglishDictionary {
    static func completions(_ prefix:String)->[String] {
        guard (3...32).contains(prefix.count),prefix.utf8.allSatisfy({(97...122).contains($0)}) else{return []}
        let range=NSRange(location:0,length:prefix.utf16.count),checker=NSSpellChecker.shared
        var words=checker.completions(forPartialWordRange:range,in:prefix,language:"en_US",inSpellDocumentWithTag:0) ?? []
        words += checker.guesses(forWordRange:range,in:prefix,language:"en_US",inSpellDocumentWithTag:0) ?? []
        if checker.checkSpelling(of:prefix,startingAt:0,language:"en_US",wrap:false,inSpellDocumentWithTag:0,wordCount:nil).location==NSNotFound {words.insert(prefix,at:0)}
        return words
    }
}
