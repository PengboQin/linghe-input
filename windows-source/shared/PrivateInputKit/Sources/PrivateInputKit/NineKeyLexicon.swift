import Foundation

/// A memory-mapped public dictionary index. It contains numeric spellings and
/// aggregate public frequency only, never user words or input history.
public final class NineKeyLexicon {
    private let data:Data
    private let count:Int
    public init(url:URL) throws {
        let bytes=try Data(contentsOf:url,options:.mappedIfSafe)
        guard bytes.count>=16,bytes.prefix(8)==Data("PI9LEX01".utf8) else { throw InputDataError.invalidRecord }
        let count=Int(bytes.withUnsafeBytes{$0.loadUnaligned(fromByteOffset:8,as:UInt32.self).littleEndian})
        let stride=bytes.withUnsafeBytes{$0.loadUnaligned(fromByteOffset:12,as:UInt32.self).littleEndian}
        guard count<=300_000,stride==12,bytes.count==16+count*12 else { throw InputDataError.oversized }
        self.data=bytes;self.count=count
    }
    private func key(_ code:String) -> UInt64? {
        guard NineKeySpelling.isCode(code),code.count<=18 else { return nil }
        var result:UInt64=0
        for byte in code.utf8 { result=(result<<3)|UInt64(byte-50) }
        return (UInt64(code.count)<<54)|result
    }
    public func frequency(_ code:String) -> UInt32 {
        guard let key=key(code) else { return 0 }
        return data.withUnsafeBytes { bytes in
            var low=0,high=count
            while low<high {
                let mid=(low+high)/2,value=bytes.loadUnaligned(fromByteOffset:16+mid*12,as:UInt64.self).littleEndian
                if value<key { low=mid+1 } else { high=mid }
            }
            guard low<count,bytes.loadUnaligned(fromByteOffset:16+low*12,as:UInt64.self).littleEndian==key else { return 0 }
            return bytes.loadUnaligned(fromByteOffset:24+low*12,as:UInt32.self).littleEndian
        }
    }
    public func alternatives(_ input:String,limit:Int=8) -> [(input:String,cost:Double,frequency:UInt32)] {
        guard NineKeySpelling.isCode(input),(2...12).contains(input.count),limit>0 else { return [] }
        let source=Array(input);var seen=Set([input]),result:[(input:String,cost:Double,frequency:UInt32)]=[]
        func add(_ chars:[Character]) {
            let value=String(chars)
            guard seen.insert(value).inserted,let cost=NineKeySpelling.editCost(input,value) else { return }
            let frequency=frequency(value);if frequency>0 { result.append((value,cost,frequency)) }
        }
        for i in source.indices {
            var shorter=source;shorter.remove(at:i);add(shorter)
            for digit in "23456789" where digit != source[i] { var changed=source;changed[i]=digit;add(changed) }
            if i+1<source.count { var swapped=source;swapped.swapAt(i,i+1);add(swapped) }
        }
        for i in 0...source.count { for digit in "23456789" { var longer=source;longer.insert(digit,at:i);add(longer) } }
        let ranked=result.sorted {
            let a=log1p(Double($0.frequency))-$0.cost*1.5,b=log1p(Double($1.frequency))-$1.cost*1.5
            return a==b ? $0.input<$1.input:a>b
        }
        // Preserve the old eight strongest hypotheses, then reserve extra
        // recall for distinct missed/extra/swapped/neighbor errors.
        var selected=Array(ranked.prefix(min(limit,8)))
        if limit>8 {
            func category(_ value:String) -> Int {
                if value.count>input.count { return 0 };if value.count<input.count { return 1 }
                let next=Array(value),different=source.indices.filter{source[$0] != next[$0]}
                return different.count==2 ? 2:3
            }
            for kind in 0..<4 where selected.count<min(limit,16) {
                if let value=ranked.first(where:{ candidate in category(candidate.input)==kind && !selected.contains(where:{$0.input==candidate.input}) }) { selected.append(value) }
            }
            for value in ranked where selected.count<min(limit,16) && !selected.contains(where:{$0.input==value.input}) { selected.append(value) }
        }
        return selected
    }
}
