import Foundation
import Combine
import NaturalLanguage
import PrivateInputKit

struct InputCandidate {
    let text: String; let comment: String; let index: Int
    var replacementInput: String? = nil
    var sourceInput: String? = nil
    var assemblyID:Int? = nil
    var generation:Int? = nil
    var continuationContext:String? = nil
    var personalID:UUID? = nil
    var latinInput:String? = nil
    var supplementaryTrigger:String? = nil
    var partialCode:String? = nil
    var pinyinRepair:String? = nil
    var pinyinRemainder:String? = nil
    var initialsInput:String? = nil
    var initialsSuffix:Int = 0
    var prefixCompletion=false
    var learnedPreference=false
}

enum EngineFailure: Error { case resourceMissing, initializeFailed, sessionFailed }
/// Only immutable public-dictionary spelling work runs here. Rime sessions and
/// live engine state stay on the platform input thread; no shared native lock is
/// moved into a background job. Retain at most the running and latest request.
private final class NineKeyPreparationWorker {
    struct Result {
        let seeds:[(input:String,cost:Double,frequency:UInt32)]
        let legacy:[(input:String,cost:Double)]
    }
    private struct Work {
        let generation:Int,code:String,limit:Int,local:Bool,lexicon:NineKeyLexicon?
        let completion:(Result)->Void
    }
    private let queue=DispatchQueue(label:"live.linghe.privateinput.spelling-preparation",qos:.userInitiated)
    private let lock=NSLock()
    private var generation=0,pending:Work?,running=false
    func cancel() {lock.lock();generation &+= 1;pending=nil;lock.unlock()}
    func evaluate(code:String,lexicon:NineKeyLexicon?,limit:Int,local:Bool,completion:@escaping(Result)->Void) {
        lock.lock();generation &+= 1
        pending=Work(generation:generation,code:code,limit:limit,local:local,lexicon:lexicon,completion:completion)
        let start = !running;if start {running=true};lock.unlock()
        if start {queue.async {self.drain()}}
    }
    private func current(_ value:Int)->Bool {lock.lock();defer{lock.unlock()};return generation==value}
    private func drain() {
        while true {
            lock.lock();let work=pending;pending=nil;if work==nil {running=false};lock.unlock()
            guard let work else{return}
            guard current(work.generation) else{continue}
            let result=autoreleasepool {Result(seeds:work.lexicon?.alternatives(work.code,limit:work.limit) ?? [],legacy:work.local ? NineKeySpelling.alternatives(work.code,limit:64):[])}
            DispatchQueue.main.async { [weak self] in
                guard self?.current(work.generation)==true else{return}
                work.completion(result)
            }
        }
    }
}
// Synchronous adapter used by serialized platform input callbacks; the C layer
// guards the process-global Rime API. Only immutable public spelling preparation
// and neural inference run off-thread; native session state remains serialized.
final class NativeEngine: ObservableObject {
    @Published private(set) var preedit = ""
    @Published private(set) var candidates: [String] = []
    @Published private var runtimeReady = false
    private(set) var ready:Bool {
        get {runtimeReady && personalEpoch==Self.initializedEpoch}
        set {runtimeReady=newValue}
    }
    @Published private(set) var page = 0
    @Published private(set) var hasNextPage = false
    private var session: PI_Session = 0
    private(set) var revision = 0
    var compositionCursorUTF16:Int {
        guard ready else{return 0}
        let before=String(decoding:preedit.utf8.prefix(Int(pi_preedit_cursor_utf8(session))),as:UTF8.self)
        if latinDisplay() != nil {
            let selected=String(cString:pi_selected_prefix(session)).trimmingCharacters(in:.whitespaces)
            if before.hasPrefix(selected) {return selected.utf16.count+before.dropFirst(selected.count).replacingOccurrences(of:" ",with:"").utf16.count}
        }
        return before.utf16.count
    }
    private static var initialized = false
    private static var initializedEpoch="initial"
    private static var initializedPath: String?
    private static var initializedSharedPath: String?
    private var coordinator: LocalLearningCoordinator?
    private var privateInput = false
    private var englishInput = false
    private var nineKeyInput = false
    private var personalStore:PersonalLexiconStore?
    private var personalLexicon=PersonalLexicon()
    private var supplementaryLexicon=SupplementaryLexicon(pairs:[])
    private(set) var mixedEnglishEnabled=false
    private let mixedEnglishProvider:((String)->[String])?
    private let candidateIsDisplayable:(String)->Bool
    private var visibilityPage=CandidateVisibilityPage<InputCandidate>()
    private var visibilityRevision = -1
    private var visibilityPredictionComplete=false
    private var mixedRevision = -1
    private var mixedRows:[InputCandidate]=[]
    private var mixedLeads=false
    private var mixedChinesePriority=false
    private var mixedLatinDisplayAllowed=false
    private var lastLatinDisplayInput=""
    private var baseURL: URL?
    private var cloudCommittedVersion: UInt64 = 0
    private var managedEntries: [LearningEntry] = []
    private var appliedPins: [LearningEntry] = []
    private(set) var managementPending = false
    private let learningRefreshOwner = UUID()
    private var learningCheckpointGate = LearningCheckpointGate()
    private let learningRefreshQueue = DispatchQueue(label:"live.linghe.privateinput.learning-preflight",qos:.utility)
    private(set) var learningRefreshWasSkipped = false
    private(set) var learningCheckpointRuns = 0
    private func markNativeLearningChanged() { learningCheckpointGate.changed() }

    private var ownContext = ""
    var precedingOwnText: String { ownContext }
    private var hostContext:SurroundingText?
    var modelContext:SurroundingText {
        let prefix=ready ? String(cString:pi_selected_prefix(session)):""
        return SurroundingText(before:(hostContext?.before ?? ownContext)+prefix,after:hostContext?.after ?? "")
    }
    var hasHostContext:Bool {hostContext.map{!$0.before.isEmpty || !$0.after.isEmpty} ?? false}
    func setHostContext(_ context:SurroundingText?) {
        guard preedit.isEmpty,hostContext != context else{return}
        hostContext=context;revision &+= 1;invalidatePrediction()
    }
    var continuationSourceContext:String {hostContext?.before ?? ownContext}
    func canSemanticRank(_ row:InputCandidate)->Bool {
        guard row.personalID==nil,row.latinInput==nil,row.supplementaryTrigger==nil,!row.learnedPreference,
              !appliedPins.contains(where:{$0.text==row.text}),row.partialCode==nil else{return false}
        return row.pinyinRepair != nil ? row.pinyinRemainder==nil:canContextRank(row)
    }
    /// Mobile's smaller local model follows the same protected-slot contract
    /// as MacBERT. It scores existing candidates, never invents host edits.
    func rankPinyinCandidates(_ rows:[InputCandidate],completion:@escaping([InputCandidate])->Void) {
        guard !nineKeyInput,!englishInput,!predictionSuspended,let ranker=semanticRanker else{return}
        let eligible=Array(rows.filter{$0.text.count>=2 && canSemanticRank($0) && ($0.pinyinRepair != nil || hasHostContext)}.prefix(12))
        guard eligible.count>1 else{return}
        let expected=revision,context=modelContext,rankingInput=alphabeticRankingInput
        let requests=eligible.enumerated().map{SemanticRanker.Request(id:String($0.offset),before:context.before,text:$0.element.text,after:context.after)}
        ranker.evaluate(requests,limit:12) { [weak self] scores,metrics in
            guard let self,self.revision==expected else{return}
            self.recordSemanticMetrics(metrics)
            let ranked=eligible.enumerated().sorted { a,b in
                let av = -Double(a.offset)*0.20 + max(-2,min(0,scores[String(a.offset)] ?? -2))*0.65
                let bv = -Double(b.offset)*0.20 + max(-2,min(0,scores[String(b.offset)] ?? -2))*0.65
                return av==bv ? a.offset<b.offset:av>bv
            }.map(\.element)
            completion(Self.mergingSemanticRanking(base:rows,ranked:ranked,input:rankingInput))
        }
    }
    static func mergingSemanticRanking(base:[InputCandidate],ranked:[InputCandidate],input:String?=nil)->[InputCandidate] {
        var result=base
        func priority(_ row:InputCandidate)->Int {
            guard let input else{return row.pinyinRepair == nil ? 0:1}
            return PinyinInputMatch.candidatePriority(input,reading:row.comment,corrected:row.pinyinRepair != nil)
        }
        for tier in 0...3 {
            let group=ranked.filter{priority($0)==tier}
            let positions=base.indices.filter{index in group.contains{$0.index==base[index].index && $0.text==base[index].text}}
            for (position,row) in zip(positions,group) {result[position]=row}
        }
        return result
    }
    func canContextRank(_ row:InputCandidate)->Bool {
        guard row.personalID==nil,row.latinInput==nil,row.supplementaryTrigger==nil,!row.learnedPreference,
              !appliedPins.contains(where:{$0.text==row.text}),!row.comment.isEmpty else{return false}
        let learned=privateInput ? 0:choiceMemory.boost(code:NineKeySpelling.encode(rawInput) ?? "",reading:row.comment,text:row.text,context:ownContext)
        return learned==0 && PinyinInputMatch.covers(rawInput,reading:row.comment)
    }
    private var commonWords:CommonWordPrior?
    private var commonRevision = -1
    private var commonPredictionComplete = false
    private var commonRows:[InputCandidate] = []
    private var commonCandidateTiers:[Int:Int]=[:]
    private var choiceMemory = NineKeyChoiceMemory()
    private var choiceMemoryWritable = true
    private var replacement: (code:String, context:String, time:TimeInterval, rejectedText:String?,reading:String?)?
    private var preferenceNativeRevision = -1, preferencePredictionRevision = -1
    private var preferenceNativeRows:[InputCandidate]=[],preferencePredictionRows:[InputCandidate]=[]
    private var semanticRanker:SemanticRanker?
    private var completeSyllables=Set<String>()
    private var nineLexicon:NineKeyLexicon?
    private var continuationLexicon:ContinuationLexicon?
    private var continuationRevision = -1,continuationRanked = false
    private var continuationRows:[ContinuationLexicon.Suggestion]=[]
    private var continuationCandidates:[InputCandidate]=[]
    private let useSemantic:Bool
    private let useLexicon:Bool
    private let expandedShortRecall:Bool
    private let expandedSentenceRecall:Bool
    private let cachePredictionQueries:Bool
    private let retainPredictionProbe:Bool
    private var semanticWaiting=false,semanticLocalStarted=false,semanticFinalStarted=false
    private var sentenceExplored=false,sentenceReranked=false
    private struct AssemblyPlan { let input:String,text:String,readings:[String] }
    private struct ExplorationUnit { let text:String;let readings:[String];let score:Double }
    private struct ExplorationAlternative { let id:String;let draft:Int;let position:Int;let text:String;let readings:[String] }
    private struct ExplorationProbe { let draft:Int;let position:Int;let code:String }
    private struct SentenceExploration {
        var drafts:[AssemblyPlan], units:[[ExplorationUnit]], probes:[ExplorationProbe]
        var cursor=0
        var alternatives:[ExplorationAlternative]=[]
        var requests:[SemanticRanker.Request]=[]
    }
    private var sentenceExploration:SentenceExploration?
    private var assemblyPlans:[Int:AssemblyPlan]=[:]
    var assembledCandidateCount:Int { assemblyPlans.count }
    var predictionScope:(numericStart:Int,unselectedStart:Int) { (predictionOffset,predictionActiveOffset) }
    private(set) var semanticScores:[String:Double]=[:]
    private struct LocalSemanticRow { let request:SemanticRanker.Request;let key:String;let base:Double;let priority:Int }
    private var localSemanticRows:[LocalSemanticRow]=[]
    private var localSemanticContexts:[String:(before:String,after:String)]=[:]
    private var lexicalRanks:[String:Int]=[:]
    private(set) var semanticBatches=0,semanticElapsedMS=0.0
    private(set) var predictionCacheHits=0
    private var predictionProbeRequests=0
    private var predictionProbeCache:[String:[InputCandidate]]=[:]
    private(set) var semanticLastMetrics=SemanticRanker.Metrics()
    private(set) var semanticMetricsRevision = -1
    var hasSemanticResources:Bool { semanticRanker?.configured==true }
    private var predictionRevision = -1
    private var predictionInput = "", predictionContext = ""
    private var predictionModelBefore="",predictionModelAfter=""
    private var predictionOffset=0,predictionActiveOffset=0
    private var predictionSelectedPrefix="",predictionLearningCode=""
    private var predictionLocalQueue:[(span:NineKeySpan,input:String,cost:Double,primary:Bool)]=[]
    private var predictionLocalContexts:[String:(before:String,after:String)]=[:]
    private var predictionLocalScoreCache:[String:Double]=[:]
    private var predictionLocalBest:[NineKeyLocalHypothesis]=[]
    private var predictionLocalPrimary:[NineKeyLocalHypothesis]=[]
    private var predictionJointQueued=false
    private var predictionTail="",predictionPrefix=""
    private var predictionQueue: [(input:String,cost:Double)] = []
    private var predictionOriginal: [InputCandidate] = []
    private var predictionCorrections: [(candidate:InputCandidate,score:Double)] = []
    private var predictionExpansionQueue:[(input:String,cost:Double)]=[]
    private var predictionExpansionRows:[(candidate:InputCandidate,score:Double)]=[]
    private var predictionExpansionRanked=false
    private var predictionProtectedExtras:[(candidate:InputCandidate,score:Double)]?
    private var predictionHead: [InputCandidate] = []
    private var predictionComplete = false
    private var predictionProbe:PI_Session=0
    private enum PredictionYield: Error { case nextRunLoop }
    private var predictionSliceQueriesRemaining = Int.max
    private struct NinePredictionPreparation {
        let tail:String,prefix:String,queryPrefix:String,reading:String
        let first:InputCandidate?
        let spans:[NineKeySpan]
        var nextSpan=0
        var dictionaryWhole:[[(input:String,cost:Double)]]
        var local:[[(NineKeySpan,String,Double)]]=[]
    }
    private let ninePreparationWorker=NineKeyPreparationWorker()
    private var nineSpanWorkPending=false
    private var ninePreparedSpan:NineKeyPreparationWorker.Result?
    private var ninePredictionPreparation:NinePredictionPreparation?
    private var predictionPrefixQueried = false
    private(set) var predictionPreparationMS = 0.0
    private(set) var predictionMaxProbeMS = 0.0
    private var languageScoreCache:[String:Double]=[:]
    private var predictionStart:TimeInterval=0
    private(set) var predictionQueryCount=0
    private(set) var predictionMaxSliceMS:Double=0
    private(set) var predictionElapsedMS:Double=0
    private(set) var predictionFootprintMB:Double=0
    private(set) var languageModelReady = false
    private var predictionSuspended = false
    private var recoveryRevision = -1
    private var recoveryRows:[InputCandidate] = []
    private var initialsRevision = -1
    private var initialsRows:[InputCandidate] = []

    private var pinyinCorrector:PinyinCorrection?
    private var pinyinRevision = -1
    private var pinyinRows:[InputCandidate] = []
    func suspendPredictionForMemoryPressure() {
        releasePredictionProbe()
        predictionSuspended=true;semanticRanker?.suspend();languageModelReady=false;pi_language_release()
        recordSemanticMetrics(.init(available:false,footprintMB:Double(pi_process_memory_footprint())/1048576,peakMB:Double(pi_process_peak_memory_footprint())/1048576,headroomMB:Double(pi_available_memory())/1048576,memoryLimited:true));reload()
    }
    init(sharedResources: URL? = nil, storageBase: URL? = nil, useSemantic:Bool=true,useLexicon:Bool=true,expandedShortRecall:Bool=true,expandedSentenceRecall:Bool=true,cachePredictionQueries:Bool=true,retainPredictionProbe:Bool=false,mixedEnglishProvider:((String)->[String])?=nil,candidateIsDisplayable:@escaping(String)->Bool={CandidateGlyphSupport.supports($0)}) {
        self.mixedEnglishProvider=mixedEnglishProvider
        // Supplementary, personal and continuation rows do not all originate
        // from Rime's filtered batch. Enforce the same automatic-suggestion
        // policy at the final Apple boundary, including injected glyph probes.
        // Literal text, clipboard insertion and archive storage never use it.
        self.candidateIsDisplayable={text in
            AppleCandidateAdmission.allows(text,displayable:candidateIsDisplayable)
        }
        self.useSemantic=useSemantic;self.useLexicon=useLexicon;self.expandedShortRecall=expandedShortRecall;self.expandedSentenceRecall=expandedSentenceRecall;self.cachePredictionQueries=cachePredictionQueries;self.retainPredictionProbe=retainPredictionProbe
        originalSharedResources=sharedResources;originalStorageBase=storageBase
        do { try start(sharedResources: sharedResources, storageBase: storageBase) } catch { ready = false }
        resetObserver=PersonalDataReset.observe {[weak self] in
            guard let self else {return};let wasReady=self.runtimeReady
            _ = self.refreshResetBarrier();if !wasReady {self.finish()}
        }
    }
    static func clearOwnedDataAfterConfirmedReset() throws {
        pi_finalize();initialized=false;initializedPath=nil;initializedSharedPath=nil
        initializedEpoch=PersonalDataReset.generation
        let base=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("PrivateInput",isDirectory:true)
        try PersonalDataReset.applyLocal(base:base)
    }
    private var resetObserver:UUID?
    private var personalEpoch="initial"
    private var originalSharedResources:URL?
    private var originalStorageBase:URL?
    private var currentPersonalEpoch:String {
        if let base=originalStorageBase,let value=try? String(contentsOf:base.appendingPathComponent(PersonalDataReset.marker),encoding:.utf8),UUID(uuidString:value) != nil {return value}
        return originalStorageBase == nil ? PersonalDataReset.generation:"initial"
    }
    private func refreshResetBarrier() -> Bool {
        if originalStorageBase == nil {do {try PersonalDataReset.checkLocalDeadline()} catch {ready=false;return false}}
        let nextEpoch=currentPersonalEpoch
        guard personalEpoch != nextEpoch else {return ready}
        markNativeLearningChanged()
        // Finalize the process-global runtime once. Other controllers still hold
        // old IDs which may already have been reused by this new runtime.
        if Self.initializedEpoch != nextEpoch {
            pi_finalize();Self.initialized=false;Self.initializedPath=nil;Self.initializedSharedPath=nil;Self.initializedEpoch=nextEpoch
        }
        CandidateGlyphSupport.clearCache()
        predictionProbe=0;session=0
        choiceMemory=NineKeyChoiceMemory();choiceMemoryWritable=true;coordinator=nil;personalStore=nil
        resetPredictionContext();ownContext=""
        do {
            try start(sharedResources:originalSharedResources,storageBase:originalStorageBase)
            _ = pi_set_nine_key(session,nineKeyInput ? 1:0);_ = pi_set_private(session,privateInput ? 1:0);_ = pi_set_ascii_mode(session,englishInput ? 1:0);reload()
            return ready
        }
        catch {ready=false;return false}
    }
    private func start(sharedResources: URL?, storageBase: URL?) throws {
        KeyboardRuntimeDiagnostics.record(.nativeStart)
        guard let shared = sharedResources ?? Bundle.main.url(forResource: "rime", withExtension: nil) else { throw EngineFailure.resourceMissing }
        let fileManager = FileManager.default
        let base = storageBase ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PrivateInput", isDirectory: true)
        if originalStorageBase == nil {try PersonalDataReset.checkLocalDeadline()}
        let nextEpoch=currentPersonalEpoch
        if PersonalDataReset.needsApply(base:base,epoch:nextEpoch) {
            pi_finalize();Self.initialized=false;Self.initializedPath=nil;Self.initializedSharedPath=nil;Self.initializedEpoch=nextEpoch
        }
        try PersonalDataReset.applyLocal(base:base,epoch:nextEpoch,shared:originalStorageBase ?? PersonalDataReset.directory)
        personalEpoch=nextEpoch
        let user = base.appendingPathComponent("Rime", isDirectory: true)
        try fileManager.createDirectory(at: user, withIntermediateDirectories: true)
        baseURL = base
        KeyboardRuntimeDiagnostics.record(.nativeResourcesReady)
        #if os(iOS)
        let personalDirectory=storageBase ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:LocalLearningCoordinator.groupID)
        #else
        let personalDirectory:URL?=base
        #endif
        personalStore=personalDirectory.map(PersonalLexiconStore.init)
        refreshPersonalLexicon()
        let semanticDirectory=shared.deletingLastPathComponent().appendingPathComponent("semantic",isDirectory:true)
        if useLexicon { nineLexicon=try? NineKeyLexicon(url:semanticDirectory.appendingPathComponent("nine-lexicon.bin")) }
        if useSemantic { semanticRanker=SemanticRanker(directory:semanticDirectory) }
        if let data=try? Data(contentsOf:semanticDirectory.appendingPathComponent("pinyin-syllables.txt")),data.count<=8192,let text=String(data:data,encoding:.utf8) {
            let words=text.split(separator:"\n").map(String.init)
            if (300...600).contains(words.count),words.allSatisfy({!$0.isEmpty && $0.count<=8 && $0.allSatisfy({$0.isASCII && $0.isLowercase})}) { completeSyllables=Set(words) }
        }
        pinyinCorrector=PinyinCorrection(syllables:completeSyllables,frequency:{[weak self] value in
            guard let code=NineKeySpelling.encode(value) else {return 0};return self?.nineLexicon?.frequency(code) ?? 0
        })
        continuationLexicon=try? ContinuationLexicon(url:semanticDirectory.appendingPathComponent("continuation.bin"))
        let currentMemory=base.appendingPathComponent("nine-choice-memory-v3.json")
        let priorMemory=base.appendingPathComponent("nine-choice-memory-v2.json")
        let legacyMemory=base.appendingPathComponent("nine-choice-memory-v1.json")
        let memoryFile=fileManager.fileExists(atPath:currentMemory.path) ? currentMemory:(fileManager.fileExists(atPath:priorMemory.path) ? priorMemory:legacyMemory)
        if fileManager.fileExists(atPath:memoryFile.path) {
            do {
                let data=try Data(contentsOf:memoryFile);guard data.count<=512*1024 else { throw InputDataError.oversized }
                let decoded=try JSONDecoder().decode(NineKeyChoiceMemory.self,from:data)
                if memoryFile==currentMemory { guard decoded.version==3 else { throw InputDataError.incompatibleSchema } }
                if memoryFile==priorMemory { guard decoded.version==2 else { throw InputDataError.incompatibleSchema } }
                choiceMemory=try decoded.migrated()
                if memoryFile != currentMemory { try saveChoiceMemory(choiceMemory) }
            } catch { choiceMemoryWritable=false }
        }
        coordinator = try LocalLearningCoordinator(base: baseURL!)
        KeyboardRuntimeDiagnostics.record(.nativeLocalStateReady)
        if !Self.initialized {
            // Bundle only prebuilt resources. Never compile dictionaries while typing.
            KeyboardRuntimeDiagnostics.record(.nativeInitializeBegin)
            let initialized = pi_initialize(shared.path, user.path, 0) != 0
            KeyboardRuntimeDiagnostics.record(.nativeInitializeEnd, [.ready: initialized ? 1 : 0])
            guard initialized else { throw EngineFailure.initializeFailed }
            Self.initialized = true; Self.initializedPath = user.path; Self.initializedSharedPath = shared.path;Self.initializedEpoch=personalEpoch
        } else if Self.initializedPath != user.path || Self.initializedSharedPath != shared.path {
            // Rime is process-global; reject a request for another database.
            throw EngineFailure.initializeFailed
        }
        KeyboardRuntimeDiagnostics.record(.nativeSessionBegin)
        session = pi_create_session()
        KeyboardRuntimeDiagnostics.record(.nativeSessionEnd, [.ready: session != 0 ? 1 : 0])
        guard session != 0 else { throw EngineFailure.sessionFailed }
        ready = true
        KeyboardRuntimeDiagnostics.record(.nativeLanguageBegin)
        languageModelReady = pi_language_initialize(shared.path) != 0
        KeyboardRuntimeDiagnostics.record(.nativeLanguageEnd, [.ready: languageModelReady ? 1 : 0])
        commonWords = CommonWordPrior(url:shared.appendingPathComponent("essay.txt"))
        // Auxiliary learning corruption must not disable offline typing. Keep
        // the file for recovery; management/sync will report its own failure.
        managedEntries = (try? coordinator?.entries()) ?? []; cloudCommittedVersion &+= 1
        KeyboardRuntimeDiagnostics.record(.nativeJournalReady, [.sourceCount: Double(managedEntries.count)])
        applyPins(); reload()
        KeyboardRuntimeDiagnostics.record(.nativeStartEnd, [.ready: ready ? 1 : 0])
    }
    @discardableResult func movePinyinCursor(_ direction:Int) -> Bool {
        guard ready,!nineKeyInput,!englishInput,pi_move_pinyin_cursor(session,Int32(direction)) != 0 else{return false}
        markNativeLearningChanged();reload();return true
    }
    func key(_ code: Int32, modifiers: Int32 = 0) -> (handled: Bool, commit: String) {
        guard refreshResetBarrier() else { return (false, "") }
        if !privateInput, rawInput.isEmpty, preedit.isEmpty,
           (65...90).contains(code) || (97...122).contains(code) || (50...57).contains(code) { coordinator?.beginComposition() }

        if rawInput.isEmpty { refreshPersonalLexicon() }
        markNativeLearningChanged()
        let inputCode = !nineKeyInput && !englishInput && code==252 ? Int32(118):code
        let handled = pi_process_key(session, inputCode, modifiers) != 0
        let commit = String(cString: pi_take_commit(session))
        observeCommit(commit);reload(); return (handled, commit)
    }
    func choose(_ index: Int) -> String {
        guard refreshResetBarrier(),index>=0,let row=nativeBatch(offset:index,limit:1).first,candidateIsDisplayable(row.text),pi_select_candidate(session,index) != 0 else{return ""}
        markNativeLearningChanged()
        let commit = String(cString: pi_take_commit(session));observeCommit(commit);reload(); return commit
    }
    func candidateBatch(offset:Int,limit:Int)->[InputCandidate] {
        guard refreshResetBarrier(),offset>=0,limit>0 else{return []}
        if visibilityRevision != revision || visibilityPredictionComplete != predictionComplete {
            visibilityRevision=revision;visibilityPredictionComplete=predictionComplete;visibilityPage = .init()
        }
        // Use a local page to avoid overlapping inout access while the source
        // adapter updates other native caches. Candidate IDs never get renumbered.
        var page=visibilityPage
        let rows=page.slice(offset:offset,limit:limit,accept:{self.candidateIsDisplayable($0.text)},source:{self.orderedCandidateBatch(offset:$0,limit:$1)})
        visibilityPage=page;return rows
    }
    private func orderedCandidateBatch(offset:Int,limit:Int)->[InputCandidate] {
        guard ready,offset>=0,limit>0,!englishInput,(rawInput.count>=4 || coordinator?.scoreSnapshot.isCurrent()==true),commonWords != nil else {
            return unrankedCandidateBatch(offset:offset,limit:limit)
        }
        // Sort a bounded, stable head. Tail offsets and native selection IDs
        // retain their original meaning, including after asynchronous decoding.
        if commonRevision != revision || commonPredictionComplete != predictionComplete {
            commonRevision=revision;commonPredictionComplete=predictionComplete
            commonCandidateTiers=[:]
            commonRows=recentExpressionOrder(commonExpressionOrder(unrankedCandidateBatch(offset:0,limit:64)))
        }
        if offset>=64 {return unrankedCandidateBatch(offset:offset,limit:limit)}
        let head=Array(commonRows.dropFirst(offset).prefix(limit))
        guard commonRows.count==64,head.count<limit else{return head}
        return head+unrankedCandidateBatch(offset:64,limit:limit-head.count)
    }
    /// A verified snapshot is consulted in memory only. Reorder adjacent,
    /// equivalent native candidates; never cross pins, user correction intent,
    /// partial prefixes, repair/assembly classes or public-frequency tiers.
    private func recentExpressionOrder(_ rows:[InputCandidate])->[InputCandidate] {
        guard !privateInput,let snapshot=coordinator?.scoreSnapshot,snapshot.isCurrent(),
              String(cString:pi_selected_prefix(session)).isEmpty else {return rows}
        if let replacement,Date.timeIntervalSinceReferenceDate-replacement.time<=120 {return rows}
        let code=NineKeySpelling.rawCode(rawInput) ?? rawInput
        func identity(_ row:InputCandidate)->String? {
            guard row.index>=0,row.personalID==nil,row.latinInput==nil,row.supplementaryTrigger==nil,
                  row.pinyinRepair==nil,row.replacementInput==nil,row.assemblyID==nil,row.partialCode==nil,
                  row.initialsInput==nil,!row.prefixCompletion,!row.learnedPreference,!isPinned(row),
                  let reading=candidateReading(row),NineKeySpelling.encode(reading)==code,
                  (nineKeyInput || PinyinInputMatch.isFullSpelling(rawInput,reading:reading)),
                  choiceMemory.boost(code:code,reading:reading,text:row.text,context:ownContext)==0 else{return nil}
            let frequency=commonWords?.frequency(row.text) ?? 0
            let tier=commonCandidateTiers[row.index] ?? (frequency>=3000 ? 3:(frequency>=200 ? 2:0))
            return reading+"|"+String(row.text.count)+"|"+String(tier)
        }
        var result=rows,start=0
        while start<rows.count {
            guard let group=identity(rows[start]) else{start+=1;continue}
            var end=start+1
            while end<rows.count,identity(rows[end])==group {end+=1}
            if end-start>1 {
                let ordered=RecencyCoordinator.ordered(Array(rows[start..<end])) {row in
                    guard let reading=candidateReading(row) else{return 0}
                    return snapshot.scores[reading+"\u{001F}"+row.text] ?? 0
                }
                result.replaceSubrange(start..<end,with:ordered)
            }
            start=end
        }
        return result
    }
    func acceptAuthenticatedRecency(policy:RecentLearningPolicy,unixSeconds:Double,uptime:Double=ProcessInfo.processInfo.systemUptime) throws {
        guard let coordinator else{throw LearningSyncFailure.engineUnavailable}
        try coordinator.acceptAuthenticatedRecency(policy:policy,unixSeconds:unixSeconds,uptime:uptime)
        // No visible-candidate refresh during composition; use the next revision.
        if preedit.isEmpty {commonRevision = -1}
    }
    func suspendRecency() {coordinator?.suspendRecency()}
    private func commonExpressionOrder(_ rows:[InputCandidate])->[InputCandidate] {
        guard let commonWords,let code=NineKeySpelling.rawCode(rawInput) else{return rows}
        // An explicit delete-and-retype correction overrides the public prior,
        // including private mode where this intent is deliberately temporary.
        if let rejected=replacement,rejected.code==code,rejected.context==ownContext,
           Date.timeIntervalSinceReferenceDate-rejected.time<=120,
           rejected.rejectedText != nil,rejected.reading != nil {return rows}
        let context=SentenceContextWindow.scoringContext(modelContext.before)
        let positions=rows.indices.filter { i in
            let row=rows[i]
            guard row.index>=0,row.personalID==nil,row.latinInput==nil,row.supplementaryTrigger==nil,
                  row.pinyinRepair==nil,row.replacementInput==nil,row.assemblyID==nil,
                  !row.learnedPreference,(privateInput || !isPinned(row)),row.text.count>=2,
                  NineKeySpelling.encode(row.comment)==code else{return false}
            if !nineKeyInput && !PinyinInputMatch.isFullSpelling(rawInput,reading:row.comment) {return false}
            return privateInput || choiceMemory.boost(code:code,reading:row.comment,text:row.text,context:ownContext)==0
        }
        let groups=Dictionary(grouping:positions,by:{readingIdentity(rows[$0].comment)})
        var result=rows
        for indices in groups.values where indices.count>1 {
            // Strong ordinary heads keep the complete native order: a partial
            // n-gram coincidence must not promote a malformed alternative.
            if let first=indices.first,commonWords.frequency(rows[first].text)>=3000 {continue}
            var tiers:[Int:Int]=[:]
            for i in indices {
                let text=rows[i].text,frequency=commonWords.frequency(text)
                let isolated=languageModelReady ? pi_language_score("",text):Double.nan
                // Frequent whole words stay above sparse n-gram coincidences.
                // Composed expressions need common characters AND real phrase
                // evidence; a missing n-gram is not a reason to demote a word.
                var tier=frequency>=3000 ? 3:0
                if tier==0,text.count<=4,frequency>=200,isolated.isFinite,isolated > -3.5,
                   text.allSatisfy({commonWords.frequency(String($0))>=5000}) {tier=2}
                if tier<3,context.weight>=0.5,!context.text.isEmpty,isolated.isFinite,isolated > -11 {
                    let contextual=pi_language_score(context.text,text)
                    if contextual.isFinite,contextual-isolated>=1.5 {tier=3}
                }
                tiers[i]=tier
                commonCandidateTiers[rows[i].index]=tier
            }
            let order=indices.sorted { a,b in
                if tiers[a] != tiers[b] {return tiers[a,default:0]>tiers[b,default:0]}
                return a<b
            }
            for (slot,source) in zip(indices,order) {result[slot]=rows[source]}
        }
        return result
    }
    private func unrankedCandidateBatch(offset:Int,limit:Int)->[InputCandidate] {
        guard ready,offset>=0,limit>0 else{return []}
        guard nineKeyInput,!nativeBatch(offset:0,limit:1).isEmpty else{return baseCandidateBatch(offset:offset,limit:limit)}
        let completions=ninePrefixCompletions(),extras=initialsCandidates()
        if !completions.isEmpty {
            let base=baseCandidateBatch(offset:0,limit:64)
            let protected=Array(base.prefix(while:{$0.personalID != nil || isPinned($0)}))
            var seen=Set<String>()
            let front=(protected+completions+base+extras).filter{seen.insert($0.text).inserted}
            var result=Array(front.dropFirst(offset).prefix(limit)),skip=max(0,offset-front.count),cursor=64
            while result.count<limit,base.count==64 {
                let rows=baseCandidateBatch(offset:cursor,limit:64)
                for row in rows where !seen.contains(row.text) {
                    if skip>0 {skip-=1}else{result.append(row);if result.count==limit{break}}
                }
                cursor+=rows.count;if rows.count<64{break}
            }
            return result
        }
        guard !extras.isEmpty else{return baseCandidateBatch(offset:offset,limit:limit)}
        let base=baseCandidateBatch(offset:0,limit:64)
        let explicit=(base.lastIndex(where:{$0.personalID != nil || isPinned($0)}) ?? -1)+1
        let protectedCount=min(base.count,max(3,explicit))
        let leading=Array(base.prefix(protectedCount))
        let full=extras.filter{$0.initialsInput?.count==rawInput.count}
        var seen=Set<String>()
        let front=(leading+Array(full.prefix(8))+Array(base.dropFirst(protectedCount))+extras).filter{seen.insert($0.text).inserted}
        var result=Array(front.dropFirst(offset).prefix(limit)),skip=max(0,offset-front.count),cursor=64
        while result.count<limit,base.count==64 {
            let rows=baseCandidateBatch(offset:cursor,limit:64)
            for row in rows where !seen.contains(row.text) {
                if skip>0 {skip-=1}else{result.append(row);if result.count==limit{break}}
            }
            cursor+=rows.count;if rows.count<64{break}
        }
        return result
    }
    private var prefixCompletionRevision = -1
    private var prefixCompletionRows:[InputCandidate]=[]
    /// A complete short parse (ji nv at 5468) must not suppress a common
    /// cross-syllable continuation (jin t...). Proposals append keys only;
    /// the exact draft and every legitimate native alternative stay intact.
    private func ninePrefixCompletions()->[InputCandidate] {
        guard ready,nineKeyInput,!englishInput,pi_cursor_at_end(session) != 0,let commonWords,let nineLexicon else{return []}
        if prefixCompletionRevision==revision {return prefixCompletionRows}
        prefixCompletionRevision=revision;prefixCompletionRows=[]
        let active=Int(pi_unselected_input_start(session))
        guard active>=0,active<=rawInput.count else{return []}
        let tail=String(rawInput.dropFirst(active))
        guard NineKeySpelling.isCode(tail),(3...12).contains(tail.count),
              let first=nativeBatch(offset:0,limit:1).first,!isPinned(first),first.personalID==nil else{return []}
        // Preserve ordinary exact heads such as you/有, neng/能 and nong/弄.
        // Do not globally favour long output or turn incomplete keys into edits.
        let baseline=commonWords.frequency(first.text)
        guard baseline<3000 else{return []}
        let proposals=nineLexicon.completions(tail,limit:6)
        guard !proposals.isEmpty else{return []}
        let probe=pi_create_session();guard probe != 0 else{return []};defer{pi_destroy_session(probe)}
        guard pi_set_private(probe,1) != 0,pi_set_nine_key(probe,1) != 0 else{return []}
        var ranked:[(row:InputCandidate,frequency:UInt64)]=[]
        for proposal in proposals {
            guard pi_set_prediction_input(probe,proposal.input) != 0 else{continue}
            let count=Int(pi_load_candidate_batch(probe,0,8))
            for index in 0..<count {
                let text=String(cString:pi_batch_candidate_text(probe,index)),reading=String(cString:pi_batch_candidate_comment(probe,index))
                let frequency=commonWords.frequency(text)
                guard frequency>=3000,frequency>baseline*4,text.count>=2,fullySpelled(reading),
                      readingParts(reading).count==text.count,NineKeySpelling.encode(reading)==proposal.input,
                      PinyinInputMatch.consumedPrefix(tail,reading:reading,nineKey:true)==tail.count,
                      candidateIsDisplayable(text),!ranked.contains(where:{$0.row.text==text}) else{continue}
                ranked.append((InputCandidate(text:text,comment:reading,index:-68000-ranked.count,sourceInput:rawInput,generation:revision,initialsInput:tail,prefixCompletion:true),frequency))
            }
        }
        prefixCompletionRows=Array(ranked.sorted{$0.frequency==$1.frequency ? $0.row.index>$1.row.index:$0.frequency>$1.frequency}.prefix(3).map(\.row))
        return prefixCompletionRows
    }
    private func baseCandidateBatch(offset: Int, limit: Int) -> [InputCandidate] {
        guard ready, offset >= 0, limit > 0 else { return [] }
        let personal=personalCandidates()
        let personalTexts=Set(personal.map(\.text))
        let latin=mixedCandidates().filter{!personalTexts.contains($0.text)}
        let latinTexts=Set(latin.map(\.text))
        let proposed=supplementaryCandidates().filter{!personalTexts.contains($0.text) && !latinTexts.contains($0.text)}
        guard !personal.isEmpty || !latin.isEmpty || !proposed.isEmpty else { return coreCandidateBatch(offset:offset,limit:limit) }
        let nativeSeed:[InputCandidate]
        if latin.isEmpty && proposed.isEmpty {nativeSeed=[]}
        else if !nineKeyInput && !latin.isEmpty {nativeSeed=coreCandidateBatch(offset:0,limit:32)}
        else if !rareFullSpellingCompletions().isEmpty {nativeSeed=coreCandidateBatch(offset:0,limit:32)}
        else {nativeSeed=preferenceNativeHead(limit:32)}
        let nativeTexts=Set(nativeSeed.map(\.text))
        // A system shortcut that equals a common native word must not remove
        // that word from its original first position and reinsert it later.
        let supplements=proposed.filter{!nativeTexts.contains($0.text)}
        guard !personal.isEmpty || !latin.isEmpty || !supplements.isEmpty else { return coreCandidateBatch(offset:offset,limit:limit) }
        let texts=Set((personal+latin+supplements).map(\.text))
        // Keep the words/widths preceding English fixed during asynchronous
        // ranking. A displayed English target must not move under a finger.
        let chineseSlots = !nineKeyInput && mixedChinesePriority && !latin.isEmpty ? 6:3
        let nativeFront = (latin.isEmpty && supplements.isEmpty) || (mixedLeads && supplements.isEmpty) ? []:Array(nativeSeed.filter{!texts.contains($0.text)}.prefix(chineseSlots))
        let front=personal+nativeFront+latin+supplements
        let indices=Set(nativeFront.map(\.index))
        // Translate visible offsets after removing native duplicates. The
        // native lazy tail remains reachable and keeps its absolute indices.
        var result=Array(front.dropFirst(offset).prefix(limit))
        var skip=max(0,offset-front.count),cursor=0
        while result.count<limit {
            let rows=coreCandidateBatch(offset:cursor,limit:64)
            for row in rows where !texts.contains(row.text) && !indices.contains(row.index) {
                if skip>0 { skip-=1 } else { result.append(row);if result.count==limit { break } }
            }
            cursor+=rows.count
            if rows.count<64 { break }
        }
        return result
    }
    private var hasHomophonePreference:Bool {
        guard !englishInput,!rawInput.isEmpty,pi_cursor_at_end(session) != 0,String(cString:pi_selected_prefix(session)).trimmingCharacters(in:.whitespaces).isEmpty,
              let code=NineKeySpelling.rawCode(rawInput) else { return false }
        return (replacement.map{$0.code==code && $0.context==ownContext && Date.timeIntervalSinceReferenceDate-$0.time<=120 && $0.rejectedText != nil && $0.reading != nil} ?? false) || (!privateInput && choiceMemory.entries.contains{$0.code==code})
    }
    private func preferenceNativeHead(limit:Int) -> [InputCandidate] {
        guard hasHomophonePreference else { return nativeBatch(offset:0,limit:limit) }
        if preferenceNativeRevision != revision { preferenceNativeRevision=revision;preferenceNativeRows=homophoneOrder(nativeBatch(offset:0,limit:64)) }
        return Array(preferenceNativeRows.prefix(limit))
    }
    private func coreCandidateBatch(offset:Int,limit:Int) -> [InputCandidate] {
        if !nineKeyInput,!pinyinRepairCandidates().isEmpty {return rawCoreCandidateBatch(offset:offset,limit:limit)}
        if nativeBatch(offset:0,limit:1).isEmpty {return rawCoreCandidateBatch(offset:offset,limit:limit)}
        guard hasHomophonePreference else { return rawCoreCandidateBatch(offset:offset,limit:limit) }
        let head:[InputCandidate]
        if predictionComplete && predictionRevision==revision {
            if preferencePredictionRevision != revision { preferencePredictionRevision=revision;preferencePredictionRows=homophoneOrder(rawCoreCandidateBatch(offset:0,limit:64)) }
            head=preferencePredictionRows
        } else { head=preferenceNativeHead(limit:64) }
        let first=Array(head.dropFirst(offset).prefix(limit))
        if first.count==limit || head.count<64 { return first }
        return first+rawCoreCandidateBatch(offset:max(64,offset),limit:limit-first.count)
    }
    private func readingIdentity(_ reading:String) -> String {
        reading.lowercased().split(whereSeparator:{$0.isWhitespace || $0=="'"}).joined(separator:"'")
    }
    private func homophoneOrder(_ rows:[InputCandidate]) -> [InputCandidate] {
        guard let code=NineKeySpelling.rawCode(rawInput) else { return rows }
        func normalized(_ reading:String) -> String { readingIdentity(reading) }
        let rejected=replacement.flatMap { r -> (String,String)? in
            guard r.code==code,r.context==ownContext,Date.timeIntervalSinceReferenceDate-r.time<=120,let text=r.rejectedText,let reading=r.reading else { return nil }
            return (text,normalized(reading))
        }
        let indices=rows.indices.filter{rows[$0].replacementInput==nil && rows[$0].assemblyID==nil && rows[$0].index>=0 && !isPinned(rows[$0]) && !normalized(rows[$0].comment).isEmpty}
        let groups=Dictionary(grouping:indices,by:{normalized(rows[$0].comment)})
        var result=rows
        for (reading,positions) in groups where positions.count>1 {
            let scores=Dictionary(uniqueKeysWithValues:positions.map { i in (i,privateInput ? 0:choiceMemory.boost(code:code,reading:rows[i].comment,text:rows[i].text,context:ownContext)) })
            let order=positions.sorted { a,b in
                let rejectA=rejected.map{$0.0==rows[a].text && $0.1==reading} ?? false,rejectB=rejected.map{$0.0==rows[b].text && $0.1==reading} ?? false
                if rejectA != rejectB { return !rejectA }
                if scores[a] != scores[b] { return scores[a,default:0]>scores[b,default:0] }
                if scores[a,default:0]>0 {
                    let recencyA=choiceMemory.entries.lastIndex{$0.code==code && $0.reading==reading.replacingOccurrences(of:"'",with:"") && $0.text==rows[a].text} ?? -1
                    let recencyB=choiceMemory.entries.lastIndex{$0.code==code && $0.reading==reading.replacingOccurrences(of:"'",with:"") && $0.text==rows[b].text} ?? -1
                    if recencyA != recencyB { return recencyA>recencyB }
                }
                return a<b
            }
            for (slot,source) in zip(positions,order) { result[slot]=rows[source] }
        }
        return result
    }
    #if PRIVATE_INPUT_DEVELOPMENT_DIAGNOSTICS
    var compositionSelectionForAcceptance:(prefix:String,offset:Int) {
        guard ready else{return ("",-1)}
        return (String(cString:pi_selected_prefix(session)),Int(truncatingIfNeeded:pi_unselected_input_start(session)))
    }
    #endif
    private func activePinyinDraft()->(prefix:String,input:String,offset:Int)? {
        let raw=rawInput,prefix=String(cString:pi_selected_prefix(session)).trimmingCharacters(in:.whitespaces)
        var offset=Int(pi_unselected_input_start(session))
        if offset<0,prefix.isEmpty {offset=0}
        guard offset>=0,offset<=raw.count else{return nil}
        return (prefix,String(raw.dropFirst(offset)),offset)
    }
    private func rawCoreCandidateBatch(offset:Int,limit:Int) -> [InputCandidate] {
        if !nineKeyInput,!englishInput {
            let repairs=pinyinRepairCandidates(),initials=initialsCandidates()
            let activeInput=activePinyinDraft()?.input ?? rawInput
            if !repairs.isEmpty || !initials.isEmpty {
                let ordinary=nativeBatch(offset:0,limit:32)
                // Keep the established typo-repair priority for long vowel
                // spellings. Repeated-initial mixtures have their own verified
                // path and must not admit arbitrary abbreviated long sentences.
                let maxAbbreviations=activeInput.count>=7 && activeInput.contains(where:{"aeiouv".contains($0)}) ? 1:Int.max
                let normal=ordinary.filter{PinyinInputMatch.covers(activeInput,reading:$0.comment,maxAbbreviations:maxAbbreviations)}
                // All exact readings retain their native relative order, not
                // just three protected slots before correction alternatives.
                let exact=ordinary.filter{fullySpelled($0.comment) && PinyinInputMatch.isFullSpelling(activeInput,reading:$0.comment)}
                let whole=initials.filter{$0.initialsInput?.count==activeInput.count}
                let proposed=exact+whole+normal+repairs+initials
                var seen=Set<String>()
                let front=proposed.filter{seen.insert($0.text).inserted}
                let texts=Set(front.map(\.text))
                var result=Array(front.dropFirst(offset).prefix(limit))
                var skip=max(0,offset-front.count),cursor=0
                while result.count<limit {
                    let rows=nativeBatch(offset:cursor,limit:32)
                    for row in rows where !texts.contains(row.text) {
                        if skip>0 {skip-=1} else {result.append(row);if result.count==limit {break}}
                    }
                    cursor+=rows.count;if rows.count<32 {break}
                }
                return result
            }
        }
        if nativeBatch(offset:0,limit:1).isEmpty {
            let fallback=recoveryCandidates()
            let predicted=(predictionComplete && predictionRevision==revision ? predictionHead:[]).map{row in
                fallback.first(where:{$0.text==row.text}) ?? row
            }
            // Repeated initials are an intentional, common expression. Keep
            // them stable while asynchronous typo proposals arrive. Other
            // abbreviations stay behind verified correction results.
            let active=Int(pi_unselected_input_start(session))
            let tailCount=active>=0 && active<=rawInput.count ? rawInput.count-active:0
            let complete=fallback.filter{$0.initialsInput?.count==tailCount}
            var seen=Set<String>()
            let partial=fallback.filter{($0.initialsInput?.count ?? tailCount)<tailCount || $0.partialCode != nil}
            let rows=(fallback.filter{isPinned($0)}+Array(complete.prefix(8))+Array(partial.prefix(8))+Array(predicted.prefix(16))+complete+predicted+fallback).filter{seen.insert($0.text).inserted}
            return Array(rows.dropFirst(offset).prefix(limit))
        }
        if predictionComplete && predictionRevision == revision {
            let first=Array(predictionHead.dropFirst(offset).prefix(limit))
            if first.count==limit { return first }
            let tailOffset=max(0,offset-predictionHead.count)+predictionOriginal.count
            return first + nativeBatch(offset:tailOffset,limit:limit-first.count)
        }
        let rows=nativeBatch(offset:offset,limit:limit)
        if !rows.isEmpty || !nativeBatch(offset:0,limit:1).isEmpty {return rows}
        return Array(recoveryCandidates().dropFirst(offset).prefix(limit))
    }
    private func recoveryCandidates() -> [InputCandidate] {
        // Retain exact partial recovery alongside independently matched initials.
        let partial=partialRecoveryCandidates()
        let initials=initialsCandidates()
        return partial+initials
    }
    /// Empty menus and explicit repeated initials use a bounded private probe.
    /// Every candidate records its consumed prefix; untouched tails stay editable.
    private var rareCompletionRevision = -1
    private var rareCompletionRows:[InputCandidate]=[]
    /// A legitimate but unattested supplementary Han character can monopolize
    /// Rime's exact match and suppress every ordinary prefix completion.
    /// Preserve it, but offer common dictionary-validated continuations first.
    private func rareFullSpellingCompletions()->[InputCandidate] {
        guard ready,!nineKeyInput,!englishInput,pi_cursor_at_end(session) != 0,
              String(cString:pi_selected_prefix(session)).isEmpty else{return []}
        if rareCompletionRevision==revision {return rareCompletionRows}
        rareCompletionRevision=revision;rareCompletionRows=[]
        let raw=rawInput
        guard (2...5).contains(raw.count),raw.utf8.allSatisfy({(97...122).contains($0)}),
              let commonWords,let code=NineKeySpelling.rawCode(raw) else{return []}
        let ordinary=nativeBatch(offset:0,limit:32)
        let exact=ordinary.filter{PinyinInputMatch.isFullSpelling(raw,reading:$0.comment)}
        guard !exact.isEmpty,exact.allSatisfy({row in
            if !candidateIsDisplayable(row.text) {return true}
            return row.text.unicodeScalars.count==1 && row.text.unicodeScalars.allSatisfy({$0.value>0xFFFF && $0.properties.isIdeographic}) &&
            commonWords.frequency(row.text)==0 && !isPinned(row) &&
            (privateInput || choiceMemory.boost(code:code,reading:row.comment,text:row.text,context:ownContext)==0)
        }) else{return []}
        let spellings=completeSyllables.filter{$0.count>raw.count && $0.hasPrefix(raw)}.sorted()
        guard !spellings.isEmpty else{return []}
        let probe=pi_create_session();guard probe != 0 else{return []};defer{pi_destroy_session(probe)}
        guard pi_set_private(probe,1) != 0,pi_set_nine_key(probe,0) != 0 else{return []}
        var result:[InputCandidate]=[]
        let existing=Set(ordinary.map(\.text))
        for spelling in spellings.prefix(8) {
            guard pi_set_pinyin_probe_input(probe,spelling) != 0 else{continue}
            let count=Int(pi_load_candidate_batch(probe,0,8))
            for i in 0..<count {
                let text=String(cString:pi_batch_candidate_text(probe,i)),reading=String(cString:pi_batch_candidate_comment(probe,i))
                let frequency=commonWords.frequency(text)
                guard text.count==1,frequency>=3000,readingParts(reading)==[spelling],!existing.contains(text),
                      !result.contains(where:{$0.text==text}) else{continue}
                result.append(InputCandidate(text:text,comment:reading,index:-66000-result.count,sourceInput:raw,generation:revision,initialsInput:raw,prefixCompletion:true))
            }
        }
        // Keep native order within each completed reading. A globally common
        // character can have a rare alternate reading at this spelling.
        rareCompletionRows=Array(result.sorted {a,b in
            let pinA = !privateInput && isPinned(a),pinB = !privateInput && isPinned(b)
            return pinA != pinB ? pinA:a.index>b.index
        }.prefix(8))
        return rareCompletionRows
    }
    private func initialsCandidates() -> [InputCandidate] {
        guard ready,!englishInput,pi_cursor_at_end(session) != 0 else{return []}
        if !nineKeyInput {
            let completions=rareFullSpellingCompletions()
            if !completions.isEmpty {return completions}
        }
        if nineKeyInput {
            guard nativeBatch(offset:0,limit:1).isEmpty || rawInput.prefix(while:{$0==rawInput.first}).count>=2 else{return []}
        } else {
            guard rawInput.prefix(while:{$0==rawInput.first}).count>=2,
                  !nativeBatch(offset:0,limit:32).contains(where:{PinyinInputMatch.isFullSpelling(rawInput,reading:$0.comment)}) else{return []}
        }
        if initialsRevision==revision {return initialsRows}
        initialsRevision=revision;initialsRows=[]
        var active=Int(pi_unselected_input_start(session))
        if active<0,!nineKeyInput,String(cString:pi_selected_prefix(session)).isEmpty {active=0}
        guard active>=0,active<=rawInput.count else {return []}
        let tail=String(rawInput.dropFirst(active))
        guard tail.count>=2 else{return []}
        let digits:String
        if nineKeyInput {guard NineKeySpelling.isCode(tail) else{return []};digits=tail}
        else {guard let encoded=NineKeySpelling.encode(tail),tail.utf8.allSatisfy({(97...122).contains($0)}) else{return []};digits=encoded}
        // A mixed spelling needs its suffix to be decoded too. Uniform long
        // runs stay bounded; selecting their prefix retains every remaining key.
        let code=String(digits.prefix(Set(tail).count==1 ? 8:16)),source=String(tail.prefix(Set(tail).count==1 ? 8:16)),probe=pi_create_session()
        guard probe != 0 else {return []};defer{pi_destroy_session(probe)}
        guard pi_set_nine_key(probe,1) != 0,pi_set_private(probe,1) != 0,
              pi_set_nine_initials_probe_input(probe,code) != 0 else{return []}
        let count=Int(pi_load_candidate_batch(probe,0,32))
        for i in 0..<count {
            let text=String(cString:pi_batch_candidate_text(probe,i)),reading=String(cString:pi_batch_candidate_comment(probe,i))
            guard !text.isEmpty,fullySpelled(reading),readingParts(reading).count==text.count else{continue}
            guard let consumed=PinyinInputMatch.consumedPrefix(source,reading:reading,nineKey:nineKeyInput),consumed>0 else {continue}
            initialsRows.append(InputCandidate(text:text,comment:reading,index:-60000-initialsRows.count,sourceInput:rawInput,generation:revision,initialsInput:String(source.prefix(consumed))))
        }
        // Rime emits one best composed sentence and then prefix words. Reuse
        // those prefixes to expose full suffix alternatives without changing
        // the normal prism or launching a search for every split point.
        let run=tail.prefix{ $0==tail.first }.count
        let boundaries=run<tail.count ? [run-1,run].filter{(2...8).contains($0)}:[]
        // Query the transition independently: sentence-level prefix ordering
        // must not starve common repeated words before a fully spelled tail.
        if !boundaries.isEmpty {
            let prefixProbe=pi_create_session()
            if prefixProbe != 0 {
                defer{pi_destroy_session(prefixProbe)}
                if pi_set_nine_key(prefixProbe,1) != 0,pi_set_private(prefixProbe,1) != 0 {
                    for cut in boundaries {
                        pi_clear(prefixProbe)
                        let prefix=String(tail.prefix(cut)),query=String(digits.prefix(cut))
                        guard pi_set_nine_initials_probe_input(prefixProbe,query) != 0 else{continue}
                        let count=Int(pi_load_candidate_batch(prefixProbe,0,64))
                        for i in 0..<count {
                            let text=String(cString:pi_batch_candidate_text(prefixProbe,i)),reading=String(cString:pi_batch_candidate_comment(prefixProbe,i))
                            guard !text.isEmpty,fullySpelled(reading),readingParts(reading).count==text.count,
                                  PinyinInputMatch.consumedPrefix(prefix,reading:reading,nineKey:nineKeyInput)==cut,
                                  !initialsRows.contains(where:{$0.text==text && $0.initialsInput==prefix}) else{continue}
                            initialsRows.append(InputCandidate(text:text,comment:reading,index:-60000-initialsRows.count,sourceInput:rawInput,generation:revision,initialsInput:prefix))
                        }
                    }
                }
            }
        }
        // Numeric 22 can be full ba, hiding abbreviation bb behind hundreds
        // of homophones. Query each actual initial in Latin independently so
        // repeated-initial words keep their ordinary word-frequency order.
        var repeatedHeads:[InputCandidate]=[]
        if let first=tail.first,!boundaries.isEmpty {
            let initial=String(first)
            let letters=nineKeyInput ? Array("abcdefghijklmnopqrstuvwxyz").map(String.init).filter{NineKeySpelling.encode($0)==initial}:[initial]
            let repeatProbe=pi_create_session()
            if repeatProbe != 0 {
                defer{pi_destroy_session(repeatProbe)}
                if pi_set_private(repeatProbe,1) != 0,pi_set_nine_key(repeatProbe,0) != 0 {
                    for cut in boundaries {
                        let prefix=String(tail.prefix(cut))
                        for letter in letters {
                            pi_clear(repeatProbe)
                            for key in String(repeating:letter,count:cut).utf8 {_ = pi_process_key(repeatProbe,Int32(key),0)}
                            let count=Int(pi_load_candidate_batch(repeatProbe,0,32))
                            for i in 0..<count {
                                let text=String(cString:pi_batch_candidate_text(repeatProbe,i)),reading=String(cString:pi_batch_candidate_comment(repeatProbe,i))
                                guard !text.isEmpty,fullySpelled(reading),readingParts(reading).count==text.count,
                                      PinyinInputMatch.consumedPrefix(prefix,reading:reading,nineKey:nineKeyInput)==cut,
                                      !initialsRows.contains(where:{$0.text==text && $0.initialsInput==prefix}),
                                      !repeatedHeads.contains(where:{$0.text==text && $0.initialsInput==prefix}) else{continue}
                                repeatedHeads.append(InputCandidate(text:text,comment:reading,index:-65000-repeatedHeads.count,sourceInput:rawInput,generation:revision,initialsInput:prefix))
                            }
                        }
                    }
                }
            }
        }
        let prefixes=initialsRows.filter{($0.initialsInput?.count ?? 0)<tail.count}+repeatedHeads
        var visited=Set<Int>()
        let available=prefixes.compactMap{$0.initialsInput?.count}.filter{tail.count-$0<=16}
        let cuts=Array((boundaries+available.sorted(by:>)).filter{visited.insert($0).inserted}.prefix(5))
        let exact=pi_create_session()
        if exact != 0 {
            defer{pi_destroy_session(exact)}
            if pi_set_nine_key(exact,1) != 0,pi_set_private(exact,1) != 0 {
                for cut in cuts {
                    let suffix=String(tail.dropFirst(cut)),query=String(digits.dropFirst(cut))
                    guard pi_set_prediction_input(exact,query) != 0 else{continue}
                    let count=Int(pi_load_candidate_batch(exact,0,6))
                    let heads=prefixes.filter{$0.initialsInput?.count==cut}.sorted{a,b in
                        let uniformA=a.text.count>=2 && Set(a.text).count==1,uniformB=b.text.count>=2 && Set(b.text).count==1
                        return uniformA != uniformB ? uniformA:a.index>b.index
                    }.prefix(64)
                    for i in 0..<count {
                        let text=String(cString:pi_batch_candidate_text(exact,i)),reading=String(cString:pi_batch_candidate_comment(exact,i))
                        guard !text.isEmpty,fullySpelled(reading),NineKeySpelling.encode(reading)==query,readingParts(reading).count==text.count,
                              nineKeyInput || PinyinInputMatch.isFullSpelling(suffix,reading:reading) else{continue}
                        for head in heads.prefix(i==0 ? 64:16) {
                            let joined=head.text+text
                            let suffixWeight=head.text.count>=2 && Set(head.text).count==1 ? suffix.count:0
                            if let existing=initialsRows.firstIndex(where:{$0.text==joined && $0.initialsInput==tail}) {
                                initialsRows[existing].initialsSuffix=max(initialsRows[existing].initialsSuffix,suffixWeight)
                                continue
                            }
                            initialsRows.append(InputCandidate(text:joined,comment:head.comment+" "+reading,index:-60000-initialsRows.count,sourceInput:rawInput,generation:revision,initialsInput:tail,initialsSuffix:suffixWeight))
                            if initialsRows.count>=512 {break}
                        }
                        if initialsRows.count>=512 {break}
                    }
                    if initialsRows.count>=512 {break}
                }
            }
        }
        initialsRows+=repeatedHeads
        initialsRows.sort{a,b in
            let fullA=a.initialsInput?.count==tail.count,fullB=b.initialsInput?.count==tail.count
            if fullA != fullB {return fullA}
            if fullA,a.initialsSuffix != b.initialsSuffix {return a.initialsSuffix>b.initialsSuffix}
            return a.index>b.index
        }
        return initialsRows
    }
    var alphabeticRankingInput:String {activePinyinDraft()?.input ?? rawInput}
    private func pinyinRepairCandidates() -> [InputCandidate] {
        guard ready,!nineKeyInput,!englishInput,pi_cursor_at_end(session) != 0 else {return []}
        if pinyinRevision==revision {return pinyinRows}
        pinyinRevision=revision;pinyinRows=[]
        guard let draft=activePinyinDraft() else{return []}
        let selected=draft.prefix,tail=draft.input
        guard (4...96).contains(tail.count),tail.utf8.allSatisfy({(97...122).contains($0)}) else {return []}
        let ordinary=nativeBatch(offset:0,limit:32)
        // A repair with the same visible text must not replace a native
        // selection which already covers the draft, or a native prefix before
        // an unfinished next syllable. Otherwise choosing 这个 at zheged
        // silently drops the next initial d. Genuine edits such as shijei /
        // shi jie (or an extra complete vowel) remain repair alternatives.
        let protectedNativeTexts=Set(ordinary.filter { row in
            if PinyinInputMatch.covers(tail,reading:row.comment) {return true}
            guard let consumed=PinyinInputMatch.consumedPrefix(tail,reading:row.comment,nineKey:false),consumed>0,consumed<tail.count else{return false}
            let unfinished=PinyinInputMatch.canonicalSyllable(String(tail.dropFirst(consumed)))
            return !completeSyllables.contains(unfinished) && completeSyllables.contains(where:{$0.hasPrefix(unfinished)})
        }.map(\.text))
        // Exact paths are protected by presentation tiers, not by deleting
        // correction recall. Short exact drafts retain eight bounded probes.
        let bytes=Array(tail.utf8),hasDuplicate=zip(bytes,bytes.dropFirst()).contains{$0==$1}
        let probeLimit=tail.count<10 && !hasDuplicate && ordinary.contains(where:{fullySpelled($0.comment) && PinyinInputMatch.isFullSpelling(tail,reading:$0.comment)}) ? 8:64
        let probe=pi_create_session();guard probe != 0 else {return []};defer {pi_destroy_session(probe)}
        guard pi_set_private(probe,1) != 0,pi_set_nine_key(probe,0) != 0,pi_set_ascii_mode(probe,0) != 0 else {return []}
        var ranked:[(row:InputCandidate,score:Double)]=[]
        for proposal in (pinyinCorrector?.proposals(tail,limit:64) ?? []).prefix(probeLimit) {
            guard pi_set_pinyin_probe_input(probe,proposal.spelling) != 0 else {continue}
            let count=Int(pi_load_candidate_batch(probe,0,16))
            for i in 0..<count {
                let text=String(cString:pi_batch_candidate_text(probe,i)),reading=String(cString:pi_batch_candidate_comment(probe,i))
                guard !text.isEmpty,!protectedNativeTexts.contains(text),fullySpelled(reading),readingParts(reading).joined()==proposal.spelling else {continue}
                let language=pi_language_score(modelContext.before,text)
                let code=NineKeySpelling.encode(tail) ?? ""
                let learned=privateInput ? 0:choiceMemory.boost(code:code,reading:reading,text:text,context:SentenceContextWindow.append(selected,to:ownContext))
                let lexical=log1p(Double(nineLexicon?.frequency(NineKeySpelling.encode(proposal.spelling) ?? "") ?? 0))
                // Sparse bigram evidence cannot veto a common dictionary word
                // or promote a rare homophone over the native frequency order.
                let grammar=language.isFinite ? max(-6,min(0,language))*0.5:-3
                let score=tail.count>=10 ? (language.isFinite ? language:-12)-proposal.cost*3-Double(i)*0.12+learned:grammar-proposal.cost*3-Double(i)*0.8+min(4,lexical*0.5)+learned
                let row=InputCandidate(text:text,comment:reading,index:-50000-ranked.count,sourceInput:rawInput,generation:revision,pinyinRepair:proposal.spelling,learnedPreference:learned>0)
                if let old=ranked.firstIndex(where:{$0.row.text==text}) {
                    if score>ranked[old].score {ranked[old]=(row,score)}
                } else {ranked.append((row,score))}
            }
        }
        pinyinRows=Array(ranked.sorted{$0.score==$1.score ? $0.row.text<$1.row.text:$0.score>$1.score}.prefix(16).map(\.row))
        // A severely malformed suffix must not make a valid prefix unusable.
        if pinyinRows.isEmpty,ordinary.isEmpty {
            for cut in stride(from:min(32,tail.count-1),through:1,by:-1) {
                let prefix=String(tail.prefix(cut));guard pi_set_pinyin_probe_input(probe,prefix) != 0 else {continue}
                let count=Int(pi_load_candidate_batch(probe,0,8))
                for i in 0..<count {
                    let text=String(cString:pi_batch_candidate_text(probe,i)),reading=String(cString:pi_batch_candidate_comment(probe,i))
                    if fullySpelled(reading),readingParts(reading).joined()==prefix {
                        pinyinRows.append(InputCandidate(text:text,comment:reading,index:-51000-i,sourceInput:rawInput,generation:revision,pinyinRepair:prefix,pinyinRemainder:String(tail.dropFirst(cut))))
                    }
                }
                if !pinyinRows.isEmpty {break}
            }
        }
        return pinyinRows
    }
    /// When the entire spelling cannot decode, offer an exact readable prefix.
    /// Selecting it commits that prefix only; every remaining key stays editable.
    func partialRecoveryCandidates() -> [InputCandidate] {
        guard ready,nineKeyInput,!englishInput,pi_cursor_at_end(session) != 0 else {return []}
        if recoveryRevision==revision {return recoveryRows}
        recoveryRevision=revision;recoveryRows=[]
        let active=Int(pi_unselected_input_start(session))
        guard active>=0,active<=rawInput.count else {return []}
        let tail=String(rawInput.dropFirst(active))
        guard NineKeySpelling.isCode(tail),tail.count>1,tail.count<=96 else {return []}
        let probe=pi_create_session();guard probe != 0 else {return []};defer {pi_destroy_session(probe)}
        guard pi_set_nine_key(probe,1) != 0,pi_set_private(probe,1) != 0,pi_set_ascii_mode(probe,0) != 0 else {return []}
        let cuts=Array(Set(Array((max(1,tail.count-8)..<tail.count).reversed())+[18,12,9,6,3,2,1].filter{$0<tail.count})).sorted(by:>)
        for cut in cuts.prefix(15) {
            let prefix=String(tail.prefix(cut))
            guard pi_set_prediction_input(probe,prefix) != 0 else {continue}
            let count=Int(pi_load_candidate_batch(probe,0,8))
            for i in 0..<count {
                let text=String(cString:pi_batch_candidate_text(probe,i)),reading=String(cString:pi_batch_candidate_comment(probe,i))
                guard !text.isEmpty,fullySpelled(reading),NineKeySpelling.encode(reading)==prefix else {continue}
                recoveryRows.append(InputCandidate(text:text,comment:reading,index:-40000-recoveryRows.count,sourceInput:rawInput,generation:revision,partialCode:prefix))
            }
            if !recoveryRows.isEmpty {break}
        }
        return recoveryRows
    }
    private func refreshPersonalLexicon() {
        // Unreadable/revoked shared files do not retain stale private content.
        personalLexicon=(try? personalStore?.load()) ?? PersonalLexicon()
    }
    @discardableResult func setMixedEnglishEnabled(_ enabled:Bool) -> Bool {
        guard ready,rawInput.isEmpty,mixedEnglishEnabled != enabled else { return false }
        mixedEnglishEnabled=enabled;reload();return true
    }
    private func mixedCandidates() -> [InputCandidate] {
        guard mixedEnglishEnabled,!englishInput,!rawInput.isEmpty,pi_cursor_at_end(session) != 0 else { return [] }
        if mixedRevision==revision { return mixedRows }
        mixedRevision=revision;mixedRows=[];mixedLeads=false;mixedChinesePriority=false;mixedLatinDisplayAllowed=false
        let raw=rawInput,selected=String(cString:pi_selected_prefix(session)).trimmingCharacters(in:.whitespaces)
        var active=Int(pi_unselected_input_start(session))
        if active<0,!nineKeyInput,selected.isEmpty,raw.utf8.allSatisfy({(97...122).contains($0)}) { active=0 }
        guard active>=0,active<=raw.count else { return [] }
        let pending=String(raw.dropFirst(active))
        guard pending.count<=32 else { return [] }
        let system = !nineKeyInput && pending.count>=3 && pending.utf8.allSatisfy({(97...122).contains($0)}) ? (mixedEnglishProvider?(pending) ?? []):[]
        let words=MixedEnglishLexicon.suggestions(input:pending,nineKey:nineKeyInput,systemWords:system)
        mixedRows=words.enumerated().map { i,text in
            InputCandidate(text:text,comment:"英文",index:-20000-i,sourceInput:raw,generation:revision,latinInput:pending)
        }
        // The Chinese mode accepts full pinyin, initials and an unfinished
        // final syllable. An exact Latin dictionary hit is not proof that the
        // same draft is English (for example, a valid two-syllable abbreviation).
        if !nineKeyInput {
            let context=modelContext
            let sentenceHasHan=(selected+context.before+context.after).unicodeScalars.contains{$0.properties.isIdeographic}
            let chinese=coreCandidateBatch(offset:0,limit:32)
            let supported=chinese.contains { row in
                row.latinInput==nil && row.pinyinRepair==nil && row.text.unicodeScalars.contains{$0.properties.isIdeographic} &&
                PinyinInputMatch.covers(pending,reading:row.comment,maxAbbreviations:1)
            }
            let complete=chinese.contains { row in
                row.latinInput==nil && row.pinyinRepair==nil && PinyinInputMatch.isFullSpelling(pending,reading:row.comment)
            }
            let curatedExact=MixedEnglishLexicon.words.contains{$0.lowercased()==pending.lowercased()}
            let knownEnglish=curatedExact && !complete
            mixedChinesePriority=(sentenceHasHan || supported) && !knownEnglish
            // A system provider's exact hit can be a name, abbreviation or
            // guessing artifact. Only the deliberate offline English list is
            // strong enough to lead over a weak Chinese segmentation.
            mixedLeads=knownEnglish
            let curatedContinuation=words.contains { word in
                word.lowercased().hasPrefix(pending) && MixedEnglishLexicon.words.contains{$0.lowercased()==word.lowercased()}
            }
            mixedLatinDisplayAllowed=knownEnglish || (!sentenceHasHan && !supported && curatedContinuation)
        }
        return mixedRows
    }
    private func personalCandidates() -> [InputCandidate] {
        guard !englishInput,!rawInput.isEmpty else { return [] }
        let active=Int(pi_unselected_input_start(session))
        guard active>=0,active<=rawInput.count else { return [] }
        let pending=String(rawInput.dropFirst(active))
        return personalLexicon.matches(input:pending,nineKey:nineKeyInput).enumerated().map { i,e in
            InputCandidate(text:e.text,comment:e.trigger,index:-10000-i,sourceInput:rawInput,generation:revision,personalID:e.id)
        }
    }
    @discardableResult func setSupplementaryLexicon(_ lexicon:SupplementaryLexicon) -> Bool {
        guard ready,rawInput.isEmpty else { return false }
        if supplementaryLexicon.entries != lexicon.entries { supplementaryLexicon=lexicon;reload() };return true
    }
    private func supplementaryCandidates() -> [InputCandidate] {
        guard !englishInput,!rawInput.isEmpty,pi_cursor_at_end(session) != 0 else { return [] }
        let active=Int(pi_unselected_input_start(session))
        guard active>=0,active<=rawInput.count else { return [] }
        let pending=String(rawInput.dropFirst(active))
        return supplementaryLexicon.matches(input:pending,nineKey:nineKeyInput).enumerated().map { i,e in
            InputCandidate(text:e.text,comment:"系统词库",index:-30000-i,sourceInput:rawInput,generation:revision,supplementaryTrigger:e.trigger)
        }
    }
    /// Restore before asking the platform to delete any host characters. A
    /// failed replay cannot consume or commit host text.
    @discardableResult func restoreRecentInput(_ input:String,nineKey:Bool,context:String) -> Bool {
        guard ready,!englishInput,rawInput.isEmpty,nineKeyInput==nineKey,
              !input.isEmpty,input.count<=128,input.utf8.allSatisfy({(97...122).contains($0) || (50...57).contains($0) || $0==39}) else { return false }
        markNativeLearningChanged()
        resetPredictionContext();ownContext=context
        for byte in input.utf8 {
            guard pi_process_key(session,Int32(byte),0) != 0,String(cString:pi_take_commit(session)).isEmpty else {
                pi_clear(session);resetPredictionContext();reload();return false
            }
        }
        guard !String(cString:pi_preedit(session)).isEmpty else { pi_clear(session);reload();return false }
        if let code=NineKeySpelling.rawCode(input),NineKeySpelling.isCode(code) { replacement=(code,context,Date.timeIntervalSinceReferenceDate,nil,nil) }
        reload();return true
    }
    private func nativeBatch(offset:Int,limit:Int) -> [InputCandidate] {
        let count = Int(pi_load_candidate_batch(session, offset, limit))
        let code=NineKeySpelling.rawCode(rawInput) ?? ""
        let remembered = !nineKeyInput && !privateInput ? choiceMemory.entries.filter{$0.code==code}:[]
        return (0..<count).map { i in
            let text=String(cString:pi_batch_candidate_text(session,i)),reading=String(cString:pi_batch_candidate_comment(session,i))
            return InputCandidate(text:text,comment:reading,index:Int(pi_batch_candidate_index(session,i)),generation:revision,learnedPreference:remembered.contains{$0.text==text && $0.reading==reading.replacingOccurrences(of:" ",with:"").replacingOccurrences(of:"'",with:"")})
        }
    }
    func chooseAbsolute(_ index: Int) -> String {
        guard ready, index >= 0, pi_select_candidate_absolute(session, index) != 0 else { return "" }
        markNativeLearningChanged()
        let commit = String(cString: pi_take_commit(session));observeCommit(commit);reload(); return commit
    }
    /// Learning uses only own commits. Supplied host context remains separate and ephemeral.
    private func observeCommit(_ text:String) {
        guard !text.isEmpty else{return}
        ownContext=SentenceContextWindow.append(text,to:ownContext)
        if let context=hostContext {hostContext=SurroundingText(before:context.before+text,after:context.after)}
    }
    func resetPredictionContext(preservingReplacement:Bool=false) {
        ownContext="";hostContext=nil
        if preservingReplacement,let r=replacement { replacement=(r.code,"",r.time,r.rejectedText,r.reading) } else { replacement=nil }
        revision &+= 1;invalidatePrediction()
    }
    func confirmOwnCommitContext(previous:String,text:String) { ownContext=SentenceContextWindow.append(text,to:previous) }
    func noteLiteralInput(_ text:String) { ownContext=SentenceContextWindow.append(text,to:ownContext);replacement=nil;revision &+= 1;invalidatePrediction() }
    func continuationBatch() -> [InputCandidate] {
        guard refreshResetBarrier(),preedit.isEmpty,!englishInput,!continuationSourceContext.isEmpty else { return [] }
        if continuationRevision != revision {
            continuationRevision=revision;continuationRanked=false
            continuationRows=continuationLexicon?.suggestions(context:continuationSourceContext) ?? []
            continuationCandidates=continuationRows.enumerated().map { InputCandidate(text:$0.element.text,comment:"",index:$0.offset,generation:revision,continuationContext:continuationSourceContext) }
        }
        return continuationCandidates.filter{candidateIsDisplayable($0.text)}
    }
    func rankContinuations(completion:@escaping()->Void) {
        let candidates=continuationBatch()
        guard !candidates.isEmpty,!continuationRanked,!predictionSuspended,let ranker=semanticRanker else { return }
        continuationRanked=true
        let version=revision,context=continuationSourceContext,after=modelContext.after,rows=continuationRows
        ranker.evaluate(candidates.map{.init(id:$0.text,before:context,text:$0.text,after:after)},limit:24) { [weak self] scores,metrics in
            guard let self,self.revision==version,self.preedit.isEmpty,self.continuationSourceContext==context else { return }
            let ordered=rows.sorted {
                let a=$0.score+(scores[$0.text] ?? -2)*0.8,b=$1.score+(scores[$1.text] ?? -2)*0.8
                return a==b ? $0.text<$1.text:a>b
            }
            self.continuationCandidates=ordered.enumerated().map{InputCandidate(text:$0.element.text,comment:"",index:$0.offset,generation:version,continuationContext:context)}
            self.semanticBatches=metrics.batches;self.semanticElapsedMS=metrics.elapsedMS;self.recordSemanticMetrics(metrics)
            completion()
        }
    }
    func chooseContinuation(_ candidate:InputCandidate) -> String {
        guard candidate.generation==revision,candidate.continuationContext==continuationSourceContext,!continuationSourceContext.isEmpty,preedit.isEmpty,!englishInput,
              continuationBatch().contains(where:{$0.text==candidate.text}) else { return "" }
        noteLiteralInput(candidate.text);return candidate.text
    }
    func noteFullyDeletedOwnCommit(code:String,context:String,rejectedText:String?=nil,reading:String?=nil) {
        guard preedit.isEmpty, NineKeySpelling.isCode(code) else { return }
        // Rime may roll back its still-pending recent transaction; the host has
        // already deleted the text, so this call must not cause another host delete.
        _ = key(0xff08);ownContext=context
        replacement=(code,context,Date.timeIntervalSinceReferenceDate,rejectedText,reading)
    }
    func notePartiallyDeletedOwnCommit(code:String,context:String,rejectedText:String,reading:String) {
        guard preedit.isEmpty,NineKeySpelling.isCode(code) else { return }
        ownContext=context;replacement=(code,context,Date.timeIntervalSinceReferenceDate,rejectedText,reading)
        revision &+= 1;invalidatePrediction()
    }
    private var predictionEligible:Bool {
        guard ready,!predictionSuspended,nineKeyInput,!englishInput,rawInput.count<=128 else { return false }
        let start=pi_prediction_input_start(session)
        guard start>=0 && start<=128 else { return false }
        let tail=String(rawInput.dropFirst(Int(start)))
        return NineKeySpelling.isCode(tail) && tail.count<=96
    }
    var needsNinePrediction:Bool { predictionEligible && predictionRevision != revision }
    var ninePredictionWaitingForBackground:Bool { semanticWaiting || nineSpanWorkPending }
    var hasPreparedNinePrediction:Bool { predictionComplete && predictionRevision==revision }
    func cancelNinePrediction() { if !predictionComplete { invalidatePrediction() } }
    private func wordLengths(_ text:String) -> [Int] {
        let tokenizer=NLTokenizer(unit:.word);tokenizer.string=text;tokenizer.setLanguage(.simplifiedChinese)
        var lengths:[Int]=[]
        tokenizer.enumerateTokens(in:text.startIndex..<text.endIndex) { range,_ in lengths.append(text[range].count);return true }
        return lengths
    }
    func beginNinePrediction() -> Bool {
        guard needsNinePrediction else { return false }
        let preparationStart = Date.timeIntervalSinceReferenceDate
        defer { predictionPreparationMS = (Date.timeIntervalSinceReferenceDate - preparationStart) * 1000 }
        predictionPrefixQueried = false
        ninePredictionPreparation = nil
        ninePreparationWorker.cancel();nineSpanWorkPending=false;ninePreparedSpan=nil
        predictionPreparationMS = 0
        predictionMaxProbeMS = 0
        predictionRevision=revision;predictionInput=rawInput
        predictionOffset=Int(pi_prediction_input_start(session));predictionActiveOffset=Int(pi_unselected_input_start(session))
        predictionSelectedPrefix=String(cString:pi_selected_prefix(session)).trimmingCharacters(in:.whitespaces)
        predictionContext=SentenceContextWindow.append(predictionSelectedPrefix,to:ownContext)
        predictionModelBefore=modelContext.before;predictionModelAfter=modelContext.after
        predictionStart=Date.timeIntervalSinceReferenceDate;predictionMaxSliceMS=0;predictionQueryCount=0
        predictionCacheHits=0;predictionProbeRequests=0;predictionProbeCache=[:]
        semanticWaiting=false;semanticLocalStarted=false;semanticFinalStarted=false;sentenceExplored=false;sentenceReranked=false;sentenceExploration=nil;assemblyPlans=[:];semanticScores=[:];localSemanticRows=[];localSemanticContexts=[:];lexicalRanks=[:];semanticBatches=0;semanticElapsedMS=0
        predictionOriginal=nativeBatch(offset:0,limit:32);predictionCorrections=[];predictionHead=[];predictionComplete=false
        let tail=String(predictionInput.dropFirst(predictionOffset)),prefix=String(predictionInput.prefix(predictionOffset))
        let queryPrefix=predictionSelectedPrefix.isEmpty ? prefix:String(prefix.dropFirst(predictionActiveOffset))
        predictionLearningCode=NineKeySpelling.rawCode(queryPrefix+tail) ?? tail
        let first=predictionOriginal.first
        let reading=queryPrefix.isEmpty ? (first?.comment ?? ""):""
        let spans=NineKeySentencePlanner.spans(code:tail,reading:reading,wordLengths:first.map{wordLengths($0.text)} ?? [])
        predictionQueue=NineKeySentencePlanner.alternatives(code:tail,spans:spans).map{(prefix+$0.input,$0.cost)}
        predictionTail=tail;predictionPrefix=prefix;predictionLocalBest=[];predictionLocalPrimary=[];predictionJointQueued=false;predictionLocalQueue=[];predictionLocalContexts=[:];predictionLocalScoreCache=[:]
        predictionExpansionRows=[];predictionExpansionRanked=false;languageScoreCache=[:]
        ninePredictionPreparation=NinePredictionPreparation(tail:tail,prefix:prefix,queryPrefix:queryPrefix,reading:reading,first:first,spans:spans,dictionaryWhole:Array(repeating:[],count:spans.count))
        return true
    }
    /// Prepare one word span per turn. This includes dictionary alternatives,
    /// local segmentation and lexical seeds which used to run in one timer fire.
    private func advanceNinePreparation(background:Bool) -> Bool {
        guard var work=ninePredictionPreparation else {return true}
        let started=Date.timeIntervalSinceReferenceDate
        defer {predictionPreparationMS += (Date.timeIntervalSinceReferenceDate-started)*1000}
        let tail=work.tail,prefix=work.prefix,queryPrefix=work.queryPrefix,reading=work.reading,first=work.first,spans=work.spans
        let tailChars=Array(tail)
        if work.nextSpan<spans.count {
            let i=work.nextSpan,span=spans[work.nextSpan]
            let code=String(tailChars[span.start..<span.end])
            let seeds:[(input:String,cost:Double,frequency:UInt32)],legacy:[(input:String,cost:Double)]
            if background {
                if let result=ninePreparedSpan {
                    seeds=result.seeds;legacy=result.legacy;ninePreparedSpan=nil
                } else {
                    if !nineSpanWorkPending {
                        nineSpanWorkPending=true
                        let expected=predictionRevision
                        ninePreparationWorker.evaluate(code:code,lexicon:nineLexicon,limit:tail.count<=12 ? 12:8,local:spans.count>=2) { [weak self] result in
                            guard let self,self.predictionRevision==expected,self.revision==expected else{return}
                            self.nineSpanWorkPending=false;self.ninePreparedSpan=result
                        }
                    }
                    return false
                }
            } else {
                seeds=nineLexicon?.alternatives(code,limit:tail.count<=12 ? 12:8) ?? []
                legacy=spans.count>=2 ? NineKeySpelling.alternatives(code,limit:64):[]
            }
            for (rank,seed) in seeds.enumerated() {
                lexicalRanks["\(span.start):\(span.end):"+seed.input]=rank
                work.dictionaryWhole[i].append((prefix+String(tailChars[..<span.start])+seed.input+String(tailChars[span.end...]),seed.cost))
            }
            if let first {
                if let context=NineKeySentencePlanner.neighbors(code:tail,reading:reading,text:first.text,span:span,window:24) {localSemanticContexts["\(span.start):\(span.end)"]=context}
                if let context=NineKeySentencePlanner.neighbors(code:tail,reading:reading,text:first.text,span:span) {predictionLocalContexts["\(span.start):\(span.end)"]=context}
            }
            if spans.count>=2 {
                var seen=Set<String>()
                let candidates=Array(legacy.prefix(16))+seeds.prefix(8).map{(input:$0.input,cost:$0.cost)}+Array(legacy.dropFirst(16))
                work.local.append(Array(candidates.filter{seen.insert($0.input).inserted}.prefix(64)).map{(span,$0.input,$0.cost)})
            }
            work.nextSpan+=1;ninePredictionPreparation=work
            return false
        }
        let dictionaryWhole=work.dictionaryWhole
        var seenWhole=Set<String>()
        predictionQueue=(dictionaryWhole.flatMap{Array($0.prefix(2))}+predictionQueue).filter{seenWhole.insert($0.input).inserted}
        if !privateInput,let prefixCode=NineKeySpelling.rawCode(queryPrefix) ?? (queryPrefix.isEmpty ? "":nil) {
            for e in choiceMemory.entries where e.code==predictionLearningCode && choiceMemory.boost(code:e.code,reading:e.reading,text:e.text,context:predictionContext)>0 {
                if let code=NineKeySpelling.encode(e.reading),code.hasPrefix(prefixCode),code != predictionLearningCode {
                    let next=prefix+code.dropFirst(prefixCode.count)
                    if !predictionQueue.contains(where:{$0.input==next}) { predictionQueue.insert((String(next),NineKeySpelling.jointEditCost(e.code,code) ?? 3),at:0) }
                }
            }
        }
        predictionQueue=Array(predictionQueue.prefix(tail.count<=12 ? 32:48))
        if tail.count<=12 {
            for row in dictionaryWhole { for item in row.dropFirst(8) where predictionQueue.count<36 && !predictionQueue.contains(where:{$0.input==item.input}) { predictionQueue.append(item) } }
        }
        // Additional hits have their own final phase. They cannot displace
        // existing beam queries, neural requests, or already recalled words.
        let prior=Set(predictionQueue.map(\.input))
        predictionExpansionQueue = tail.count<=12 && expandedShortRecall ? Array(NineKeySentencePlanner.recallQueries(legacy:[],dictionary:dictionaryWhole).filter{!prior.contains($0.input)}.prefix(12)):[]
        if tail.count>12,expandedSentenceRecall {
            let boundary=NineKeySentencePlanner.boundaryAlternatives(code:tail,spans:spans).map{(input:prefix+$0.input,cost:$0.cost)}
            // Long sentences used only the first two whole-sentence dictionary
            // probes per span. Reserve a final opportunity for the remaining
            // dictionary-verified missing/extra/neighbor hypotheses as well.
            let dictionary=NineKeySentencePlanner.recallQueries(legacy:[],dictionary:dictionaryWhole,limit:64)
            var seen=prior
            predictionExpansionQueue=Array((boundary.filter{$0.cost==1.2}+dictionary+boundary.filter{$0.cost != 1.2}).filter{seen.insert($0.input).inserted}.prefix(16))
        }
        if spans.count>=2 {
            for index in 0..<64 { for q in work.local where index<q.count { if predictionLocalQueue.count<128 {predictionLocalQueue.append((q[index].0,q[index].1,q[index].2,index<16))} } }
        }
        ninePredictionPreparation=nil
        if predictionProbe==0 {
            predictionProbe=pi_create_session()
            guard predictionProbe != 0,pi_set_private(predictionProbe,1) != 0,pi_set_nine_key(predictionProbe,1) != 0 else { releasePredictionProbe();invalidatePrediction();return false }
        } else {pi_clear(predictionProbe)}
        return true
    }
    private func querySelectedPredictionPrefix() throws {
        // A selected prefix remains evidence for decoding the rest of the
        // sentence. Keep only full-query hypotheses agreeing with that prefix.
        if !predictionSelectedPrefix.isEmpty,predictionOffset==predictionActiveOffset {
            let selectedCount=predictionSelectedPrefix.count
            for full in try probeNine(predictionInput) where full.text.hasPrefix(predictionSelectedPrefix) && full.text.count>selectedCount {
                let parts=readingParts(full.comment)
                guard parts.count==full.text.count else { continue }
                let remaining=Array(parts.dropFirst(selectedCount)),text=String(full.text.dropFirst(selectedCount))
                guard NineKeySpelling.encode(remaining.joined())==predictionLearningCode,!predictionOriginal.contains(where:{$0.text==text}) else { continue }
                let id=assemblyPlans.count;assemblyPlans[id] = .init(input:predictionInput,text:text,readings:remaining)
                let item=InputCandidate(text:text,comment:remaining.joined(separator:" "),index:0,replacementInput:predictionInput,sourceInput:predictionInput,assemblyID:id)
                predictionCorrections.append((item,predictionScore(item,position:0)+0.5));break
            }
        }
        predictionPrefixQueried = true
    }
    /// A native query cannot be preempted. Mobile therefore caps queries per
    /// turn as well as elapsed time, and yields between planning phases. The
    /// complete queue stays intact; this changes scheduling, never recall.
    func advanceNinePrediction(timeBudget:TimeInterval=0.008, maxQueriesPerSlice:Int=Int.max) -> Bool {
        guard predictionRevision==revision,!predictionComplete else { return true }
        if semanticWaiting { return false }
        let start=Date.timeIntervalSinceReferenceDate
        predictionSliceQueriesRemaining=max(1,maxQueriesPerSlice)
        defer {
            predictionSliceQueriesRemaining=Int.max
            predictionMaxSliceMS=max(predictionMaxSliceMS,(Date.timeIntervalSinceReferenceDate-start)*1000)
        }
        do { return try advanceNinePredictionSlice(timeBudget:timeBudget,start:start,yieldBetweenPhases:maxQueriesPerSlice != Int.max) }
        catch { return false } // Only an internal cooperative yield is thrown.
    }
    private func advanceNinePredictionSlice(timeBudget:TimeInterval,start:TimeInterval,yieldBetweenPhases:Bool) throws -> Bool {
        if ninePredictionPreparation != nil {
            let ready=advanceNinePreparation(background:yieldBetweenPhases)
            if !ready || yieldBetweenPhases {return false}
        }
        if !predictionPrefixQueried {
            try querySelectedPredictionPrefix()
            if yieldBetweenPhases { return false }
        }
        repeat {
            if predictionQueue.isEmpty,!predictionLocalQueue.isEmpty {
                let local=predictionLocalQueue[0]
                let values=try probeNine(local.input)
                predictionLocalQueue.removeFirst()
                if let best=values.map({ item in localPredictionScore(item,span:local.span) }).filter(\.isFinite).max() {
                    let prior=min(1.5,log1p(Double(nineLexicon?.frequency(local.input) ?? 0))/8)
                    let h=NineKeyLocalHypothesis(span:local.span,input:local.input,cost:local.cost,score:best-3*local.cost+prior)
                    let spanKey="\(local.span.start):\(local.span.end)",key=spanKey+":"+local.input
                    if let context=localSemanticContexts[spanKey] {
                        var seen=Set<String>()
                        let chosen=(Array(values.prefix(1))+values.sorted{localPredictionScore($0,span:local.span)>localPredictionScore($1,span:local.span)}).filter{seen.insert($0.text).inserted}.prefix(2)
                        for (i,item) in chosen.enumerated() {
                            let request=SemanticRanker.Request(id:key+":"+item.text,before:predictionModelBefore+context.before,text:item.text,after:context.after+predictionModelAfter)
                            localSemanticRows.append(.init(request:request,key:key,base:localPredictionScore(item,span:local.span)-3*local.cost+prior,priority:(lexicalRanks[key] ?? 12)*2+i))
                        }
                    }
                    predictionLocalBest.append(h);if local.primary { predictionLocalPrimary.append(.init(span:local.span,input:local.input,cost:local.cost,score:best-3*local.cost)) }
                }
                continue
            }
            if predictionQueue.isEmpty,!semanticLocalStarted {
                semanticLocalStarted=true
                if startLocalSemanticRanking() || yieldBetweenPhases { return false }
            }
            if predictionQueue.isEmpty,!predictionJointQueued {
                predictionJointQueued=true
                let primary=NineKeySentencePlanner.jointAlternatives(code:predictionTail,hypotheses:predictionLocalPrimary)
                let expanded=NineKeySentencePlanner.jointAlternatives(code:predictionTail,hypotheses:predictionLocalBest,limit:semanticBatches>0 ? 24:32)
                var seen=Set<String>()
                predictionQueue=(primary+expanded).filter{seen.insert($0.input).inserted}.map{(predictionPrefix+$0.input,$0.cost)}
                if yieldBetweenPhases { return false }
            }
            guard !predictionQueue.isEmpty else { break }
            let variant=predictionQueue[0]
            let query=predictionSelectedPrefix.isEmpty ? variant.input:String(variant.input.dropFirst(predictionActiveOffset))
            let values=try probeNine(query)
            predictionQueue.removeFirst()
            for item in values {
                if predictionOriginal.contains(where:{$0.text==item.text}) { continue }
                var candidate=item;candidate.replacementInput=variant.input;candidate.sourceInput=predictionInput
                let score=predictionScore(candidate,position:item.index)-3*variant.cost
                if let i=predictionCorrections.firstIndex(where:{$0.candidate.text==item.text && $0.candidate.comment==item.comment}) {
                    if score>predictionCorrections[i].score { predictionCorrections[i]=(candidate,score) }
                } else { predictionCorrections.append((candidate,score)) }
            }
        } while Date.timeIntervalSinceReferenceDate-start < timeBudget
        predictionMaxSliceMS=max(predictionMaxSliceMS,(Date.timeIntervalSinceReferenceDate-start)*1000)
        guard predictionQueue.isEmpty,predictionLocalQueue.isEmpty,predictionJointQueued else { return false }
        if !semanticFinalStarted {
            semanticFinalStarted=true
            if startFinalSemanticRanking() || yieldBetweenPhases { return false }
        }
        if !sentenceExplored {
            let waiting = try startSentenceExploration()
            sentenceExplored=true
            if waiting || yieldBetweenPhases { return false }
        }
        if !sentenceReranked {
            sentenceReranked=true
            if !assemblyPlans.isEmpty,startFinalSemanticRanking(assembliesFirst:true) { return false }
            if yieldBetweenPhases { return false }
        }
        if predictionProtectedExtras==nil {
            predictionProtectedExtras=Array(predictionCorrections.filter{$0.candidate.assemblyID==nil || semanticScores[$0.candidate.text] != nil}.map{(candidate:$0.candidate,score:$0.score+semanticAdjustment($0.candidate))}.sorted{$0.score>$1.score}.prefix(24))
        }
        if !predictionExpansionQueue.isEmpty {
            let slice=Date.timeIntervalSinceReferenceDate
            repeat {
                if predictionQueryCount>=240 { predictionExpansionQueue=[];break }
                let variant=predictionExpansionQueue[0]
                let query=predictionSelectedPrefix.isEmpty ? variant.input:String(variant.input.dropFirst(predictionActiveOffset))
                let values=try probeNine(query)
                predictionExpansionQueue.removeFirst()
                for item in values where !predictionOriginal.contains(where:{$0.text==item.text}) {
                    var candidate=item;candidate.replacementInput=variant.input;candidate.sourceInput=predictionInput
                    let score=predictionScore(candidate,position:item.index)-3*variant.cost
                    if let i=predictionExpansionRows.firstIndex(where:{$0.candidate.text==item.text}) {
                        if score>predictionExpansionRows[i].score { predictionExpansionRows[i]=(candidate,score) }
                    } else { predictionExpansionRows.append((candidate,score)) }
                }
            } while !predictionExpansionQueue.isEmpty && Date.timeIntervalSinceReferenceDate-slice<timeBudget
            predictionMaxSliceMS=max(predictionMaxSliceMS,(Date.timeIntervalSinceReferenceDate-slice)*1000)
            if !predictionExpansionQueue.isEmpty { return false }
        }
        if !predictionExpansionRanked {
            predictionExpansionRanked=true
            if startExpansionRanking() || yieldBetweenPhases { return false }
        }
        // Retain more corrected readings for ambiguous nine-key omissions.
        // The normal head and lazy tail remain intact; UI scrolling is unchanged.
        var extras=predictionProtectedExtras ?? []
        let known=Set(extras.map{$0.candidate.text})
        extras += predictionExpansionRows.filter{!known.contains($0.candidate.text)}.map{(candidate:$0.candidate,score:$0.score+semanticAdjustment($0.candidate))}.sorted{$0.score>$1.score}.prefix(12)
        var scored=predictionOriginal.enumerated().map { (candidate:$0.element,score:predictionScore($0.element,position:$0.offset)+1+semanticAdjustment($0.element)) }
        scored += extras
        let priorities=scored.map{matchPriority($0.candidate)}
        let learned=scored.map { row in privateInput ? 0:choiceMemory.boost(code:predictionLearningCode,reading:row.candidate.comment,text:row.candidate.text,context:predictionContext) }
        let ordered=scored.enumerated().sorted {
            let a=priorities[$0.offset],b=priorities[$1.offset]
            if a != b { return a<b }
            // Rime already supplies the word-frequency order for a short,
            // correctly spelled word. Fragment discriminator scores must not
            // turn that word into a longer phrase requiring untyped keys.
            if predictionLearningCode.count<=12,a==1 {
                let learnedX=learned[$0.offset],learnedY=learned[$1.offset]
                if learnedX != learnedY { return learnedX>learnedY }
                return $0.offset<$1.offset
            }
            if $0.element.score == $1.element.score { return $0.offset<$1.offset }
            return $0.element.score>$1.element.score
        }
        predictionHead=ordered.map(\.element.candidate)
        for i in predictionHead.indices where predictionHead[i].replacementInput != nil { predictionHead[i] = InputCandidate(text:predictionHead[i].text,comment:predictionHead[i].comment,index:-i-1,replacementInput:predictionHead[i].replacementInput,sourceInput:predictionInput,assemblyID:predictionHead[i].assemblyID,generation:predictionRevision) }
        predictionMaxSliceMS=max(predictionMaxSliceMS,(Date.timeIntervalSinceReferenceDate-start)*1000)
        predictionElapsedMS=(Date.timeIntervalSinceReferenceDate-predictionStart)*1000
        predictionFootprintMB=Double(pi_process_memory_footprint())/1048576
        if retainPredictionProbe,personalEpoch==Self.initializedEpoch,predictionProbe != 0 {pi_clear(predictionProbe)}
        else {releasePredictionProbe()}
        predictionProbeCache=[:]
        predictionComplete=true;return true
    }
    private func fullySpelled(_ reading:String) -> Bool {
        let tokens=readingParts(reading)
        guard !tokens.isEmpty else { return false }
        return tokens.allSatisfy { word in
            if !completeSyllables.isEmpty { return completeSyllables.contains(word) }
            // Resource absence keeps basic input available. This fallback is
            // deliberately narrower than accepting every single initial.
            return ["m","n","ng"].contains(word) || word.contains(where:{"aeiouv".contains($0)})
        }
    }
    private func matchPriority(_ candidate:InputCandidate) -> Int {
        if isPinned(candidate) { return 0 }
        guard fullySpelled(candidate.comment),let target=NineKeySpelling.encode(candidate.comment) else { return 5 }
        let source=predictionLearningCode
        if target==source { return 1 }
        if candidate.replacementInput==nil,target.hasPrefix(source) { return 1 }
        if candidate.replacementInput != nil {
            // A normally resolved leading syllable is evidence. Keep edits
            // elsewhere, but demote guesses splitting you into wo + bu.
            if let first=predictionOriginal.first(where:{fullySpelled($0.comment)}),
               let syllable=readingParts(first.comment).first,let leading=NineKeySpelling.encode(syllable),source.hasPrefix(leading),
               !target.hasPrefix(leading) { return 4 }
            return 2
        }
        if source.hasPrefix(target) { return 3 }
        return 5
    }
    private func recordSemanticMetrics(_ metrics:SemanticRanker.Metrics) {
        semanticLastMetrics=metrics;semanticMetricsRevision=revision
        #if PRIVATE_INPUT_DEVELOPMENT_DIAGNOSTICS
        // Numeric resource counters only. No words, codes, context or host IDs.
        if let cache=FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask).first {
            try? FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true)
            let record:[String:Any]=["build":Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "test","model":"electra-small-int8","batches":semanticBatches,"elapsedMS":semanticElapsedMS,"available":metrics.available,"footprintMB":metrics.footprintMB,"peakMB":metrics.peakMB,"headroomMB":metrics.headroomMB,"memoryLimited":metrics.memoryLimited]
            if let data=try? JSONSerialization.data(withJSONObject:record,options:[.sortedKeys]) { try? data.write(to:cache.appendingPathComponent("PrivateInput-semantic-metrics.json"),options:.atomic) }
        }
        #endif
    }
    private func startExpansionRanking() -> Bool {
        guard let ranker=semanticRanker,ranker.configured else { return false }
        let rows=predictionExpansionRows.sorted{$0.score>$1.score}.filter{$0.candidate.text.count>=2 && semanticScores[$0.candidate.text]==nil}.prefix(12)
        let requests=rows.map{SemanticRanker.Request(id:$0.candidate.text,before:predictionModelBefore,text:$0.candidate.text,after:predictionModelAfter)}
        guard !requests.isEmpty else { return false }
        let expected=revision;semanticWaiting=true
        ranker.evaluate(requests,limit:12) { [weak self] scores,metrics in
            guard let self,self.revision==expected,self.predictionRevision==expected else { return }
            self.semanticScores.merge(scores,uniquingKeysWith:{old,_ in old});self.semanticBatches+=metrics.batches;self.semanticElapsedMS+=metrics.elapsedMS;self.recordSemanticMetrics(metrics);self.semanticWaiting=false
        }
        return true
    }
    private func semanticAdjustment(_ candidate:InputCandidate) -> Double {
        guard let score=semanticScores[candidate.text] else { return 0 }
        let preference=privateInput ? 0:choiceMemory.boost(code:predictionLearningCode,reading:candidate.comment,text:candidate.text,context:predictionContext)
        return max(-10,20*score)/(1+preference/2)
    }
    private func startLocalSemanticRanking() -> Bool {
        guard let ranker=semanticRanker,ranker.configured,!localSemanticRows.isEmpty else { return false }
        let rows=Array(localSemanticRows.enumerated().sorted{$0.element.priority==$1.element.priority ? $0.offset<$1.offset:$0.element.priority<$1.element.priority}.prefix(32).map(\.element))
        let expected=revision;semanticWaiting=true
        ranker.evaluate(rows.map(\.request)) { [weak self] scores,metrics in
            guard let self,self.revision==expected,self.predictionRevision==expected else { return }
            self.semanticBatches+=metrics.batches;self.semanticElapsedMS+=metrics.elapsedMS;self.recordSemanticMetrics(metrics)
            var values:[String:Double]=[:]
            for row in rows { if let score=scores[row.request.id] { values[row.key]=max(values[row.key] ?? -.infinity,row.base+max(-10,20*score)) } }
            func updated(_ h:NineKeyLocalHypothesis) -> NineKeyLocalHypothesis {
                let key="\(h.span.start):\(h.span.end):"+h.input
                return .init(span:h.span,input:h.input,cost:h.cost,score:values[key] ?? h.score)
            }
            self.predictionLocalBest=self.predictionLocalBest.map(updated) // Keep the legacy beam independent of neural pruning.
            self.semanticWaiting=false
        }
        return true
    }
    private func startFinalSemanticRanking(assembliesFirst:Bool=false) -> Bool {
        guard let ranker=semanticRanker,ranker.configured else { return false }
        let originals=predictionOriginal.enumerated().map{(candidate:$0.element,score:predictionScore($0.element,position:$0.offset)+1)}
        let ranked=(originals+predictionCorrections).sorted {
            if assembliesFirst,($0.candidate.assemblyID != nil) != ($1.candidate.assemblyID != nil) { return $0.candidate.assemblyID != nil }
            return $0.score>$1.score
        }
        let candidates=assembliesFirst ? ranked:originals+ranked
        var requests:[SemanticRanker.Request]=[],seen=Set<String>()
        for value in candidates {
            let item=value.candidate,input=item.replacementInput ?? predictionInput
            let query=predictionSelectedPrefix.isEmpty ? input:String(input.dropFirst(predictionActiveOffset))
            guard item.text.count>=2,NineKeySpelling.encode(item.comment)==NineKeySpelling.rawCode(query),seen.insert(item.text).inserted else { continue }
            requests.append(.init(id:item.text,before:predictionModelBefore,text:item.text,after:predictionModelAfter,includeTokenScores:!assembliesFirst))
            if requests.count==(assembliesFirst ? 64:32) { break }
        }
        guard !requests.isEmpty else { return false }
        let expected=revision;semanticWaiting=true
        ranker.evaluate(requests,limit:assembliesFirst ? 64:32) { [weak self] scores,metrics in
            guard let self,self.revision==expected,self.predictionRevision==expected else { return }
            self.semanticScores.merge(scores,uniquingKeysWith:{_,new in new});self.semanticBatches+=metrics.batches;self.semanticElapsedMS+=metrics.elapsedMS;self.recordSemanticMetrics(metrics);self.semanticWaiting=false
        }
        return true
    }
    private func readingParts(_ text:String) -> [String] { text.replacingOccurrences(of:"'",with:" ").split(separator:" ").map{PinyinInputMatch.canonicalSyllable(String($0))} }
    private func startSentenceExploration() throws -> Bool {
        guard let ranker=semanticRanker,ranker.configured,semanticBatches>0,predictionOffset==predictionActiveOffset else { return false }
        if sentenceExploration==nil {
            let originals=predictionOriginal.enumerated().map{(candidate:$0.element,score:predictionScore($0.element,position:$0.offset)+1)}
        let sorted=(originals+predictionCorrections).sorted{$0.score+semanticAdjustment($0.candidate)>$1.score+semanticAdjustment($1.candidate)}
        let preferred=sorted.filter{($0.candidate.replacementInput ?? predictionInput)==predictionInput}+sorted
        var drafts:[AssemblyPlan]=[],seen=Set<String>()
        for value in preferred {
            let item=value.candidate,input=item.replacementInput ?? predictionInput
            let query=predictionSelectedPrefix.isEmpty ? input:String(input.dropFirst(predictionActiveOffset))
            let parts=readingParts(item.comment)
            guard (3...32).contains(item.text.count),parts.count==item.text.count,item.text.unicodeScalars.allSatisfy({(0x3400...0x9fff).contains($0.value)}),semanticScores[item.text] != nil,
                  NineKeySpelling.encode(item.comment)==NineKeySpelling.rawCode(query),seen.insert(input).inserted else { continue }
            drafts.append(.init(input:input,text:item.text,readings:parts));if drafts.count==3 { break }
        }
            var units:[[ExplorationUnit]]=[],probes:[ExplorationProbe]=[]
            for (d,draft) in drafts.enumerated() {
                let chars=Array(draft.text).map(String.init),lengths=wordLengths(draft.text)
                let aligned=lengths.reduce(0,+)==chars.count ? lengths:Array(repeating:1,count:chars.count)
                var group:[ExplorationUnit]=[],offset=0
                for length in aligned {
                    var left=length
                    while left>0 {
                        let n=min(4,left),range=offset..<offset+n
                        let confidence=range.map{semanticScores[draft.text+"#\($0)"] ?? 0}.reduce(0,+)/Double(n)
                        group.append(.init(text:chars[range].joined(),readings:Array(draft.readings[range]),score:confidence))
                        offset+=n;left-=n
                    }
                }
                units.append(group)
                let positions=group.indices.sorted{group[$0].score==group[$1].score ? $0<$1:group[$0].score<group[$1].score}.prefix(d==0 ? 4:2)
                for position in positions {
                    if let code=NineKeySpelling.encode(group[position].readings.joined()) {
                        probes.append(.init(draft:d,position:position,code:code))
                    }
                }
            }
            sentenceExploration=SentenceExploration(drafts:drafts,units:units,probes:probes)
        }
        guard var work=sentenceExploration else {return false}
        while work.cursor<work.probes.count {
            let probe=work.probes[work.cursor],group=work.units[work.probes[work.cursor].draft]
            if predictionProbeRequests<240 {
                let words=try probeNine(probe.code,limit:64).filter{(1...4).contains($0.text.count) && readingParts($0.comment).count==$0.text.count && $0.text != group[probe.position].text}.prefix(8)
                for word in words {
                    let id="assembly:\(probe.draft):\(probe.position):"+word.text
                    work.alternatives.append(.init(id:id,draft:probe.draft,position:probe.position,text:word.text,readings:readingParts(word.comment)))
                    work.requests.append(.init(id:id,before:predictionModelBefore+group.prefix(probe.position).map(\.text).joined(),text:word.text,after:group.dropFirst(probe.position+1).map(\.text).joined()+predictionModelAfter))
                }
            }
            work.cursor+=1
            sentenceExploration=work
        }
        let drafts=work.drafts,units=work.units,alternatives=work.alternatives,requests=work.requests
        sentenceExploration=nil
        guard !requests.isEmpty else { return false }
        let expected=revision;semanticWaiting=true
        ranker.evaluate(requests,limit:64) { [weak self] scores,metrics in
            guard let self,self.revision==expected,self.predictionRevision==expected else { return }
            self.semanticBatches+=metrics.batches;self.semanticElapsedMS+=metrics.elapsedMS;self.recordSemanticMetrics(metrics)
            struct Beam { var words:[String],readings:[[String]];var delta:Double;var changes:Int }
            for (d,draft) in drafts.enumerated() {
                var beam=[Beam(words:units[d].map(\.text),readings:units[d].map(\.readings),delta:0,changes:0)]
                let positions=Set(alternatives.filter{$0.draft==d && scores[$0.id] != nil}.map(\.position)).sorted()
                for position in positions {
                    let choices=alternatives.filter{$0.draft==d && $0.position==position && scores[$0.id] != nil}.sorted{scores[$0.id]!>scores[$1.id]!}.prefix(4)
                    var next=beam
                    for state in beam { for choice in choices {
                        var changed=state;changed.words[position]=choice.text;changed.readings[position]=choice.readings
                        changed.delta += scores[choice.id]!-units[d][position].score;changed.changes+=1;next.append(changed)
                    } }
                    // Preserve different numbers of word replacements. Several mutually
                    // supporting errors can make every single replacement look
                    // weak even when their complete combination is fluent.
                    let ranked=next.sorted{$0.delta==$1.delta ? $0.changes<$1.changes:$0.delta>$1.delta}
                    var counts:[Int:Int]=[:];beam=[]
                    for state in ranked where (counts[state.changes] ?? 0)<4 {
                        beam.append(state);counts[state.changes,default:0]+=1
                    }
                }
                for state in beam.filter({$0.changes>0}).prefix(16) {
                    let text=state.words.joined(),parts=state.readings.flatMap{$0},reading=parts.joined(separator:" ")
                    guard !self.predictionOriginal.contains(where:{$0.text==text}),!self.predictionCorrections.contains(where:{$0.candidate.text==text}),
                          let target=NineKeySpelling.encode(reading),let cost=NineKeySpelling.jointEditCost(self.predictionLearningCode,target) else { continue }
                    let id=self.assemblyPlans.count
                    self.assemblyPlans[id] = .init(input:draft.input,text:text,readings:parts)
                    let item=InputCandidate(text:text,comment:reading,index:0,replacementInput:draft.input,sourceInput:self.predictionInput,assemblyID:id)
                    self.predictionCorrections.append((item,self.predictionScore(item,position:0)-3*cost-0.3*Double(state.changes)))
                }
            }
            self.semanticWaiting=false
        }
        return true
    }
    /// Explicit user selection is replayed in a fresh Rime session. A failed
    /// replay never clears the visible draft or inserts a partial host string.
    private func stageAssembly(_ plan:AssemblyPlan,nineKey:Bool=true) -> PI_Session? {
        let staged=pi_create_session();guard staged != 0 else { return nil };var adopted=false;defer { if !adopted { pi_destroy_session(staged) } }
        guard pi_set_nine_key(staged,nineKey ? 1:0) != 0,pi_set_private(staged,privateInput ? 1:0) != 0,pi_set_ascii_mode(staged,0) != 0 else{return nil}
        let canonical=plan.readings.joined(separator:"'")
        guard (nineKey ? pi_stage_nine_input(staged,canonical):pi_stage_pinyin_input(staged,canonical)) != 0 else{return nil}
        var remaining=plan.text,readings=plan.readings
        // Every accepted word consumes at least one reading. Bound replay by
        // the supported reading count, rather than truncating long selections
        // after 32 short dictionary words.
        for _ in 0..<min(128,plan.readings.count) {
            var best:InputCandidate?
            for offset in stride(from:0,to:256,by:32) {
                let count=Int(pi_load_candidate_batch(staged,offset,32))
                for i in 0..<count {
                    let text=String(cString:pi_batch_candidate_text(staged,i)),comment=String(cString:pi_batch_candidate_comment(staged,i)),parts=readingParts(comment)
                    if !text.isEmpty,remaining.hasPrefix(text),parts.count==text.count,Array(readings.prefix(parts.count))==parts,
                       text.count>(best?.text.count ?? 0) { best=InputCandidate(text:text,comment:comment,index:Int(pi_batch_candidate_index(staged,i))) }
                }
                if best?.text==remaining || count<32 { break }
            }
            guard let best,pi_select_candidate_absolute(staged,best.index) != 0 else { return nil }
            remaining=String(remaining.dropFirst(best.text.count));readings.removeFirst(best.text.count)
            let commit=String(cString:pi_take_commit(staged))
            if remaining.isEmpty { guard commit==plan.text else { return nil };adopted=true;return staged }
            if !commit.isEmpty { return nil }
        }
        return nil
    }
    private func localPredictionScore(_ candidate:InputCandidate,span:NineKeySpan) -> Double {
        let key="\(span.start):\(span.end)",cacheKey=key+":"+candidate.text
        if let value=predictionLocalScoreCache[cacheKey] { return value-Double(candidate.index)*0.16 }
        let context=predictionLocalContexts[key]
        let before=context?.before ?? "",after=context?.after ?? ""
        var score=pi_language_score(before.isEmpty ? SentenceContextWindow.scoringContext(predictionModelBefore).text:before,candidate.text)
        if !after.isEmpty {
            let right=pi_language_score(candidate.text,after)
            if right.isFinite { score=score.isFinite ? score*0.4+right*0.6:right }
        }
        if !score.isFinite { score = -12 } // No usable neighbors: conservative search fallback.
        predictionLocalScoreCache[cacheKey]=score
        return score-Double(candidate.index)*0.16
    }
    private func probeNine(_ input:String,limit:Int=12) throws -> [InputCandidate] {
        let probe=predictionProbe;guard probe != 0 else { return [] }
        let key="\(limit)|"+input
        if cachePredictionQueries,let cached=predictionProbeCache[key] { predictionProbeRequests+=1;predictionCacheHits+=1;return cached }
        guard predictionSliceQueriesRemaining>0 else { throw PredictionYield.nextRunLoop }
        predictionSliceQueriesRemaining-=1
        predictionProbeRequests+=1;predictionQueryCount+=1
        let probeStart=Date.timeIntervalSinceReferenceDate
        defer { predictionMaxProbeMS=max(predictionMaxProbeMS,(Date.timeIntervalSinceReferenceDate-probeStart)*1000) }
        guard pi_set_prediction_input(probe,input) != 0 else { return [] }
        let count=Int(pi_load_candidate_batch(probe,0,limit))
        let result:[InputCandidate]=(0..<count).compactMap { index in
            let reading=String(cString:pi_batch_candidate_comment(probe,index))
            guard NineKeySpelling.encode(reading)==NineKeySpelling.rawCode(input) else { return nil }
            return InputCandidate(text:String(cString:pi_batch_candidate_text(probe,index)),comment:reading,index:Int(pi_batch_candidate_index(probe,index)))
        }
        // Per-generation probe sessions are private and their input setter
        // resets conversion state. Reuse only identical input AND batch limit;
        // local context scores are still computed independently by each span.
        if cachePredictionQueries,predictionProbeCache.count<240 { predictionProbeCache[key]=result }
        return result
    }
    private func predictionScore(_ candidate:InputCandidate,position:Int) -> Double {
        if isPinned(candidate) { return 10000-Double(position)*0.001 }
        let input=candidate.replacementInput ?? predictionInput
        let query=predictionSelectedPrefix.isEmpty ? input:String(input.dropFirst(predictionActiveOffset))
        let complete=NineKeySpelling.encode(candidate.comment)==NineKeySpelling.rawCode(query)
        var score = -12.0-Double(position)*0.16
        if complete && languageModelReady {
            let context=SentenceContextWindow.scoringContext(predictionModelBefore)
            let value=languageScoreCache[candidate.text] ?? pi_language_score(context.text,candidate.text)
            languageScoreCache[candidate.text]=value
            if value.isFinite {
                let base=context.weight<1 ? pi_language_score("",candidate.text):value
                score=base+(value-base)*context.weight-Double(position)*0.16
            }
        }
        if !privateInput { score += choiceMemory.boost(code:predictionLearningCode,reading:candidate.comment,text:candidate.text,context:predictionContext) }
        return score
    }
    func chooseCandidate(_ candidate:InputCandidate) -> String {
        guard refreshResetBarrier(),candidateIsDisplayable(candidate.text) else{return ""}
        markNativeLearningChanged()
        if let generation=candidate.generation,generation != revision { return "" }
        if let code=candidate.initialsInput {
            guard candidate.sourceInput==rawInput,
                  (initialsCandidates()+ninePrefixCompletions()).contains(where:{$0.text==candidate.text && $0.comment==candidate.comment && $0.initialsInput==code}) else{return ""}
            let original=rawInput
            var active=Int(pi_unselected_input_start(session))
            if active<0,!nineKeyInput,String(cString:pi_selected_prefix(session)).isEmpty {active=0}
            guard active>=0,active<=original.count else{return ""}
            let tail=String(original.dropFirst(active))
            guard tail.hasPrefix(code),let staged=stageAssembly(.init(input:code,text:candidate.text,readings:readingParts(candidate.comment)),nineKey:nineKeyInput) else{return ""}
            let suffix=String(tail.dropFirst(code.count))
            for key in suffix.utf8 {_ = pi_process_key(staged,Int32(key),0)}
            guard String(cString:pi_raw_input(staged))==suffix,rawInput==original else{pi_destroy_session(staged);return ""}
            let selected=String(cString:pi_selected_prefix(session)).trimmingCharacters(in:.whitespaces)
            let old=session;session=staged;pi_destroy_session(old)
            // Canonical full spelling is learned by Rime; do not treat a valid
            // initial abbreviation as a typo or train a false full-code mapping.
            let commit=selected+candidate.text;observeCommit(commit);reload();return commit
        }
        if let spelling=candidate.pinyinRepair {
            guard !nineKeyInput,!englishInput,candidate.sourceInput==rawInput,
                  pinyinRepairCandidates().contains(where:{$0.text==candidate.text && $0.comment==candidate.comment && $0.pinyinRepair==spelling && $0.pinyinRemainder==candidate.pinyinRemainder}) else {return ""}
            let original=rawInput,selected=String(cString:pi_selected_prefix(session)).trimmingCharacters(in:.whitespaces)
            let staged=pi_create_session();guard staged != 0 else {return ""}
            var adopted=false;defer {if !adopted {pi_destroy_session(staged)}}
            guard pi_set_private(staged,privateInput ? 1:0) != 0,pi_set_nine_key(staged,0) != 0,pi_set_ascii_mode(staged,0) != 0,
                  pi_stage_pinyin_input(staged,spelling) != 0 else {return ""}
            var found:Int?
            for offset in stride(from:0,to:64,by:16) {
                let count=Int(pi_load_candidate_batch(staged,offset,16))
                for i in 0..<count where String(cString:pi_batch_candidate_text(staged,i))==candidate.text && readingParts(String(cString:pi_batch_candidate_comment(staged,i))).joined()==spelling {found=Int(pi_batch_candidate_index(staged,i));break}
                if found != nil || count<16 {break}
            }
            guard let found,pi_select_candidate_absolute(staged,found) != 0,
                  String(cString:pi_take_commit(staged))==candidate.text,String(cString:pi_raw_input(staged)).isEmpty,rawInput==original else {return ""}
            if let remainder=candidate.pinyinRemainder {
                for key in remainder.utf8 {_ = pi_process_key(staged,Int32(key),0)}
                guard String(cString:pi_raw_input(staged))==remainder else {return ""}
            }
            let active=Int(pi_unselected_input_start(session))
            let source=selected.isEmpty ? original:(active>=0 && active<=original.count ? String(original.dropFirst(active)):"")
            let code=NineKeySpelling.encode(candidate.pinyinRemainder==nil ? source:spelling) ?? ""
            rememberChoice(code:code,candidate:candidate,context:SentenceContextWindow.append(selected,to:ownContext),corrected:candidate.pinyinRemainder==nil)
            let old=session;session=staged;adopted=true;pi_destroy_session(old)
            let commit=selected+candidate.text;observeCommit(commit);reload();return commit
        }
        if let prefix=candidate.partialCode {
            guard candidate.sourceInput==rawInput,nineKeyInput,!englishInput,
                  partialRecoveryCandidates().contains(where:{$0.text==candidate.text && $0.partialCode==prefix && $0.comment==candidate.comment}) else {return ""}
            let active=Int(pi_unselected_input_start(session)),original=rawInput
            guard active>=0,active<=original.count else {return ""}
            let pending=String(original.dropFirst(active))
            guard pending.hasPrefix(prefix),pending.count>prefix.count else {return ""}
            let suffix=String(pending.dropFirst(prefix.count)),staged=pi_create_session()
            guard staged != 0 else {return ""}
            guard pi_set_nine_key(staged,1) != 0,pi_set_private(staged,privateInput ? 1:0) != 0,pi_set_ascii_mode(staged,0) != 0 else {pi_destroy_session(staged);return ""}
            for key in suffix.utf8 {_ = pi_process_key(staged,Int32(key),0)}
            guard String(cString:pi_raw_input(staged))==suffix,rawInput==original else {pi_destroy_session(staged);return ""}
            let selected=String(cString:pi_selected_prefix(session)).trimmingCharacters(in:.whitespaces)
            let old=session;session=staged;pi_destroy_session(old)
            let commit=selected+candidate.text
            rememberChoice(code:prefix,candidate:candidate,context:SentenceContextWindow.append(selected,to:ownContext))
            observeCommit(commit);reload();return commit
        }
        if let pending=candidate.latinInput {
            guard mixedEnglishEnabled,!englishInput,candidate.sourceInput==rawInput,
                  mixedCandidates().contains(where:{$0.text==candidate.text && $0.latinInput==pending && $0.sourceInput==candidate.sourceInput}) else { return "" }
            let selected=String(cString:pi_selected_prefix(session)).trimmingCharacters(in:.whitespaces)
            let commit=selected+candidate.text
            pi_clear(session);observeCommit(commit);replacement=nil;reload();return commit
        }
        if let trigger=candidate.supplementaryTrigger {
            guard !englishInput,candidate.sourceInput==rawInput,
                  supplementaryCandidates().contains(where:{$0.text==candidate.text && $0.supplementaryTrigger==trigger}) else { return "" }
            let selected=String(cString:pi_selected_prefix(session)).trimmingCharacters(in:.whitespaces)
            let commit=selected+candidate.text
            pi_clear(session);observeCommit(commit);replacement=nil;reload();return commit
        }
        if let id=candidate.personalID {
            guard candidate.sourceInput==rawInput,!englishInput,
                  let entry=personalLexicon.entries.first(where:{$0.id==id}),entry.text==candidate.text,
                  personalCandidates().contains(where:{$0.personalID==id}),
                  let fresh=try? personalStore?.load(),fresh.entries.contains(entry) else { return "" }
            let selected=String(cString:pi_selected_prefix(session)).trimmingCharacters(in:.whitespaces)
            let commit=selected+entry.text
            pi_clear(session);observeCommit(commit);replacement=nil;reload();return commit
        }
        let original=rawInput,selected=String(cString:pi_selected_prefix(session)).trimmingCharacters(in:.whitespaces)
        let active=pi_unselected_input_start(session)
        let learningCode=NineKeySpelling.rawCode(selected.isEmpty ? original:(active<0 || active>128 ? "":String(original.dropFirst(Int(active)))))
        let context=SentenceContextWindow.append(selected,to:ownContext)
        if let assemblyID=candidate.assemblyID {
            guard predictionComplete,predictionRevision==revision,candidate.sourceInput==original,predictionEligible,
                  let plan=assemblyPlans[assemblyID],plan.text==candidate.text,plan.input==candidate.replacementInput,
                  plan.readings.joined(separator:" ")==candidate.comment,
                  predictionHead.contains(where:{$0.index==candidate.index && $0.assemblyID==assemblyID && $0.text==candidate.text}),
                  let code=learningCode,NineKeySpelling.isRelated(code,NineKeySpelling.encode(candidate.comment) ?? "") else { return "" }
            guard let staged=stageAssembly(plan) else { return "" }
            guard rawInput==original else { pi_destroy_session(staged);return "" }
            let old=session;session=staged;pi_destroy_session(old)
            let commit=selected+plan.text;observeCommit(commit)
            rememberChoice(code:code,candidate:candidate,context:context,corrected:true);reload();return commit
        }
        if let input=candidate.replacementInput {
            guard predictionComplete,predictionRevision==revision,candidate.sourceInput==original,predictionEligible else { return "" }
            let query=selected.isEmpty ? input:String(input.dropFirst(predictionActiveOffset))
            let expectedReading=NineKeySpelling.rawCode(query)
            guard pi_replace_pending_input(session,original,input) != 0 else { return "" };reload()
            var actual:InputCandidate?
            for offset in stride(from:0,to:256,by:32) {
                let values=nativeBatch(offset:offset,limit:32)
                if let value=values.first(where:{$0.text==candidate.text && NineKeySpelling.encode($0.comment)==expectedReading}) { actual=value;break }
                if values.count<32 { break }
            }
            guard let actual else { _ = pi_replace_pending_input(session,input,original);reload();return "" }
            let commit=chooseAbsolute(actual.index)
            if commit==selected+actual.text,let code=learningCode { rememberChoice(code:code,candidate:actual,context:context,corrected:true) }
            return commit
        }
        let commit=chooseAbsolute(candidate.index)
        if commit==selected+candidate.text,let code=learningCode { rememberChoice(code:code,candidate:candidate,context:context) }
        return commit
    }
    private func rememberChoice(code:String,candidate:InputCandidate,context:String,corrected:Bool=false) {
        defer { replacement=nil }
        guard !privateInput,choiceMemoryWritable,let reading=NineKeySpelling.encode(candidate.comment) else { return }
        var codes=Set([code])
        if let r=replacement,Date.timeIntervalSinceReferenceDate-r.time<=120,r.context==context,NineKeySpelling.isRelated(r.code,reading) { codes.insert(r.code) }
        let retry=replacement.map { r in Date.timeIntervalSinceReferenceDate-r.time<=120 && r.context==context && r.rejectedText != nil && r.rejectedText != candidate.text && NineKeySpelling.isRelated(r.code,reading) } ?? false
        // A confirmed typo correction also teaches the correctly spelled code.
        // It remains the same reading/text/context, with no migration or loss
        // of the original mistyped-code record.
        if corrected || codes.count>1 || retry { codes.insert(reading) }
        do {
            var next=choiceMemory
            for c in codes where NineKeySpelling.isRelated(c,reading) {
                if retry { try next.recordCorrection(code:c,reading:candidate.comment,text:candidate.text,context:context) }
                else { try next.record(code:c,reading:candidate.comment,text:candidate.text,context:context,strength:(codes.count>1 || corrected) ? 2:1) }
            }
            try saveChoiceMemory(next);choiceMemory=next
        } catch { /* Preserve existing personalization; offline typing still works. */ }
    }
    private func saveChoiceMemory(_ memory:NineKeyChoiceMemory) throws {
        guard personalEpoch==currentPersonalEpoch else {throw InputDataError.invalidRecord}
        guard let baseURL else { throw InputDataError.invalidRecord };try memory.validate()
        let data=try JSONEncoder().encode(memory);guard data.count<=512*1024 else { throw InputDataError.oversized }
        #if os(iOS)
        try data.write(to:baseURL.appendingPathComponent("nine-choice-memory-v3.json"),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to:baseURL.appendingPathComponent("nine-choice-memory-v3.json"),options:.atomic)
        #endif
    }
    private func releasePredictionProbe() {
        if predictionProbe != 0,personalEpoch==Self.initializedEpoch {pi_destroy_session(predictionProbe)}
        predictionProbe=0
    }
    private func invalidatePrediction() {
        ninePredictionPreparation=nil;sentenceExploration=nil
        ninePreparationWorker.cancel();nineSpanWorkPending=false;ninePreparedSpan=nil
        visibilityRevision = -1;visibilityPage = .init()
        predictionProbeCache=[:]
        preferencePredictionRevision = -1;preferencePredictionRows=[]
        predictionExpansionQueue=[];predictionExpansionRows=[];predictionExpansionRanked=false;predictionProtectedExtras=nil
        continuationRevision = -1;continuationRanked=false;continuationRows=[];continuationCandidates=[]
        semanticRanker?.cancel();predictionModelBefore="";predictionModelAfter="";semanticWaiting=false;semanticScores=[:];sentenceExploration=nil;assemblyPlans=[:];localSemanticRows=[];localSemanticContexts=[:];lexicalRanks=[:]
        if retainPredictionProbe,personalEpoch==Self.initializedEpoch,predictionProbe != 0 {pi_clear(predictionProbe)}
        else {releasePredictionProbe()}
        predictionRevision = -1;predictionComplete=false;predictionHead=[];predictionQueue=[];predictionLocalQueue=[];predictionLocalBest=[];predictionLocalPrimary=[];predictionJointQueued=false;predictionLocalContexts=[:];predictionLocalScoreCache=[:];languageScoreCache=[:]
    }
    private var syllableRevision = -1
    private var syllableCache:[String]=[]
    var nineSyllables:[String] {
        guard ready else { return [] }
        if syllableRevision != revision {
            syllableCache=(0..<Int(pi_nine_syllable_count(session))).map{String(cString:pi_nine_syllable_text(session,$0))};syllableRevision=revision
        }
        return syllableCache
    }
    var canUndoNineSyllable: Bool { ready && pi_nine_can_undo_syllable(session) != 0 }
    @discardableResult func selectNineSyllable(_ index: Int) -> Bool {
        guard ready, index >= 0, pi_nine_select_syllable(session, index) != 0 else { return false }
        markNativeLearningChanged();reload(); return true
    }
    @discardableResult func undoNineSyllable() -> Bool {
        guard ready, pi_nine_undo_syllable(session) != 0 else { return false }
        markNativeLearningChanged();reload(); return true
    }
    func clear() { guard refreshResetBarrier() else { return }; markNativeLearningChanged();replacement=nil;pi_clear(session); reload() }
    var rawInput: String { ready ? String(cString: pi_raw_input(session)) : "" }
    private func latinDisplay()->(selected:String,pending:String)? {
        guard ready,!nineKeyInput,!englishInput,mixedEnglishEnabled,!rawInput.isEmpty else{return nil}
        let raw=rawInput,selected=String(cString:pi_selected_prefix(session)).trimmingCharacters(in:.whitespaces)
        var active=Int(pi_unselected_input_start(session));if active<0,selected.isEmpty {active=0}
        guard active>=0,active<=raw.count else{return nil}
        let pending=String(raw.dropFirst(active))
        guard pending.utf8.allSatisfy({(97...122).contains($0)}),pending.count>=2 else{return nil}
        let suggestions=mixedCandidates()
        // Provider guesses and prefixes must not erase the host's Chinese
        // syllable boundaries or a prefix the user has already selected.
        guard mixedLatinDisplayAllowed,!mixedChinesePriority else {lastLatinDisplayInput="";return nil}
        let recognized = !suggestions.isEmpty || lastLatinDisplayInput==raw || MixedEnglishLexicon.words.contains{$0.lowercased().hasPrefix(pending)}
        guard recognized else{return nil};lastLatinDisplayInput=raw
        return (selected,pending)
    }
    func displayedPreedit(reading: String) -> String {
        guard ready else { return preedit }
        if !nineKeyInput {
            if let parts=latinDisplay() {return parts.selected+parts.pending}
            return preedit
        }
        return reading.withCString { String(cString: pi_nine_display_preedit(session, $0)) }
    }
    func takeReadablePendingInput(reading: String) -> String {
        guard ready else { return "" }
        markNativeLearningChanged()
        // Display placeholders are not commit text. Keep verified pinyin for a
        // readable literal request; an unresolved tail preserves the actual
        // typed keys instead of committing an ellipsis or expanded letter group.
        var pending = nineKeyInput ? reading.withCString { String(cString:pi_nine_readable_preedit(session,$0)) }.replacingOccurrences(of: " ", with: "") : rawInput
        if nineKeyInput, pending.contains("…") || pending.isEmpty && !rawInput.isEmpty {
            let raw = rawInput, selected = String(cString:pi_selected_prefix(session)).trimmingCharacters(in: .whitespaces)
            let active = Int(pi_unselected_input_start(session))
            if selected.isEmpty { pending = raw }
            else {
                // An unprovable offset must not clear or guess across selected
                // Chinese text. Keep the draft available for explicit editing.
                guard active >= 0, active <= raw.count else { return "" }
                pending = selected + raw.dropFirst(active)
            }
        }
        if !nineKeyInput {
            let selected=String(cString:pi_selected_prefix(session)).trimmingCharacters(in:.whitespaces),active=Int(pi_unselected_input_start(session))
            if !selected.isEmpty,active>=0,active<=rawInput.count { pending=selected+rawInput.dropFirst(active) }
        }
        pi_clear(session); reload(); return pending
    }
    private func candidateReading(_ candidate: InputCandidate) -> String? {
        let value = candidate.comment.lowercased().trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == " " || $0 == "'") }) else { return nil }
        return readingParts(value).joined(separator:" ")
    }
    func canManage(_ candidate: InputCandidate) -> Bool { candidate.personalID==nil && candidate.latinInput==nil && candidate.supplementaryTrigger==nil && !privateInput && candidateReading(candidate) != nil }
    func isPinned(_ candidate: InputCandidate) -> Bool {
        guard let reading = candidateReading(candidate) else { return false }
        return managedEntries.contains { !$0.deleted && $0.reading == reading && $0.text == candidate.text && $0.pinned }
    }
    func manage(_ candidate: InputCandidate, pinned: Bool?) throws {
        guard !privateInput, let reading = candidateReading(candidate), let coordinator else { throw InputDataError.invalidRecord }
        markNativeLearningChanged()
        try coordinator.manage(reading: reading, text: candidate.text, pinned: pinned)
        if pinned == nil,choiceMemoryWritable { var next=choiceMemory;next.reset(text:candidate.text,reading:reading);try saveChoiceMemory(next);choiceMemory=next }
        managedEntries = try coordinator.entries(); cloudCommittedVersion &+= 1; managementPending = true
        applyPins(); reload()
    }
    private func applyPins() {
        for entry in appliedPins { _ = pi_set_word_pinned(entry.reading, entry.text, 0) }
        appliedPins = managedEntries.filter { !$0.deleted && $0.pinned }
        for entry in appliedPins { _ = pi_set_word_pinned(entry.reading, entry.text, 1) }
    }
    func takePendingInput() -> String {
        guard ready else { return "" }
        if !nineKeyInput {return takeReadablePendingInput(reading:"")}
        let pending = rawInput
        markNativeLearningChanged();pi_clear(session); reload()
        return pending
    }
    func switchToEnglish(_ english: Bool) -> String {
        guard ready else { return "" }
        // A mode switch preserves unfinished letters as typed, rather than
        // silently clearing them or guessing a Chinese candidate.
        let pending = takePendingInput()
        if pi_set_ascii_mode(session, english ? 1 : 0) != 0 { englishInput = english }
        reload()
        return pending
    }
    @discardableResult func privacy(_ enabled: Bool) -> Bool {
        guard refreshResetBarrier() else { return false }
        markNativeLearningChanged()
        let result = pi_set_private(session, enabled ? 1 : 0) != 0
        if result { coordinator?.invalidateDatedObservation();privateInput = enabled;resetPredictionContext();_ = pi_set_ascii_mode(session, englishInput ? 1 : 0) }; reload(); return result
    }
    @discardableResult func nineKey(_ enabled: Bool) -> Bool {
        guard refreshResetBarrier(), preedit.isEmpty, pi_set_nine_key(session, enabled ? 1 : 0) != 0 else { return false }
        markNativeLearningChanged();nineKeyInput = enabled; _ = pi_set_ascii_mode(session, englishInput ? 1 : 0); reload(); return true
    }
    var learningCheckpointMetrics:LearningCheckpointMetrics {coordinator?.lastCheckpointMetrics ?? LearningCheckpointMetrics()}
    private func learningRefreshContext(publish: SnapshotPublisher?) -> String {
        let publisher: String
        switch publish {case .containingApp?:publisher="app";case .keyboard(let access)?:publisher="keyboard-\(access)";case nil:publisher="local"}
        let consent: String
        if originalStorageBase == nil {
            let prefs=UserDefaults(suiteName:LocalLearningCoordinator.groupID)
            let deadline=prefs?.double(forKey:"mobile-group-expiry") ?? 0
            consent="\(prefs?.bool(forKey:"learning-sharing-enabled") == true)|\(prefs?.string(forKey:"privacy-departed-reason") ?? "")|\(deadline)|expired:\(deadline>0 && Date().timeIntervalSince1970>=deadline)"
        } else {consent="isolated"}
        return "\(personalEpoch)|\(publisher)|\(privateInput)|\(Int(Date().timeIntervalSince1970/86400))|\(consent)"
    }
    private func learningRefreshRequest(publish: SnapshotPublisher?) -> LearningRefreshRequest {
        .init(owner:learningRefreshOwner,generation:learningCheckpointGate.mutation,validationGeneration:learningCheckpointGate.validationGeneration,context:learningRefreshContext(publish:publish),sources:coordinator?.learningRefreshSources ?? [])
    }
    /// Opt-in iOS idle adapter. Every path, including invalid input, completes on
    /// the main queue. Disk reads/JSON validation/SHA run on immutable utility work.
    #if os(iOS)
    private var cloudUtilityInFlight = false
    private var cloudPublishedVersion: UInt64?
    private var cloudPreparedRankToken: String?
    private var cloudUtilityRetryAt = 0.0
    /// Value snapshots only. File/JSON/score work stays on utility; a resulting
    /// rank pointer is adopted at the next new composition, never mid-candidate.
    func stageCachedCloudLearningBootstrap(publish: SnapshotPublisher?) {
        let prefs = UserDefaults(suiteName: LocalLearningCoordinator.groupID)
        guard ready, !cloudUtilityInFlight, ProcessInfo.processInfo.systemUptime >= cloudUtilityRetryAt,
              originalStorageBase == nil, !privateInput,
              prefs?.bool(forKey: "learning-sharing-enabled") == true,
              prefs?.bool(forKey: "cloud-learning-enabled") == true,
              let (producer, directory) = coordinator?.cloudBootstrapLocation(publisher: publish) else { return }
        let token = prefs?.string(forKey: "cloud-learning-model-token")
        let version = cloudCommittedVersion, publishNeeded = cloudPublishedVersion != cloudCommittedVersion
        let rankNeeded = token != nil && (token != cloudPreparedRankToken || publishNeeded)
        guard publishNeeded || rankNeeded else { return }
        cloudUtilityInFlight = true
        let entries = managedEntries, capturedEpoch = personalEpoch
        learningRefreshQueue.async { [weak self] in
            var published = false
            var prepared: (RecencyCoordinator.Snapshot, UUID, UInt64)?
            let current = UserDefaults(suiteName: LocalLearningCoordinator.groupID)
            if PersonalDataReset.generation == capturedEpoch,
               current?.bool(forKey: "learning-sharing-enabled") == true,
               current?.bool(forKey: "cloud-learning-enabled") == true {
                if publishNeeded {
                    do { try AppleCloudProducerSnapshot.publish(entries, producer: producer, directory: directory); published = true }
                    catch { /* No native mutation. A later idle tick can retry. */ }
                }
                if rankNeeded, let group = current?.string(forKey: "cloud-learning-group").flatMap(UUID.init(uuidString:)),
                   let epoch = (current?.object(forKey: "cloud-learning-epoch") as? NSNumber)?.uint64Value,
                   let state = AppleCloudLearningRankState.read(directory: directory, group: group, epoch: epoch, preferences: current) {
                    prepared = (state.snapshot(producer: producer, entries: entries, uptime: ProcessInfo.processInfo.systemUptime), group, epoch)
                }
            }
            let didPublish = published, result = prepared
            DispatchQueue.main.async {
                guard let self else { return }; self.cloudUtilityInFlight = false
                guard self.personalEpoch == capturedEpoch, self.currentPersonalEpoch == capturedEpoch else { return }
                if didPublish { self.cloudPublishedVersion = version }
                if let (snapshot, group, epoch) = result {
                    self.coordinator?.stageCloudSnapshot(snapshot, group: group, epoch: epoch)
                    self.cloudPreparedRankToken = token
                }
                if (publishNeeded && !didPublish) || (rankNeeded && result == nil) {
                    self.cloudUtilityRetryAt = ProcessInfo.processInfo.systemUptime + 30
                }
            }
        }
    }
    #endif
    func prepareLearningRefresh(publish: SnapshotPublisher?, completion:@escaping (LearningRefreshPreparation)->Void) {
        let request=learningRefreshRequest(publish:publish)
        learningRefreshQueue.async {
            let preparation=LearningRefreshReader.evaluate(request)
            DispatchQueue.main.async {completion(preparation)}
        }
    }
    private func learningRefreshIdentityIsCurrent(_ preparation:LearningRefreshPreparation,publish:SnapshotPublisher?) -> Bool {
        ready && preparation.request.owner==learningRefreshOwner && preparation.request.generation==learningCheckpointGate.mutation &&
        preparation.request.context==learningRefreshContext(publish:publish) && personalEpoch==currentPersonalEpoch
    }
    func isCurrentLearningRefreshPreparation(_ preparation:LearningRefreshPreparation,publish:SnapshotPublisher?) -> Bool {
        learningRefreshIdentityIsCurrent(preparation,publish:publish) &&
        preparation.request.validationGeneration==learningCheckpointGate.validationGeneration &&
        (preparation.validUntilUptime.map{ProcessInfo.processInfo.systemUptime <= $0} ?? true) &&
        (preparation.stamps == nil || LearningRefreshReader.unchangedFiles(preparation))
    }
    func synchronizeLearning(publish: SnapshotPublisher? = nil, preparation:LearningRefreshPreparation? = nil) throws {
        KeyboardRuntimeDiagnostics.record(.checkpointBegin)
        let diagnosticStarted = ProcessInfo.processInfo.systemUptime
        var checkpointSucceeded=false
        var diagnosticNativeTransactionStarted=false
        defer {
            if !checkpointSucceeded {learningCheckpointGate.invalidate()}
            let metrics = diagnosticNativeTransactionStarted ? learningCheckpointMetrics : LearningCheckpointMetrics()
            KeyboardRuntimeDiagnostics.record(checkpointSucceeded ? (learningRefreshWasSkipped ? .checkpointSkipped : .checkpointEnd) : .checkpointFailed,
                [.elapsedMilliseconds: (ProcessInfo.processInfo.systemUptime - diagnosticStarted) * 1000,
                 .persistedBytes: Double(learningRefreshWasSkipped ? 0 : metrics.persistedBytes),
                 .skippedWriteBytes: Double(learningRefreshWasSkipped ? 0 : metrics.skippedWriteBytes),
                 .nativeImports: Double(learningRefreshWasSkipped ? 0 : metrics.nativeImports),
                 .nativeResets: Double(learningRefreshWasSkipped ? 0 : metrics.nativeResets),
                 .ready: ready ? 1 : 0])
        }
        guard ready, let coordinator, let baseURL else { throw LearningSyncFailure.engineUnavailable }
        guard preedit.isEmpty else { throw LearningSyncFailure.busy }
        learningRefreshWasSkipped=false
        // A supplied preflight is a permission to run THIS prepared transaction,
        // not a hint. Falling back to an unprepared full export when it became
        // stale can start long work after the lifecycle owner cancelled it.
        if let preparation, !isCurrentLearningRefreshPreparation(preparation,publish:publish) { throw LearningSyncFailure.busy }
        let validPreparation=preparation
        if let preparation=validPreparation,pi_active_session_count()==1,
           learningCheckpointGate.canReuse(fingerprint:preparation.fingerprint,generation:preparation.request.generation,pending:preparation.pending,forced:managementPending) {
            learningRefreshWasSkipped=true;checkpointSucceeded=true;return
        }
        learningCheckpointGate.invalidate()
        // iOS63 keeps a private query probe warm. It is not an independent
        // learner, but must close before quiescent native checkpoint export.
        releasePredictionProbe()
        guard pi_active_session_count() == 1 else { throw LearningSyncFailure.busy }
        let directory = baseURL.appendingPathComponent("Checkpoint-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        pi_destroy_session(session); session = 0
        defer {
            session = pi_create_session()
            ready = session != 0
            if ready {
                _ = pi_set_nine_key(session, nineKeyInput ? 1 : 0)
                _ = pi_set_private(session, privateInput ? 1 : 0)
                _ = pi_set_ascii_mode(session, englishInput ? 1 : 0)
                reload()
            }
        }
        // Never export a running DB or clear an unfinished composition.
        diagnosticNativeTransactionStarted=true
        managedEntries = try coordinator.checkpoint(exportFile: directory.appendingPathComponent("engine.tsv"), importFile: directory.appendingPathComponent("incoming.tsv"), publish: privateInput ? nil : publish,
            engineExport: { pi_export_learning($0.path) }, engineImport: { pi_import_learning($0.path) }, engineReset: { pi_reset_word_frequency($0.reading, $0.text, $0.frequency) },allowDatedLearning: !privateInput)
        cloudCommittedVersion &+= 1
        managementPending = false; applyPins()
        learningCheckpointRuns += 1;checkpointSucceeded=true
        // Postflight can only certify inputs unchanged across the completed
        // transaction. A concurrently newer shared publication is never marked
        // consumed merely because it appeared before this background read.
        if let preparation=validPreparation,learningRefreshIdentityIsCurrent(preparation,publish:publish) {
            let request=learningRefreshRequest(publish:publish)
            learningRefreshQueue.async { [weak self] in
                let after=LearningRefreshReader.evaluate(request)
                DispatchQueue.main.async { [weak self] in
                    guard let self,self.isCurrentLearningRefreshPreparation(after,publish:publish) else {return}
                    self.learningCheckpointGate.checkpointSucceeded(generation:request.generation,validation:request.validationGeneration,
                        beforeExternal:preparation.externalFingerprint,afterExternal:after.externalFingerprint,
                        afterFingerprint:after.fingerprint,pending:after.pending)
                }
            }
        }
    }
    private func reload() {
        mixedRevision = -1;mixedRows=[];mixedLeads=false;mixedChinesePriority=false;mixedLatinDisplayAllowed=false
        invalidatePrediction()
        revision &+= 1
        preedit = String(cString: pi_preedit(session))
        if preedit.isEmpty {hostContext=nil}
        page = Int(pi_page_number(session)); hasNextPage = pi_has_next_page(session) != 0
        candidates = (0..<Int(pi_candidate_count(session))).map { String(cString: pi_candidate_text(session, $0)) }.filter(candidateIsDisplayable)
    }
    func finish() { markNativeLearningChanged();hostContext=nil;invalidatePrediction();releasePredictionProbe();if session != 0 {if personalEpoch==Self.initializedEpoch {pi_destroy_session(session)};session=0};ready=false }
    deinit { if let resetObserver {PersonalDataReset.unobserve(resetObserver)};if personalEpoch==Self.initializedEpoch {if predictionProbe != 0 {pi_destroy_session(predictionProbe)};if session != 0 {pi_destroy_session(session)}} }
}

// The pinned essay is UTF-8 lexicographically sorted. Search its mapped lines
// without expanding 437k words into a second in-memory dictionary in the IME.
private final class CommonWordPrior {
    private let data:Data
    private var cache:[String:UInt64]=[:]
    init?(url:URL) {
        guard let bytes=try? Data(contentsOf:url,options:.mappedIfSafe),!bytes.isEmpty,bytes.count<=8*1024*1024 else{return nil}
        data=bytes
    }
    func frequency(_ text:String)->UInt64 {
        if let value=cache[text] {return value}
        let wanted=Array(text.utf8);var low=0,high=data.count,value:UInt64=0
        while low<high {
            var start=(low+high)/2
            while start>low && data[start-1] != 10 {start-=1}
            var tab=start
            while tab<data.count && data[tab] != 9 && data[tab] != 10 {tab+=1}
            var end=tab
            while end<data.count && data[end] != 10 {end+=1}
            let word=data[start..<tab]
            if word.elementsEqual(wanted) {
                if tab<end && data[tab]==9 {
                    for byte in data[(tab+1)..<end] {
                        if byte==13 {break}
                        guard byte>=48 && byte<=57,value<UInt64.max/10-10 else{value=0;break}
                        value=value*10+UInt64(byte-48)
                    }
                }
                break
            }
            if word.lexicographicallyPrecedes(wanted) {low=min(data.count,end+1)}else{high=start}
        }
        if cache.count>=512 {cache.removeAll(keepingCapacity:true)}
        cache[text]=value;return value
    }
}
