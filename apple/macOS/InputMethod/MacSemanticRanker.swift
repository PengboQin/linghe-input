import Foundation
import CoreML

/// Mac-only CSC scorer. One inference in flight and one replaceable request;
/// no host document access, logging or network. Failure leaves Rime usable.
final class MacSemanticRanker {
    struct Item { let id:String;let text:String }
    struct Metrics { var available=false;var batches=0;var elapsedMS=0.0;var footprintMB=0.0 }
    private let directory:URL
    private let queue=DispatchQueue(label:"live.linghe.privateinput.macbert",qos:.utility)
    private let lock=NSLock()
    private var generation=0
    private var model:MLModel?,vocab:[String:Int32]=[:],failed=false
    private var pending:(Int,[Item],String,String,([String:Double],Metrics)->Void)?
    private var running=false
    var configured:Bool { FileManager.default.fileExists(atPath:directory.appendingPathComponent("MacBERT.mlmodelc").path) }
    init(directory:URL) {self.directory=directory}
    func cancel() {lock.lock();generation &+= 1;pending=nil;lock.unlock()}
    func releaseAfterIdle() {
        lock.lock();let expected=generation;lock.unlock()
        queue.asyncAfter(deadline:.now()+60) { [weak self] in
            guard let self,self.current(expected) else{return};self.model=nil;self.vocab=[:]
        }
    }
    private func current(_ id:Int)->Bool {lock.lock();defer{lock.unlock()};return id==generation}
    func evaluate(_ items:[Item],before:String,after:String="",completion:@escaping([String:Double],Metrics)->Void) {
        lock.lock();generation &+= 1
        pending=(generation,Array(items.prefix(12)),String(before.suffix(20)),String(after.prefix(20)),completion)
        let start = !running;if start {running=true};lock.unlock()
        if start {queue.async {self.drain()}}
    }
    private func drain() {
        while true {
            lock.lock();let work=pending;pending=nil;if work==nil {running=false};lock.unlock()
            guard let (id,items,before,after,completion)=work else {return}
            let start=Date.timeIntervalSinceReferenceDate
            let result=autoreleasepool {score(items,before:before,after:after,generation:id)}
            let metrics=Metrics(available:model != nil,batches:result.1,elapsedMS:(Date.timeIntervalSinceReferenceDate-start)*1000,footprintMB:Double(pi_process_memory_footprint())/1048576)
            DispatchQueue.main.async { [weak self] in guard self?.current(id)==true else{return};completion(result.0,metrics) }
        }
    }
    private func load() throws {
        guard model==nil,!failed else{return}
        guard configured else{throw CocoaError(.fileNoSuchFile)}
        let words=try String(contentsOf:directory.appendingPathComponent("vocab.txt"),encoding:.utf8).split(separator:"\n")
        guard words.count==21128,words[101]=="[CLS]",words[102]=="[SEP]" else{throw CocoaError(.fileReadCorruptFile)}
        vocab=Dictionary(uniqueKeysWithValues:words.enumerated().map{(String($0.element),Int32($0.offset))})
        let config=MLModelConfiguration();config.computeUnits = .cpuAndNeuralEngine
        model=try MLModel(contentsOf:directory.appendingPathComponent("MacBERT.mlmodelc"),configuration:config)
    }
    private func score(_ items:[Item],before:String,after:String,generation:Int)->([String:Double],Int) {
        guard current(generation) else{return ([:],0)}
        do {try load()} catch {failed=true;model=nil;return ([:],0)}
        guard let model else{return ([:],0)}
        let preceding=before.map{vocab[String($0)] ?? 100},following=after.map{vocab[String($0)] ?? 100}
        let eligible=items.filter{(2...32).contains($0.text.count) && $0.text.allSatisfy{vocab[String($0)] != nil}}
        var scores:[String:Double]=[:],batches=0
        for start in stride(from:0,to:eligible.count,by:4) {
            guard current(generation) else{break}
            do {try autoreleasepool {
                let rows=Array(eligible.dropFirst(start).prefix(4))
                let ids=try MLMultiArray(shape:[4,48],dataType:.int32),mask=try MLMultiArray(shape:[4,48],dataType:.int32)
                var starts=[Int]()
                for r in 0..<4 {
                    let tokens=r<rows.count ? rows[r].text.map{vocab[String($0)]!}:[]
                    let budget=46-tokens.count
                    let beforeCount=min(preceding.count,budget-min(following.count,budget/2))
                    let afterCount=min(following.count,budget-beforeCount)
                    let prefix=Array(preceding.suffix(beforeCount)),suffix=Array(following.prefix(afterCount))
                    starts.append(prefix.count+1)
                    let input:[Int32]=[101]+prefix+tokens+suffix+[102]
                    for c in 0..<48 {ids[r*48+c]=NSNumber(value:c<input.count ? input[c]:0);mask[r*48+c]=NSNumber(value:c<input.count ? 1:0)}
                }
                let features=try MLDictionaryFeatureProvider(dictionary:["input_ids":ids,"attention_mask":mask])
                guard let output=try model.prediction(from:features).featureValue(for:"token_log_probs")?.multiArrayValue,output.count==192 else{return}
                for (r,item) in rows.enumerated() {
                    let values=(0..<item.text.count).map{output[[NSNumber(value:r),NSNumber(value:starts[r]+$0)]].doubleValue}
                    if values.allSatisfy(\.isFinite) {scores[item.id]=values.reduce(0,+)/Double(values.count)}
                }
                batches+=1
            }} catch {break}
        }
        return (scores,batches)
    }
}
