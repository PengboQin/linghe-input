import Foundation
import CoreML

/// Serialized, cancellable inference. The queue retains at most the running
/// request and the newest pending request; text is never written or logged.
final class SemanticRanker {
    struct Request { let id:String; let before:String; let text:String; let after:String;var includeTokenScores=false }
    struct Metrics { var batches=0; var elapsedMS=0.0; var available=false;var footprintMB=0.0;var peakMB=0.0;var headroomMB=0.0;var memoryLimited=false }
    private struct Work { let generation:Int; let requests:[Request]; let completion:([String:Double],Metrics)->Void }
    private let queue=DispatchQueue(label:"live.linghe.privateinput.semantic",qos:.userInitiated)
    private let lock=NSLock()
    private let directory:URL
    private var generation=0,pending:Work?,running=false,suspended=false
    private var model:MLModel?,vocabulary:[String:Int32]=[:],failed=false,memoryLimited=false
    private(set) var configured:Bool
    init(directory:URL) {
        self.directory=directory
        configured=FileManager.default.fileExists(atPath:directory.appendingPathComponent("SemanticDiscriminator.mlmodelc").path)
    }
    func cancel() { lock.lock();generation &+= 1;pending=nil;lock.unlock() }
    func suspend() {
        lock.lock();suspended=true;generation &+= 1;pending=nil;lock.unlock()
        queue.async { self.model=nil;self.vocabulary=[:] }
    }
    func evaluate(_ requests:[Request],limit:Int=32,completion:@escaping([String:Double],Metrics)->Void) {
        lock.lock();generation &+= 1
        if suspended || !configured { lock.unlock();completion([:],Metrics());return }
        pending=Work(generation:generation,requests:Array(requests.prefix(max(0,min(64,limit)))),completion:completion)
        let start = !running;if start { running=true };lock.unlock()
        if start { queue.async { self.drain() } }
    }
    private func current(_ id:Int) -> Bool { lock.lock();defer{lock.unlock()};return !suspended && generation==id }
    private func drain() {
        while true {
            lock.lock();let work=pending;pending=nil
            if work==nil { running=false };lock.unlock()
            guard let work else { return }
            let start=Date.timeIntervalSinceReferenceDate
            let result=autoreleasepool { infer(work) }
            let metrics=Metrics(batches:result.1,elapsedMS:(Date.timeIntervalSinceReferenceDate-start)*1000,available:model != nil,footprintMB:Double(pi_process_memory_footprint())/1048576,peakMB:Double(pi_process_peak_memory_footprint())/1048576,headroomMB:Double(pi_available_memory())/1048576,memoryLimited:memoryLimited)
            DispatchQueue.main.async { [weak self] in
                guard self?.current(work.generation)==true else { return }
                work.completion(result.0,metrics)
            }
        }
    }
    private func load() throws {
        guard model==nil,!failed else { return }
        let headroom=pi_available_memory()
        if headroom>0,headroom<32*1048576 { memoryLimited=true;return }
        memoryLimited=false
        let words=try String(contentsOf:directory.appendingPathComponent("vocab.txt"),encoding:.utf8).split(separator:"\n",omittingEmptySubsequences:false)
        guard words.count<=30000,words.count>102,words[0]=="[PAD]",words[100]=="[UNK]",words[101]=="[CLS]",words[102]=="[SEP]" else { throw CocoaError(.fileReadCorruptFile) }
        vocabulary=Dictionary(words.enumerated().filter{!$0.element.isEmpty}.map{(String($0.element),Int32($0.offset))},uniquingKeysWith:{$1})
        let config=MLModelConfiguration();config.computeUnits = .cpuAndNeuralEngine
        model=try MLModel(contentsOf:directory.appendingPathComponent("SemanticDiscriminator.mlmodelc"),configuration:config)
    }
    private func tokens(_ text:String) -> [Int32] {
        var output:[Int32]=[],word=""
        func flush() {
            guard !word.isEmpty else { return };defer { word="" }
            let chars=Array(word);var index=0,pieces:[Int32]=[]
            guard chars.count<=100 else { output.append(100);return }
            while index<chars.count {
                var end=chars.count,found:Int32?
                while end>index {
                    let piece=(index==0 ? "":"##")+String(chars[index..<end])
                    if let id=vocabulary[piece] { found=id;break };end-=1
                }
                guard let found else { output.append(100);return }
                pieces.append(found);index=end
            }
            output+=pieces
        }
        for scalar in text.lowercased().unicodeScalars {
            let c=Character(String(scalar)),value=scalar.value
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { flush() }
            else if (0x3400...0x9fff).contains(value) || (0x20000...0x2fa1f).contains(value) || c.isPunctuation || c.isSymbol {
                flush();output.append(vocabulary[String(c)] ?? 100)
            } else if !CharacterSet.controlCharacters.contains(scalar) { word.append(c) }
        }
        flush();return output
    }
    private struct Encoded { let id:String;let ids:[Int32];let start:Int;let count:Int;let includeTokenScores:Bool }
    private func encode(_ request:Request) -> Encoded? {
        let text=tokens(request.text)
        guard (1...32).contains(text.count),!text.contains(100) else { return nil }
        let preceding=tokens(request.before),following=tokens(request.after),budget=46-text.count
        let beforeCount=min(preceding.count,budget-min(following.count,budget/2))
        let afterCount=min(following.count,budget-beforeCount)
        let after=Array(following.prefix(afterCount)),before=Array(preceding.suffix(beforeCount))
        return Encoded(id:request.id,ids:[101]+before+text+after+[102],start:before.count+1,count:text.count,includeTokenScores:request.includeTokenScores)
    }
    private func infer(_ work:Work) -> ([String:Double],Int) {
        guard current(work.generation) else { return ([:],0) }
        do { try load() } catch { failed=true;model=nil;vocabulary=[:];return ([:],0) }
        guard model != nil,current(work.generation) else { return ([:],0) }
        let encoded=work.requests.compactMap(encode),start=Date.timeIntervalSinceReferenceDate
        var results:[String:Double]=[:],batches=0
        for offset in stride(from:0,to:encoded.count,by:4) {
            guard current(work.generation),Date.timeIntervalSinceReferenceDate-start<0.6 else { break }
            do {
                let partial=try autoreleasepool { () throws -> [String:Double]? in
                var outputScores:[String:Double]=[:]
                let batch=Array(encoded.dropFirst(offset).prefix(4))
                let ids=try MLMultiArray(shape:[4,48],dataType:.int32),mask=try MLMultiArray(shape:[4,48],dataType:.int32)
                let ip=ids.dataPointer.bindMemory(to:Int32.self,capacity:192),mp=mask.dataPointer.bindMemory(to:Int32.self,capacity:192)
                for row in 0..<4 {
                    let values=row<batch.count ? batch[row].ids:[101,102]
                    for col in 0..<48 { ip[row*48+col]=col<values.count ? values[col]:0;mp[row*48+col]=col<values.count ? 1:0 }
                }
                let input=try MLDictionaryFeatureProvider(dictionary:["input_ids":ids,"attention_mask":mask])
                guard let output=try model?.prediction(from:input).featureValue(for:"replacement_logits")?.multiArrayValue,output.count==192 else { return nil }
                for (row,item) in batch.enumerated() {
                    var score=0.0,finite=true
                    for col in item.start..<item.start+item.count {
                        let value=output[[NSNumber(value:row),NSNumber(value:col)]].doubleValue
                        if !value.isFinite { finite=false;break }
                        let tokenScore = -log1p(exp(min(30,value)));score += tokenScore
                        if item.includeTokenScores { outputScores[item.id+"#\(col-item.start)"]=tokenScore }
                    }
                    if finite { outputScores[item.id]=score/Double(item.count) }
                }
                return outputScores
                }
                if let partial { batches+=1;results.merge(partial,uniquingKeysWith:{_,new in new}) }
            } catch { break } // Base dictionary candidates remain available.
        }
        return (results,batches)
    }
}
