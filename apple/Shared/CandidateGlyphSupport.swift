import Foundation
import CoreText
import CryptoKit

/// Only candidates with real system-font glyphs are presented. This is a local
/// rendering policy, not a Unicode-plane blacklist or a user-dictionary edit.
enum CandidateGlyphSupport {
    private static let font = CTFontCreateUIFontForLanguage(.system,15,nil)!
    private static let cache: NSCache<NSString,NSNumber> = {
        let value=NSCache<NSString,NSNumber>();value.countLimit=512;return value
    }()
    static func supports(_ text:String)->Bool {
        let key=SHA256.hash(data:Data(text.utf8)).map{String(format:"%02x",$0)}.joined() as NSString
        if let saved=cache.object(forKey:key) {return saved.boolValue}
        let value=supports(text,font:font)
        cache.setObject(NSNumber(value:value),forKey:key)
        return value
    }
    static func clearCache() {cache.removeAllObjects()}
    static func supports(_ text:String,font:CTFont)->Bool {
        guard !text.isEmpty else {return false}
        let attributed=NSAttributedString(string:text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font])
        let line=CTLineCreateWithAttributedString(attributed),source=text as NSString
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attributes=CTRunGetAttributes(run) as NSDictionary
            guard let value=attributes[kCTFontAttributeName] else {return false}
            let actual=value as! CTFont,range=CTRunGetStringRange(run)
            if (CTFontCopyPostScriptName(actual) as String).contains("LastResort"),
               range.location>=0,range.length>0,range.location+range.length<=source.length,
               source.substring(with:NSRange(location:range.location,length:range.length)).unicodeScalars.contains(where:visible) {return false}
            let count=CTRunGetGlyphCount(run)
            var glyphs=[CGGlyph](repeating:0,count:count),indices=[CFIndex](repeating:0,count:count)
            CTRunGetGlyphs(run,CFRange(location:0,length:0),&glyphs)
            CTRunGetStringIndices(run,CFRange(location:0,length:0),&indices)
            for i in glyphs.indices where glyphs[i]==0 {
                let position=indices[i]
                guard position>=0,position<source.length else {continue}
                let range=source.rangeOfComposedCharacterSequence(at:position)
                if source.substring(with:range).unicodeScalars.contains(where:visible) {return false}
            }
        }
        return true
    }
    private static func visible(_ value:Unicode.Scalar)->Bool {
        if (0xFE00...0xFE0F).contains(value.value) || (0xE0100...0xE01EF).contains(value.value) {return false}
        switch value.properties.generalCategory {
        case .control,.format,.spaceSeparator,.lineSeparator,.paragraphSeparator:return false
        default:return true
        }
    }
}

/// Visible offsets are independent of native candidate IDs. Fill gaps left by
/// unsupported glyphs without repeating or skipping subsequent native rows.
struct CandidateVisibilityPage<Row> {
    private(set) var rows:[Row]=[]
    private(set) var sourceOffset=0
    private(set) var exhausted=false
    mutating func slice(offset:Int,limit:Int,maximumBatches:Int = .max,sourceMayContinue:()->Bool = {false},accept:(Row)->Bool,source:(Int,Int)->[Row])->[Row] {
        guard offset>=0,limit>0,maximumBatches>0,offset<=Int.max-limit else {return []}
        var batches=0
        while rows.count<offset+limit && !exhausted && batches<maximumBatches {
            let batch=source(sourceOffset,64)
            rows.append(contentsOf:batch.filter(accept));sourceOffset+=batch.count
            exhausted=batch.count<64 && !sourceMayContinue()
            batches+=1
            // A budgeted native source may have scanned only rejected rows.
            // Keep this visible offset, yield, then retry in a later UI turn.
            if batch.isEmpty && !exhausted {break}
        }
        return Array(rows.dropFirst(offset).prefix(limit))
    }
}
