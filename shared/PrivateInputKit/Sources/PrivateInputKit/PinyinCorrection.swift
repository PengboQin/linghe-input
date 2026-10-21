import Foundation

/// Bounded syllable-aware edit lattice. Only public syllables enter this index.
/// It proposes spellings; the native dictionary must still validate every word.
public final class PinyinCorrection {
    public struct Proposal { public let spelling:String;public let edits:Int;public let cost:Double }
    private struct Edge { let syllable:String;let cost:Double;var edits:Int=1 }
    private let syllables:Set<String>
    private let frequency:(String)->UInt32
    private var repairs:[String:[Edge]]=[:]
    public init(syllables:Set<String>,frequency:@escaping(String)->UInt32 = {_ in 0}) {
        self.syllables=syllables;self.frequency=frequency
        for syllable in syllables.sorted() {
            let chars=Array(syllable)
            guard chars.count>1 else {continue}
            if chars.count>=3 {
                for i in 0..<(chars.count-1) {for j in (i+1)..<chars.count {
                    var missing=chars;missing.remove(at:j);missing.remove(at:i)
                    if !missing.isEmpty {repairs[String(missing),default:[]].append(Edge(syllable:syllable,cost:2,edits:2))}
                }}
            }
            for i in chars.indices {
                var missing=chars;missing.remove(at:i)
                let value=String(missing)
                if !value.isEmpty {repairs[value,default:[]].append(Edge(syllable:syllable,cost:1))}
                if i+1<chars.count,chars[i] != chars[i+1] {
                    var swapped=chars;swapped.swapAt(i,i+1)
                    repairs[String(swapped),default:[]].append(Edge(syllable:syllable,cost:1.1))
                }
            }
        }
    }
    public func proposals(_ input:String,limit:Int=48) -> [Proposal] {
        let chars=Array(input.utf8)
        guard (4...96).contains(chars.count),chars.allSatisfy({(97...122).contains($0)}),limit>0 else {return []}
        struct State {let spelling:String;let edits:Int;let cost:Double;let parts:Int;let prior:Double}
        var lattice=[[State]](repeating:[],count:chars.count+1)
        lattice[0]=[State(spelling:"",edits:0,cost:0,parts:0,prior:0)]
        let maximumEdits=chars.count>=6 ? 2:1
        for position in 0..<chars.count where !lattice[position].isEmpty {
            for end in (position+1)...min(chars.count,position+7) {
                let fragment=String(bytes:chars[position..<end],encoding:.utf8)!
                var edges:[Edge]=[]
                if syllables.contains(fragment) {edges.append(Edge(syllable:fragment,cost:0,edits:0))}
                edges += repairs[fragment] ?? []
                if fragment.count>1 {
                    let bytes=Array(fragment.utf8)
                    for i in bytes.indices {
                        var short=bytes;short.remove(at:i)
                        let value=String(bytes:short,encoding:.utf8)!
                        if syllables.contains(value) {edges.append(Edge(syllable:value,cost:1.05))}
                    }
                }
                guard !edges.isEmpty else {continue}
                for state in lattice[position] {
                    for edge in edges {
                        let edits=state.edits+edge.edits
                        guard edits<=maximumEdits else {continue}
                        let spelling=state.spelling+edge.syllable
                        let next=State(spelling:spelling,edits:edits,cost:state.cost+edge.cost,parts:state.parts+1,prior:state.prior+log1p(Double(frequency(spelling)))*0.003)
                        if let old=lattice[end].firstIndex(where:{$0.spelling==next.spelling && $0.edits==edits}) {
                            if lattice[end][old].cost+Double(lattice[end][old].parts)*0.03-lattice[end][old].prior<=next.cost+Double(next.parts)*0.03-next.prior {continue}
                            lattice[end].remove(at:old)
                        }
                        lattice[end].append(next)
                    }
                }
                // Keep opportunities from each edit budget, including paths
                // whose first typo occurs late in an otherwise exact sentence.
                var kept:[State]=[]
                for edits in 0...maximumEdits {
                    kept += lattice[end].filter{$0.edits==edits}.sorted {
                        let a=$0.cost+Double($0.parts)*0.03-$0.prior,b=$1.cost+Double($1.parts)*0.03-$1.prior
                        return a==b ? $0.spelling<$1.spelling:a<b
                    }.prefix(48)
                }
                lattice[end]=kept
            }
        }
        var seen=Set<String>()
        let ranked=lattice[chars.count].filter{$0.edits>0 && $0.spelling != input}.sorted {
            let a=$0.cost+Double($0.parts)*0.03-$0.prior,b=$1.cost+Double($1.parts)*0.03-$1.prior
            return a==b ? $0.spelling<$1.spelling:a<b
        }
        // Reserve recall for one/two adjacent transpositions. Without this,
        // many cheaper omission paths can crowd a common two-syllable word
        // out of the finite lattice (linaxaing -> lianxiang).
        var swaps:[Proposal]=[]
        if chars.count<=24 {
            func valid(_ bytes:[UInt8])->Bool {
                var reachable:Set<Int>=[0]
                for start in 0..<bytes.count where reachable.contains(start) {
                    for end in (start+1)...min(bytes.count,start+6) {
                        if syllables.contains(String(bytes:bytes[start..<end],encoding:.utf8)!) {reachable.insert(end)}
                    }
                }
                return reachable.contains(bytes.count)
            }
            var swapSeen=Set<String>()
            func add(_ bytes:[UInt8],edits:Int) {
                let value=String(bytes:bytes,encoding:.utf8)!
                if value != input,swapSeen.insert(value).inserted,valid(bytes) {swaps.append(Proposal(spelling:value,edits:edits,cost:Double(edits)*1.1))}
            }
            for i in 0..<chars.count-1 where chars[i] != chars[i+1] {
                var once=chars;once.swapAt(i,i+1);add(once,edits:1)
                if maximumEdits>=2,i+1<chars.count-1 {
                    for j in i+1..<chars.count-1 where once[j] != once[j+1] {
                        var twice=once;twice.swapAt(j,j+1);add(twice,edits:2)
                    }
                }
            }
            swaps.sort {
                let a=log1p(Double(frequency($0.spelling)))-Double($0.edits)*0.2,b=log1p(Double(frequency($1.spelling)))-Double($1.edits)*0.2
                return a==b ? $0.spelling<$1.spelling:a>b
            }
        }
        // Whole-string extra-key deletions need their own recall budget.
        // Otherwise many slightly cheaper inserted-letter paths can crowd a
        // common short word out (haoo -> hao), despite a valid syllable parse.
        func validSpelling(_ value:String)->Bool {
            let bytes=Array(value.utf8);var reachable=Set([0])
            for start in 0..<bytes.count where reachable.contains(start) {
                for end in (start+1)...min(bytes.count,start+6) {
                    if syllables.contains(String(bytes:bytes[start..<end],encoding:.utf8)!) {reachable.insert(end)}
                }
            }
            return reachable.contains(bytes.count)
        }
        var deletions:[Proposal]=[],deletionSeen=Set<String>()
        for i in chars.indices {
            var bytes=chars;bytes.remove(at:i);let value=String(bytes:bytes,encoding:.utf8)!
            if deletionSeen.insert(value).inserted,validSpelling(value) {
                let repeated=(i>0 && chars[i-1]==chars[i]) || (i+1<chars.count && chars[i+1]==chars[i])
                deletions.append(.init(spelling:value,edits:1,cost:repeated ? 0.9:1.05))
            }
        }
        deletions.sort {
            let a=log1p(Double(frequency($0.spelling)))-$0.cost*1.5,b=log1p(Double(frequency($1.spelling)))-$1.cost*1.5
            return a==b ? $0.spelling<$1.spelling:a>b
        }
        // Preserve the original 32 one-edit + 16 two-edit opportunities;
        // additional capacity is reserved for swaps instead of displacing them.
        let ceiling=min(64,limit)
        var selected=Array(ranked.filter{$0.edits==1}.prefix(min(ceiling,32))).map{Proposal(spelling:$0.spelling,edits:$0.edits,cost:$0.cost)}
        for value in ranked.filter({$0.edits==2}).prefix(max(0,min(48,ceiling)-selected.count)) {
            selected.append(Proposal(spelling:value.spelling,edits:value.edits,cost:value.cost))
        }
        for value in deletions.prefix(4) {
            if let index=selected.firstIndex(where:{$0.spelling==value.spelling}) {
                if value.cost<selected[index].cost {selected[index]=value}
            } else if selected.count<ceiling {selected.append(value)}
        }
        for value in swaps where !selected.contains(where:{$0.spelling==value.spelling}) && selected.count<ceiling {selected.append(value)}
        for value in ranked where !selected.contains(where:{$0.spelling==value.spelling}) && selected.count<ceiling {selected.append(Proposal(spelling:value.spelling,edits:value.edits,cost:value.cost))}
        return selected.filter{seen.insert($0.spelling).inserted}
    }
}
