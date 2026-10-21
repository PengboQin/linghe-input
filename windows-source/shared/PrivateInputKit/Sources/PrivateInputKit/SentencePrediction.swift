import Foundation

public enum SentenceContextWindow {
    public static let limit=128
    public static func append(_ text:String,to previous:String) -> String { String((previous+text).suffix(limit)) }
    public static func validationSuffix(_ text:String) -> String { String(text.suffix(16)) }
    public static func preferenceContext(_ text:String) -> String {
        let ends=Set("。！？!?\n")
        let current=String(text.reversed().prefix{!ends.contains($0)}.reversed())
        return String(current.filter{$0.isLetter || $0.isNumber}.suffix(12))
    }
    public static func scoringContext(_ text:String) -> (text:String,weight:Double) {
        if text.isEmpty { return ("",1) }
        let ends=Set("。！？!?\n")
        let current=String(text.reversed().prefix{!ends.contains($0)}.reversed())
        let scope=current.isEmpty ? String(text.dropLast()):current
        let clean=scope.filter{$0.isLetter || $0.isNumber}
        return (String(clean.suffix(12)),current.isEmpty ? 0.3:1)
    }
}

public struct NineKeySpan:Equatable {
    public let start:Int,end:Int
    public init(start:Int,end:Int) { self.start=start;self.end=end }
}

public enum NineKeySentencePlanner {
    /// A transposition straddling two spans cannot be produced by either local
    /// edit queue. Reserve a small independent set, without changing the old
    /// per-span search or applying any edit to a selected/locked prefix.
    public static func boundaryAlternatives(code:String,spans:[NineKeySpan],limit:Int=12) -> [(input:String,cost:Double)] {
        guard NineKeySpelling.isCode(code),(13...96).contains(code.count),limit>0 else { return [] }
        let chars=Array(code),middle=chars.count/2
        let boundaries=Set(spans.filter{$0.start>=0 && $0.end<=chars.count && $0.start<$0.end}.map(\.end))
            .filter{$0>0 && $0<chars.count}.sorted { abs($0-middle)==abs($1-middle) ? $0<$1:abs($0-middle)<abs($1-middle) }
        var result:[(input:String,cost:Double)]=[],seen=Set([code])
        func add(_ value:[Character],cost:Double) {
            let input=String(value)
            if result.count<min(limit,12),seen.insert(input).inserted { result.append((input,cost)) }
        }
        // All cross-boundary swaps get a turn before repeated-key hypotheses.
        for b in boundaries where chars[b-1] != chars[b] {
            var next=chars;next.swapAt(b-1,b);add(next,cost:1.2)
        }
        for b in boundaries {
            if chars[b-1]==chars[b] { var next=chars;next.remove(at:b);add(next,cost:0.9) }
            for digit in Set([chars[b-1],chars[b]]).sorted() {
                var next=chars;next.insert(digit,at:b);add(next,cost:1.1)
            }
        }
        return result
    }
    /// Keep the old leading dictionary probes, then reserve room for the
    /// remaining public-dictionary hits. In particular ranks 2...7 must not
    /// disappear when a short code has no second span/local-query phase.
    public static func recallQueries(legacy:[(input:String,cost:Double)],dictionary:[[(input:String,cost:Double)]],limit:Int=48) -> [(input:String,cost:Double)] {
        guard limit>0 else { return [] }
        var output:[(input:String,cost:Double)]=[],seen=Set<String>()
        func add(_ value:(input:String,cost:Double)) {
            if output.count<min(limit,64),seen.insert(value.input).inserted { output.append(value) }
        }
        for row in dictionary { for value in row.prefix(2) { add(value) } }
        let reserve=min(16,max(8,limit/3))
        for value in legacy.prefix(reserve) { add(value) }
        for rank in 2..<16 { for row in dictionary where rank<row.count { add(row[rank]) } }
        for value in legacy.dropFirst(reserve) { add(value) }
        return output
    }
    /// Align Chinese word lengths with exact pinyin syllables. Abbreviations or
    /// nonaligned custom words use bounded chunks, never invented alignments.
    public static func spans(code:String,reading:String,wordLengths:[Int]) -> [NineKeySpan] {
        guard NineKeySpelling.isCode(code),code.count<=96 else { return [] }
        let parts=reading.replacingOccurrences(of:"'",with:" ").split(separator:" ").map(String.init)
        let encoded=parts.compactMap(NineKeySpelling.encode)
        if encoded.count==parts.count,encoded.joined()==code,!parts.isEmpty,
           !wordLengths.isEmpty,wordLengths.allSatisfy({$0>0}),wordLengths.reduce(0,+)==parts.count {
            var syllable=0,offset=0,ranges:[NineKeySpan]=[]
            for length in wordLengths {
                var start=offset
                for _ in 0..<length {
                    let size=encoded[syllable].count;syllable+=1
                    if offset-start+size>12,offset>start { ranges.append(.init(start:start,end:offset));start=offset }
                    offset+=size
                }
                if offset>start { ranges.append(.init(start:start,end:offset)) }
            }
            return mergeShort(ranges)
        }
        return stride(from:0,to:code.count,by:8).map { .init(start:$0,end:min($0+8,code.count)) }
    }
    private static func mergeShort(_ ranges:[NineKeySpan]) -> [NineKeySpan] {
        var output:[NineKeySpan]=[]
        for range in ranges {
            if let last=output.last,last.end-last.start<4,range.end-last.start<=12 {
                output[output.count-1] = .init(start:last.start,end:range.end)
            } else { output.append(range) }
        }
        if output.count>1,let last=output.last,last.end-last.start<4 {
            let prior=output[output.count-2]
            if last.end-prior.start<=12 { output.removeLast();output[output.count-1] = .init(start:prior.start,end:last.end) }
        }
        return output
    }
    public static func alternatives(code:String,spans:[NineKeySpan],limit:Int=64) -> [(input:String,cost:Double)] {
        guard NineKeySpelling.isCode(code),(2...96).contains(code.count),limit>0 else { return [] }
        let chars=Array(code)
        let valid=spans.filter{$0.start>=0 && $0.end<=chars.count && $0.start<$0.end && $0.end-$0.start<=12}
        let queues=valid.reversed().map { span in
            NineKeySpelling.alternatives(String(chars[span.start..<span.end]),limit:64).map {
                (String(chars[..<span.start])+$0.input+String(chars[span.end...]),$0.cost)
            }
        }
        var index=0,seen=Set([code]),output:[(String,Double)]=[]
        while output.count<min(limit,128) {
            var progressed=false
            for q in queues where index<q.count {
                if seen.insert(q[index].0).inserted { output.append(q[index]) }
                progressed=true;if output.count==min(limit,128) { break }
            }
            if !progressed { break };index+=1
        }
        return output
    }
}

/// A local dictionary-verified edit in original source coordinates. Composing
/// from right to left prevents insertions/deletions shifting the other range.
public struct NineKeyLocalHypothesis {
    public let span:NineKeySpan,input:String,cost:Double,score:Double
    public init(span:NineKeySpan,input:String,cost:Double,score:Double) { self.span=span;self.input=input;self.cost=cost;self.score=score }
}
public extension NineKeySentencePlanner {
    static func neighbors(code:String,reading:String,text:String,span:NineKeySpan,window:Int=3) -> (before:String,after:String)? {
        let parts=reading.replacingOccurrences(of:"'",with:" ").split(separator:" ").map(String.init)
        let codes=parts.compactMap(NineKeySpelling.encode),chars=Array(text)
        guard codes.count==parts.count,codes.joined()==code,parts.count==chars.count else { return nil }
        var boundaries=[0]
        for code in codes { boundaries.append(boundaries.last!+code.count) }
        guard let start=boundaries.firstIndex(of:span.start),let end=boundaries.firstIndex(of:span.end),start<end else { return nil }
        return (String(chars[..<start].suffix(max(0,min(window,32)))),String(chars[end...].prefix(max(0,min(window,32)))))
    }

    static func jointAlternatives(code:String,hypotheses:[NineKeyLocalHypothesis],limit:Int=32) -> [(input:String,cost:Double)] {
        guard NineKeySpelling.isCode(code),code.count<=96,limit>0 else { return [] }
        let chars=Array(code)
        let valid=hypotheses.filter{$0.span.start>=0 && $0.span.end<=chars.count && $0.span.start<$0.span.end && $0.score.isFinite && NineKeySpelling.editCost(String(chars[$0.span.start..<$0.span.end]),$0.input) != nil}
        // Six hypotheses per source span bound the beam before pairing it.
        var kept:[NineKeyLocalHypothesis]=[]
        for h in valid.enumerated().sorted(by:{$0.element.score==$1.element.score ? $0.offset<$1.offset:$0.element.score>$1.element.score}).map(\.element) {
            if kept.filter({$0.span==h.span}).count<6 { kept.append(h) }
        }
        // Rank lightweight descriptors; materialize only the bounded queries.
        // Disjoint, independently validated single edits already prove a
        // two-edit relationship, so no full-code DP is repeated for every pair.
        typealias Pair=(a:NineKeyLocalHypothesis,b:NineKeyLocalHypothesis,score:Double,order:Int,key:String)
        var pairs:[Pair]=[]
        for i in kept.indices { for j in kept.indices where j>i {
            let a=kept[i],b=kept[j]
            guard a.span.end<=b.span.start || b.span.end<=a.span.start else { continue }
            let key=[a.span,b.span].sorted{$0.start<$1.start}.map{"\($0.start):\($0.end)"}.joined(separator:"|")
            pairs.append((a,b,a.score+b.score,pairs.count,key))
        } }
        let ordered=pairs.sorted{$0.score==$1.score ? $0.order<$1.order:$0.score>$1.score}
        var keys:[String]=[],queues:[String:[Pair]]=[:]
        for p in ordered { if queues[p.key]==nil { keys.append(p.key) };queues[p.key,default:[]].append(p) }
        var result:[(String,Double)]=[],index=0,seen=Set([code])
        while result.count<min(limit,48) {
            var advanced=false
            for key in keys {
                let q=queues[key]!
                if index<q.count {
                    let pair=q[index];advanced=true;var next=chars
                    for h in [pair.a,pair.b].sorted(by:{$0.span.start>$1.span.start}) { next.replaceSubrange(h.span.start..<h.span.end,with:Array(h.input)) }
                    let value=String(next)
                    if seen.insert(value).inserted { result.append((value,pair.a.cost+pair.b.cost)) }
                }
                if result.count==min(limit,48) { break }
            }
            if !advanced { break };index+=1
        }
        return result
    }
}
