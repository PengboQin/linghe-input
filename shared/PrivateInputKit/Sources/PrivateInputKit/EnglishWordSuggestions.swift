import Foundation

/// Offline word-level candidates. The caller controls when a host word is
/// eligible; suggestions never alter or persist the original input.
public enum EnglishWordSuggestions {
    public static func suggestions(prefix:String,completions:[String],guesses:[String]=[],limit:Int=12)->[String] {
        guard (2...48).contains(prefix.count),prefix.utf8.allSatisfy({(65...90).contains($0) || (97...122).contains($0)}),limit>0 else{return []}
        let lower=prefix.lowercased()
        func valid(_ word:String)->Bool {(2...48).contains(word.count) && word.utf8.allSatisfy({(65...90).contains($0) || (97...122).contains($0)})}
        var seen=Set<String>()
        let all=completions+MixedEnglishLexicon.words
        let completions=all.filter{valid($0) && $0.lowercased().hasPrefix(lower) && $0.lowercased() != lower && seen.insert($0.lowercased()).inserted}
        var corrections:[(word:String,cost:Double,order:Int)]=[]
        if prefix.count>=3 {
            for (index,word) in (guesses+MixedEnglishLexicon.words).enumerated() where valid(word) && word.lowercased() != lower && !seen.contains(word.lowercased()) {
                guard let cost=correctionCost(lower,word.lowercased()) else{continue}
                seen.insert(word.lowercased());corrections.append((word,cost,index))
            }
        }
        corrections.sort{$0.cost == $1.cost ? $0.order<$1.order:$0.cost<$1.cost}
        // Reserve recall for spelling repair even when a different dictionary
        // word happens to complete the mistyped prefix.
        let head=min(6,max(1,limit-2)),best=corrections.first?.cost ?? 0
        let values=Array(completions.prefix(head))+corrections.filter{$0.cost<=best+0.6}.map(\.word)+Array(completions.dropFirst(head))
        return values.prefix(min(limit,24)).map {word in
            if prefix==prefix.uppercased() {return word.uppercased()}
            if prefix.first?.isUppercase==true {return word.prefix(1).uppercased()+word.dropFirst().lowercased()}
            return word.lowercased()
        }
    }
    public static func correctionCost(_ input:String,_ word:String)->Double? {
        let a=Array(input.utf8),b=Array(word.utf8)
        guard (3...48).contains(a.count),(2...48).contains(b.count),abs(a.count-b.count)<=2,
              (a+b).allSatisfy({(97...122).contains($0)}) else{return nil}
        let budget=a.count>=5 ? 2:1
        var cost=Array(repeating:Array(repeating:Array(repeating:Double.infinity,count:budget+1),count:b.count+1),count:a.count+1)
        cost[0][0][0]=0
        func add(_ i:Int,_ j:Int,_ fromI:Int,_ fromJ:Int,_ extra:Double,_ edit:Int) {
            for used in 0...budget where used+edit<=budget {
                cost[i][j][used+edit]=min(cost[i][j][used+edit],cost[fromI][fromJ][used]+extra)
            }
        }
        for i in 0...a.count {for j in 0...b.count where i+j>0 {
            if i>0 {add(i,j,i-1,j,i>1 && a[i-1]==a[i-2] ? 0.55:1,1)}
            if j>0 {add(i,j,i,j-1,j>1 && b[j-1]==b[j-2] ? 0.55:1,1)}
            if i>0,j>0 {let equal=a[i-1]==b[j-1];add(i,j,i-1,j-1,equal ? 0:(near(a[i-1],b[j-1]) ? 0.55:1.25),equal ? 0:1)}
            if i>1,j>1,a[i-1]==b[j-2],a[i-2]==b[j-1] {add(i,j,i-2,j-2,0.65,1)}
        }}
        let value=cost[a.count][b.count].min() ?? .infinity,ceiling=a.count>=5 ? 2.1:(a.count==4 ? 1.3:0.8)
        return value>0 && value<=ceiling ? value:nil
    }
    private static let positions:[UInt8:(Double,Double)] = {
        var result:[UInt8:(Double,Double)]=[:]
        for (row,line) in ["qwertyuiop","asdfghjkl","zxcvbnm"].enumerated() {
            for (column,key) in line.utf8.enumerated() {result[key]=(Double(column)+[0,0.25,0.75][row],Double(row))}
        };return result
    }()
    private static func near(_ a:UInt8,_ b:UInt8)->Bool {
        guard let x=positions[a],let y=positions[b] else{return false}
        return hypot(x.0-y.0,x.1-y.1)<=1.3
    }
}
