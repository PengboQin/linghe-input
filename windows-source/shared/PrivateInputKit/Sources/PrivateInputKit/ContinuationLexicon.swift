import Foundation

/// Read-only public word continuations; lookup does not retain the input context.
public final class ContinuationLexicon {
    public struct Suggestion { public let text:String;public let score:Double }
    private let data:Data,count:Int,strings:Int
    public init(url:URL) throws {
        let bytes=try Data(contentsOf:url,options:.mappedIfSafe)
        guard bytes.count>=16,bytes.count<=8*1024*1024,bytes.prefix(8)==Data("PINEXT01".utf8) else { throw InputDataError.invalidRecord }
        let count=Int(bytes.withUnsafeBytes{$0.loadUnaligned(fromByteOffset:8,as:UInt32.self).littleEndian})
        guard count<=300000,bytes.withUnsafeBytes({$0.loadUnaligned(fromByteOffset:12,as:UInt32.self).littleEndian})==20,16+count*20<=bytes.count else { throw InputDataError.invalidRecord }
        self.data=bytes;self.count=count;strings=16+count*20
    }
    private func key(_ text:String) -> UInt64? {
        let chars=Array(text.unicodeScalars);guard (1...3).contains(chars.count),chars.allSatisfy({(0x4e00...0x9fff).contains($0.value)}) else { return nil }
        return chars.reduce(UInt64(chars.count)<<48){($0 & 0xffff000000000000) | (($0 & 0x0000ffffffffffff)<<16) | UInt64($1.value)}
    }
    public func suggestions(context:String,limit:Int=24) -> [Suggestion] {
        guard !context.isEmpty,context.last != "\n",limit>0 else { return [] }
        let trailing=Set("，,。.!！？?；;：:、 ”\"’'")
        let trimmed=String(context.reversed().drop(while:{trailing.contains($0)}).reversed())
        let scope=String(trimmed.reversed().prefix{$0.isLetter}.reversed().suffix(3))
        guard !scope.isEmpty,key(scope) != nil else { return [] }
        var scores:[String:Double]=[:]
        for size in (1...scope.count).reversed() {
            guard let key=key(String(scope.suffix(size))) else { continue }
            data.withUnsafeBytes { bytes in
                var lo=0,hi=count
                while lo<hi { let mid=(lo+hi)/2,value=bytes.loadUnaligned(fromByteOffset:16+mid*20,as:UInt64.self).littleEndian;if value<key { lo=mid+1 } else { hi=mid } }
                while lo<count,bytes.loadUnaligned(fromByteOffset:16+lo*20,as:UInt64.self).littleEndian==key {
                    let base=16+lo*20,offset=Int(bytes.loadUnaligned(fromByteOffset:base+8,as:UInt32.self).littleEndian),length=Int(bytes.loadUnaligned(fromByteOffset:base+12,as:UInt16.self).littleEndian)
                    let frequency=bytes.loadUnaligned(fromByteOffset:base+16,as:UInt32.self).littleEndian
                    if length>0,length<=12,strings+offset+length<=data.count,let text=String(data:data.subdata(in:strings+offset..<strings+offset+length),encoding:.utf8),text.allSatisfy({$0.isLetter}) {
                        scores[text]=max(scores[text] ?? -.infinity,Double(size)*0.7+log1p(Double(frequency))*0.08)
                    };lo+=1
                }
            }
        }
        // Explicit clause links give the word model useful recall after a comma.
        // They are suggestions only; none is inserted by space or punctuation.
        if let last=context.last,"，,；;：:".contains(last) {
            let clause=String(context.suffix(64))
            let links:[String]
            if clause.contains("如果") { links=["就","可以","那么"] }
            else if clause.contains("因为") { links=["所以","我们","就"] }
            else if clause.contains("虽然") { links=["但是","不过","还是"] }
            else { links=["然后","我们","可以","不过"] }
            for (i,text) in links.enumerated() { scores[text]=max(scores[text] ?? -.infinity,3-Double(i)*0.2) }
        } else if let last=context.last,"。.!！？?".contains(last) {
            for (i,text) in ["另外","我们","我","然后"].enumerated() { scores[text]=max(scores[text] ?? -.infinity,2.2-Double(i)*0.2) }
        }
        return scores.map{Suggestion(text:$0.key,score:$0.value)}.sorted{$0.score==$1.score ? $0.text<$1.text:$0.score>$1.score}.prefix(min(limit,24)).map{$0}
    }
}
