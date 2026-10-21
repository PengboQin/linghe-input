import Foundation

public enum NineKeySpelling {
    public static func encode(_ reading: String) -> String? {
        let map=Array("22233344455566677778889999")
        var output=""
        for c in reading.lowercased() {
            if c == " " || c == "'" { continue }
            guard let value=c.asciiValue, value >= 97 && value <= 122 else { return nil }
            output.append(map[Int(value-97)])
        }
        return output.isEmpty ? nil : output
    }
    public static func isCode(_ input: String) -> Bool {
        !input.isEmpty && input.allSatisfy { "23456789".contains($0) }
    }
    public static func rawCode(_ input:String) -> String? {
        var output=""
        for c in input {
            if c == "'" || c == " " { continue }
            if "23456789".contains(c) { output.append(c) }
            else if let value=encode(String(c)) { output+=value }
            else { return nil }
        }
        return output.isEmpty ? nil:output
    }
    /// Categories share the query budget, so added/missing keys are not starved
    /// by the much larger pool of neighboring-key substitutions.
    public static func alternatives(_ input: String, limit: Int = 32) -> [(input: String, cost: Double)] {
        guard isCode(input), (2...12).contains(input.count), limit > 0 else { return [] }
        let source=Array(input);var buckets=[[(String,Double)]](repeating:[],count:4)
        var seen=Set([input])
        func add(_ chars:[Character],_ cost:Double,_ category:Int) {
            let code=String(chars);if seen.insert(code).inserted { buckets[category].append((code,cost)) }
        }
        for i in source.indices.reversed() {
            let d=Int(String(source[i]))!,r=(d-1)/3,c=(d-1)%3
            for n in 2...9 where n != d {
                let dr=abs((n-1)/3-r),dc=abs((n-1)%3-c)
                if dr<=1 && dc<=1 { var chars=source;chars[i]=Character(String(n));add(chars,dr+dc==1 ? 1:1.4,0) }
            }
            var shorter=source;shorter.remove(at:i)
            let repeated=(i>0 && source[i-1]==source[i]) || (i+1<source.count && source[i+1]==source[i])
            add(shorter,repeated ? 0.9:1.5,1)
        }
        // A missed second identical key is common, but it is only a hypothesis;
        // real double keys always remain in the original candidate stream.
        for i in source.indices.reversed() { var chars=source;chars.insert(source[i],at:i);add(chars,1.1,2) }
        for i in 0..<(source.count-1) where source[i] != source[i+1] {
            var chars=source;chars.swapAt(i,i+1);add(chars,1.2,3)
        }
        for i in (0...source.count).reversed() {
            for n in 2...9 { var chars=source;chars.insert(Character(String(n)),at:i);add(chars,1.7,2) }
        }
        var result:[(String,Double)]=[],positions=[0,0,0,0]
        while result.count<min(limit,128) {
            var advanced=false
            for b in buckets.indices where positions[b]<buckets[b].count {
                result.append(buckets[b][positions[b]]);positions[b]+=1;advanced=true
                if result.count==min(limit,128) { break }
            }
            if !advanced { break }
        }
        return result
    }
    public static func editCost(_ source:String,_ target:String) -> Double? {
        guard isCode(source),isCode(target),source.count<=128,target.count<=129 else { return nil }
        if source==target { return 0 }
        let a=Array(source),b=Array(target)
        if a.count==b.count {
            let indices=a.indices.filter { a[$0] != b[$0] }
            if indices.count==1 {
                let i=indices[0],x=Int(String(a[i]))!,y=Int(String(b[i]))!
                let dr=abs((x-1)/3-(y-1)/3),dc=abs((x-1)%3-(y-1)%3)
                return dr<=1 && dc<=1 ? (dr+dc==1 ? 1:1.4):nil
            }
            if indices.count==2,indices[1]==indices[0]+1,a[indices[0]]==b[indices[1]],a[indices[1]]==b[indices[0]] { return 1.2 }
            return nil
        }
        if abs(a.count-b.count)==1 {
            let longer=a.count>b.count ? a:b,shorter=a.count>b.count ? b:a
            var i=0,j=0,skipped=false
            while i<longer.count && j<shorter.count {
                if longer[i]==shorter[j] { i+=1;j+=1 }
                else if !skipped { i+=1;skipped=true } else { return nil }
            }
            return 1.5
        }
        return nil
    }
    /// Independent two-operation validation, not membership in a truncated query list.
    /// Banded optimal-string-alignment distance keeps swaps atomic and rejects
    /// non-neighbor substitutions. A third edit never becomes a learned rule.
    public static func jointEditCost(_ source:String,_ target:String) -> Double? {
        if let cost=editCost(source,target) { return cost }
        guard isCode(source),isCode(target),source.count<=128,target.count<=128,abs(source.count-target.count)<=2 else { return nil }
        let a=Array(source),b=Array(target),width=b.count+1
        var previous2=[Double](repeating:.infinity,count:width*3)
        var previous=previous2
        for j in 0...min(2,b.count) { previous[j*3+j]=Double(j)*1.5 }
        for i in 1...a.count {
            var current=[Double](repeating:.infinity,count:width*3)
            if i<=2 { current[i]=Double(i)*1.5 }
            let lo=max(1,i-2),hi=min(b.count,i+2)
            if lo<=hi { for j in lo...hi {
                for edits in 0...2 {
                    if a[i-1]==b[j-1] { current[j*3+edits]=min(current[j*3+edits],previous[(j-1)*3+edits]) }
                    guard edits>0 else { continue }
                    current[j*3+edits]=min(current[j*3+edits],previous[j*3+edits-1]+1.5,current[(j-1)*3+edits-1]+1.5)
                    let x=Int(String(a[i-1]))!,y=Int(String(b[j-1]))!
                    let dr=abs((x-1)/3-(y-1)/3),dc=abs((x-1)%3-(y-1)%3)
                    if x != y,dr<=1,dc<=1 { current[j*3+edits]=min(current[j*3+edits],previous[(j-1)*3+edits-1]+(dr+dc==1 ? 1:1.4)) }
                    if i>1,j>1,a[i-1]==b[j-2],a[i-2]==b[j-1] { current[j*3+edits]=min(current[j*3+edits],previous2[(j-2)*3+edits-1]+1.2) }
                }
            } }
            previous2=previous;previous=current
        }
        let cost=previous[(b.count)*3...b.count*3+2].min()!
        return cost.isFinite ? cost:nil
    }
    public static func isRelated(_ first:String,_ second:String) -> Bool { jointEditCost(first,second) != nil }

}

/// Local-only confirmed choices. This format is separate from the synchronized
/// word-frequency archive; neither surrounding host text nor typing traces enter it.
public struct NineKeyChoiceMemory: Codable, Equatable {
    public struct Entry: Codable, Equatable {
        public var code, reading, text, context: String
        public var count: Int
    }
    public var version=3
    public private(set) var entries:[Entry]=[]
    public init() {}
    public func validate() throws {
        guard (1...3).contains(version), entries.count <= (version==1 ? 512:1024) else { throw InputDataError.incompatibleSchema }
        var keys=Set<String>()
        for e in entries {
            guard (1...(version==1 ? 24:128)).contains(e.code.count), NineKeySpelling.isCode(e.code),
                  e.reading.utf8.count<=512,let target=NineKeySpelling.encode(e.reading), (version<3 ? NineKeySpelling.editCost(e.code,target):NineKeySpelling.jointEditCost(e.code,target)) != nil,
                  !e.text.isEmpty, e.text.utf8.count <= 256, !e.text.contains("\u{001F}"),
                  !e.text.contains("\n"),!e.text.contains("\r"),!e.text.contains("\0"),
                  e.context.count <= (version==1 ? 4:12), e.count > 0, e.count <= 1000,
                  keys.insert(e.code+"\u{001F}"+e.reading+"\u{001F}"+e.text+"\u{001F}"+e.context).inserted else { throw InputDataError.invalidRecord }
        }
    }
    public mutating func record(code:String,reading:String,text:String,context:String,strength:Int=1) throws {
        guard (1...3).contains(strength) else { throw InputDataError.invalidRecord }
        var next=self;next.version=3
        let reading=reading.lowercased().replacingOccurrences(of:" ",with:"").replacingOccurrences(of:"'",with:""),context=SentenceContextWindow.preferenceContext(context)
        if let index=next.entries.firstIndex(where: { $0.code==code && $0.reading==reading && $0.text==text && $0.context==context }) {
            var entry=next.entries.remove(at:index);entry.count=min(1000,entry.count+strength);next.entries.append(entry)
        } else {
            if next.entries.count >= 1024 { next.entries.removeFirst() }
            next.entries.append(.init(code:code,reading:reading,text:text,context:context,count:strength))
        }
        try next.validate();self=next
    }
    public mutating func recordCorrection(code:String,reading:String,text:String,context:String) throws {
        let normalized=reading.lowercased().replacingOccurrences(of:" ",with:"").replacingOccurrences(of:"'",with:"")
        let local=SentenceContextWindow.preferenceContext(context)
        let prior=entries.filter{$0.code==code && $0.reading==normalized && $0.context==local}.map(\.count).max() ?? 0
        var next=self;try next.record(code:code,reading:reading,text:text,context:context,strength:3)
        if let i=next.entries.lastIndex(where:{$0.code==code && $0.reading==normalized && $0.text==text && $0.context==local}) { next.entries[i].count=min(1000,max(next.entries[i].count,prior+3)) }
        try next.validate();self=next
    }
    public func boost(code:String,reading:String,text:String,context:String) -> Double {
        let reading=reading.lowercased().replacingOccurrences(of:" ",with:"").replacingOccurrences(of:"'",with:"")
        let rawContext=String(context.suffix(12)),context=SentenceContextWindow.preferenceContext(context)
        let matching=entries.filter{$0.code==code && $0.reading==reading && $0.text==text}
        let exact=matching.filter{$0.context==context || $0.context==rawContext}.map(\.count).max() ?? 0
        let short=matching.filter{!$0.context.isEmpty && $0.context.count<=4 && context.hasSuffix($0.context)}.map(\.count).max() ?? 0
        let total=min(1000,matching.reduce(0){$0+$1.count})
        // Transfer only a modest preference when the immediate phrase ending is
        // shared. Empty/different sentence contexts do not acquire this boost.
        let backoff=matching.compactMap { entry -> Double? in
            let normalized=SentenceContextWindow.preferenceContext(entry.context)
            let common=zip(context.reversed(),normalized.reversed()).prefix{$0==$1}.count
            guard common>=2,entry.count>=2 else { return nil }
            return min(4,log1p(Double(entry.count))*Double(min(common,6))/3)
        }.max() ?? 0
        let local=max(backoff,min(8,log1p(Double(exact))*3),min(6,log1p(Double(short))*2.5))
        let general=total>=2 ? min(4,log1p(Double(total))*1.2):0
        return max(local,general)
    }
    public func migrated() throws -> Self { try validate();var result=self;result.version=3;try result.validate();return result }

    public mutating func reset(text:String,reading:String) {
        entries.removeAll { $0.text==text && NineKeySpelling.encode($0.reading)==NineKeySpelling.encode(reading) }
    }
}

/// Recognizes a fully removed, recent *own* commit. Anchors are opaque digests
/// supplied by the frontend; arbitrary host edits never create training records.
public struct OwnCommitCorrectionTracker {
    public struct Replacement { public let code, context, rejectedText:String;public let reading:String? }
    private struct Commit {
        var document,anchor,remaining,code,context,original:String
        var reading:String?
        var time:TimeInterval
    }
    private var commit:Commit?
    public init() {}
    public mutating func stage(document:String,anchor:String?,text:String,code:String,context:String,time:TimeInterval,reading:String?=nil) {
        guard let anchor, NineKeySpelling.isCode(code), !text.isEmpty else { invalidate();return }
        commit=Commit(document:document,anchor:anchor,remaining:text,code:code,context:context,original:text,reading:reading,time:time)
    }
    public mutating func invalidate() { commit=nil }
    public func expectedText(document:String,time:TimeInterval) -> String? {
        guard let c=commit,c.document==document,time-c.time>=0,time-c.time<=120 else { return nil }
        return c.remaining
    }
    public func partiallyDeleted(document:String,anchor:String?,time:TimeInterval) -> Replacement? {
        guard let c=commit,c.document==document,c.anchor==anchor,time>=c.time,time-c.time<=120,
              c.remaining.count<c.original.count,!c.remaining.isEmpty,let reading=c.reading else { return nil }
        let syllables=reading.lowercased().split(whereSeparator:{$0.isWhitespace || $0=="'"}).map(String.init)
        // Only an exact one-syllable-per-character alignment permits a suffix
        // correction signal. No guessed reading for an arbitrary host edit.
        guard syllables.count==c.original.count,NineKeySpelling.encode(reading)==c.code else { return nil }
        let n=c.original.count-c.remaining.count,tail=syllables.suffix(n).joined(separator:" ")
        guard let code=NineKeySpelling.encode(tail) else { return nil }
        return Replacement(code:code,context:SentenceContextWindow.append(c.remaining,to:c.context),rejectedText:String(c.original.suffix(n)),reading:tail)
    }
    public mutating func deleted(document:String,anchor:String?,time:TimeInterval) -> Replacement? {
        guard var c=commit,let anchor,c.document==document,c.anchor==anchor,time-c.time>=0,time-c.time<=120 else { invalidate();return nil }
        c.remaining.removeLast()
        if c.remaining.isEmpty { commit=nil;return Replacement(code:c.code,context:c.context,rejectedText:c.original,reading:c.reading) }
        commit=c;return nil
    }
}
