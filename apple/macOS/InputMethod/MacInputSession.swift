import AppKit
import CryptoKit
import PrivateInputKit

// BEGIN MacHiddenCheckpointGate -- metadata only, independently host-testable.
// No clients, text, native sessions or files are retained by this policy.
struct MacHiddenCheckpointGate {
    struct Ticket:Equatable {let generation:UInt64,dirty:UInt64}
    private(set) var activeOwners=Set<UUID>()
    private(set) var generation:UInt64=0
    private(set) var dirty:UInt64=1 // A process restart must inspect persisted native learning once.
    private(set) var completedDirty:UInt64=0
    private(set) var externalFingerprint:String?
    private(set) var hiddenSince:TimeInterval?
    private(set) var nativeRunning=false
    let cooldown:TimeInterval
    init(cooldown:TimeInterval=15.0) {self.cooldown=max(0,cooldown)}
    mutating func activate(_ owner:UUID) {activeOwners.insert(owner);generation &+= 1;hiddenSince=nil}
    mutating func deactivate(_ owner:UUID,now:TimeInterval) {
        activeOwners.remove(owner);generation &+= 1
        if activeOwners.isEmpty {hiddenSince=now}
    }
    mutating func changed() {dirty &+= 1}
    var ticket:Ticket {Ticket(generation:generation,dirty:dirty)}
    func current(_ token:Ticket)->Bool {activeOwners.isEmpty && generation==token.generation}
    func canPrepare(_ token:Ticket,now:TimeInterval,nativeSessions:Int)->Bool {
        guard current(token),!nativeRunning,nativeSessions==0,let hiddenSince else{return false}
        return now>=hiddenSince && now-hiddenSince>=cooldown
    }
    func needsCheckpoint(_ token:Ticket,fingerprint:String?,pending:Bool)->Bool {
        pending || fingerprint==nil || dirty>completedDirty || externalFingerprint != fingerprint
    }
    mutating func beginNative(_ token:Ticket,nativeSessions:Int)->Bool {
        guard current(token),!nativeRunning,nativeSessions==1 else{return false}
        nativeRunning=true;return true
    }
    mutating func endedNative() {nativeRunning=false}
    mutating func completed(_ token:Ticket,fingerprint:String?) {
        guard current(token),!nativeRunning,let fingerprint else{return}
        completedDirty=max(completedDirty,token.dirty);externalFingerprint=fingerprint
    }
}
// END MacHiddenCheckpointGate

// Bounded, read-only host evidence. Raw nearby text never leaves capture().
struct MacInputAnchor:Equatable {
    let document:String,position:Int,prefix:String,suffix:String,marked:Bool
    static func capture(document:String,selection:NSRange,marked:NSRange,length:Int,expectedSuffix:String,read:(NSRange)->String?)->Self? {
        guard !document.isEmpty,expectedSuffix.utf16.count<=128,length>=0,length != NSNotFound,
              selection.location != NSNotFound,selection.length==0,selection.location<=length else{return nil}
        let hasMark=marked.location != NSNotFound && marked.length>0
        let position:Int,end:Int
        if hasMark {
            guard expectedSuffix.isEmpty,marked.location>=0,marked.location<=length,marked.length<=length-marked.location,
                  selection.location>=marked.location,selection.location<=NSMaxRange(marked) else{return nil}
            position=marked.location;end=NSMaxRange(marked)
        } else {position=selection.location;end=position}
        let n=expectedSuffix.utf16.count
        guard position>=n else{return nil}
        let start=position-n
        func text(_ range:NSRange)->String? {
            if range.length==0 {return ""}
            guard let value=read(range),value.utf16.count==range.length else{return nil};return value
        }
        guard text(NSRange(location:start,length:n))==expectedSuffix,
              let before=text(NSRange(location:max(0,start-32),length:min(32,start))),
              let after=text(NSRange(location:end,length:min(32,length-end))) else{return nil}
        func digest(_ value:String)->String {SHA256.hash(data:Data(value.utf8)).map{String(format:"%02x",$0)}.joined()}
        return Self(document:document,position:start,prefix:digest(before),suffix:digest(after),marked:hasMark)
    }
    func sameBoundary(as other:Self)->Bool {document==other.document && position==other.position && prefix==other.prefix && suffix==other.suffix}
}

// Shared by the IMK adapter and isolated NSTextView acceptance.
protocol MacInputClient {
    func insert(_ text: String)
    func insertPair(_ text:String,caretBack:Int)
    func mark(_ text: String)
    func mark(_ text:String,cursor:Int)
    func surroundingText()->SurroundingText?
    func correctionAnchor(expectedSuffix:String)->MacInputAnchor?
}
extension MacInputClient {
    func insertPair(_ text:String,caretBack:Int) {insert(text)}
    func surroundingText()->SurroundingText? {nil}
    func correctionAnchor(expectedSuffix:String)->MacInputAnchor? {nil}
    func mark(_ text:String,cursor:Int) {mark(text)}
}

private final class MacCandidateManagementAction:NSObject {
    let perform:()->Void
    init(_ perform:@escaping()->Void) {self.perform=perform}
    @objc func invoke(_ sender:NSMenuItem) {perform()}
}

final class MacInputSession {
    let engine: NativeEngine
    private(set) var english = false
    private(set) var candidateOffset = 0
    private(set) var expanded=false
    private(set) var selectedIndex=0
    private(set) var candidateLayout:DesktopCandidateLayout
    private var activeColumns:Int {candidateLayout.columns(expanded:expanded)}
    private var rowRevision = -1, rows:[InputCandidate]=[],navigationLocked=false
    private var rankWork:DispatchWorkItem?
    private let ranker:MacSemanticRanker?
    private let capsLockSwitchOverride:Bool?
    private let symbolPairingSettings:()->(autoPair:Bool,caretInside:Bool)
    private var observedCapsLock=false
    private var numericLiteralTail=""
    private struct OwnCommit {
        var text,remaining,code,context,reading,epoch:String
        var anchor:MacInputAnchor
        var time:TimeInterval
        var awaitingDelete=false,retyping=false
    }
    private var ownCommit:OwnCommit?
    private let personalEpoch:()->String
    private var observedPersonalEpoch:String
    private var stopResetObservation:(()->Void)?
    private let managementMenus=NSHashTable<NSMenu>.weakObjects()
    private func refreshPersonalEpoch() {
        if observedPersonalEpoch != personalEpoch() {resetPersonalState()}
    }
    private func resetPersonalState() {
        // Reset notifications must discard own text immediately, even when no
        // more keys arrive. Epoch checks also cover delayed notifications.
        observedPersonalEpoch=personalEpoch();ownCommit=nil
        rankWork?.cancel();ranker?.cancel();rows=[];rowRevision = -1
        candidateOffset=0;selectedIndex=0;expanded=false;navigationLocked=false;numericLiteralTail=""
        for menu in managementMenus.allObjects {menu.cancelTracking();menu.removeAllItems()}
        managementMenus.removeAllObjects()
        // Apply the engine barrier before publishing empty candidates; observer
        // order is intentionally unspecified by PersonalDataReset.
        engine.clear();engine.resetPredictionContext();candidatesChanged?()
    }
    private let now:()->TimeInterval
    // Only a confirmed different choice teaches a correction. Deletion alone
    // and quick repeated typing never change the bounded choice memory.
    private func forgetCorrection() {ownCommit=nil;engine.resetPredictionContext()}
    func invalidateCorrection() {forgetCorrection()}
    private func validateCorrection(client:MacInputClient)->Bool {
        guard var c=ownCommit else{return false}
        let elapsed=now()-c.time
        let expected=c.retyping ? "":c.remaining
        guard c.epoch==personalEpoch(),elapsed>=0,elapsed<=20,let a=client.correctionAnchor(expectedSuffix:expected),
              a.sameBoundary(as:c.anchor),a.marked==c.retyping else {forgetCorrection();return false}
        c.awaitingDelete=false;ownCommit=c;return true
    }
    private func prepareChoice(client:MacInputClient) {
        if ownCommit?.retyping==true {_ = validateCorrection(client:client)}
        else if ownCommit != nil {forgetCorrection()}
    }
    func manageCandidate(_ candidate:InputCandidate,pinned:Bool?,revision:Int,sourceInput:String)throws->Bool {
        refreshRows()
        guard revision==engine.revision,sourceInput==engine.rawInput,
              candidate.generation==revision,engine.canManage(candidate),
              rows.contains(where:{$0.index==candidate.index && $0.text==candidate.text && $0.comment==candidate.comment}) else{return false}
        forgetCorrection();try engine.manage(candidate,pinned:pinned);refreshRows();return true
    }
    func managementMenu(for candidate:InputCandidate,onChange:@escaping()->Void)->NSMenu? {
        refreshPersonalEpoch()
        guard candidate.generation==engine.revision,engine.canManage(candidate) else{return nil}
        let revision=engine.revision,source=engine.rawInput,pinned=engine.isPinned(candidate),epoch=observedPersonalEpoch
        let menu=NSMenu();menu.autoenablesItems=false;managementMenus.add(menu)
        let actions:[(String,Bool?)]=[(pinned ? "取消置顶":"置顶",!pinned),("恢复默认词频",nil)]
        for (title,value) in actions {
            let item=NSMenuItem(title:title,action:#selector(MacCandidateManagementAction.invoke(_:)),keyEquivalent:"")
            let action=MacCandidateManagementAction { [weak self] in
                guard let self else{return}
                self.refreshPersonalEpoch();guard epoch==self.observedPersonalEpoch else{return}
                do {if try self.manageCandidate(candidate,pinned:value,revision:revision,sourceInput:source) {onChange()}}
                catch {NSSound.beep()}
            }
            item.target=action;item.representedObject=action;menu.addItem(item)
        }
        if pinned {menu.items.last?.toolTip="恢复学习词频；保留手动置顶。可用“取消置顶”移除置顶。"}
        return menu
    }
    var candidatesChanged:(()->Void)?
    private(set) var modelMetrics=MacSemanticRanker.Metrics()
    var allCandidateRows:[InputCandidate] {
        refreshRows();return rows
    }
    var candidateRows:[InputCandidate] {
        refreshRows();return Array(rows.dropFirst(candidateOffset).prefix(activeColumns))
    }
    var highlightedCandidate:InputCandidate? {
        refreshRows();return rows.indices.contains(selectedIndex) ? rows[selectedIndex]:nil
    }
    private func refreshRows() {
        refreshPersonalEpoch()
        guard rowRevision != engine.revision else{return}
        rowRevision=engine.revision;rankWork?.cancel();ranker?.cancel()
        candidateOffset=0;selectedIndex=0;if engine.preedit.isEmpty {expanded=false};navigationLocked=false
        rows=engine.preedit.isEmpty ? []:engine.candidateBatch(offset:0,limit:max(36,candidateLayout.pageSize))
        if rows.isEmpty {ranker?.releaseAfterIdle()}
        guard KeyboardPreferences.macSemanticEnabled,let ranker,ranker.configured else{return}
        // Score only repair alternatives. Exact spelling, pins and personal
        // entries retain their native positions and frequency order.
        let repairs=rows.filter{row in
            guard row.text.count>=2,engine.canSemanticRank(row) else{return false}
            if row.pinyinRepair != nil {return row.pinyinRemainder==nil}
            return engine.hasHostContext && engine.canContextRank(row)
        }
        guard repairs.count>1 else{return}
        let revision=rowRevision,items=repairs.prefix(12).enumerated().map{MacSemanticRanker.Item(id:String($0.offset),text:$0.element.text)}
        let work=DispatchWorkItem { [weak self] in
            guard let self,self.engine.revision==revision,!self.navigationLocked else{return}
            ranker.evaluate(items,before:self.engine.modelContext.before,after:self.engine.modelContext.after) { [weak self] scores,metrics in
                guard let self,KeyboardPreferences.macSemanticEnabled,self.engine.revision==revision,self.rowRevision==revision,!self.navigationLocked else{return}
                self.modelMetrics=metrics
                let original=Array(repairs.prefix(12))
                let ordered=original.enumerated().sorted{a,b in
                    // Keep lexical/edit-distance ranking as a strong prior;
                    // CSC is a bounded tie-breaker, never free-form output.
                    let av = -Double(a.offset)*0.20 + max(-2,min(0,scores[String(a.offset)] ?? -2))*0.65
                    let bv = -Double(b.offset)*0.20 + max(-2,min(0,scores[String(b.offset)] ?? -2))*0.65
                    return av==bv ? a.offset<b.offset:av>bv
                }.map(\.element)
                self.rows=Self.mergingSemanticRanking(base:self.rows,ranked:ordered)
                self.candidatesChanged?()
            }
        }
        rankWork=work;DispatchQueue.main.asyncAfter(deadline:.now()+0.12,execute:work)
    }
    static func mergingSemanticRanking(base:[InputCandidate],ranked:[InputCandidate])->[InputCandidate] {
        NativeEngine.mergingSemanticRanking(base:base,ranked:ranked)
    }

    func loadMoreCandidates() {
        refreshRows();guard rows.count<1024 else{return}
        navigationLocked=true;rankWork?.cancel();ranker?.cancel()
        rows += engine.candidateBatch(offset:rows.count,limit:min(1024-rows.count,max(36,candidateLayout.pageSize)))
    }
    func highlightCandidate(_ candidate:InputCandidate) {
        refreshRows()
        guard let index=rows.firstIndex(where:{$0.index==candidate.index && $0.text==candidate.text}) else{return}
        navigationLocked=true;rankWork?.cancel();ranker?.cancel()
        selectedIndex=index;candidateOffset=(index/activeColumns)*activeColumns
    }
    func toggleExpanded() {
        refreshRows();navigationLocked=true;rankWork?.cancel();ranker?.cancel();expanded.toggle();candidateOffset=(selectedIndex/activeColumns)*activeColumns
    }
    func chooseCandidate(_ candidate:InputCandidate,client:MacInputClient) {
        refreshPersonalEpoch()
        guard candidate.generation==engine.revision else{return}
        prepareChoice(client:client)
        // Invalid host evidence cancels correction learning, while the user's
        // current click still selects that word from a freshly validated menu.
        let requested=candidate
        guard let candidate = requested.generation==engine.revision ? requested:engine.candidateBatch(offset:0,limit:max(36,rows.count)).first(where:{$0.text==requested.text && $0.comment==requested.comment}) else{return}
        let code=NineKeySpelling.rawCode(engine.rawInput),context=engine.precedingOwnText
        let before=client.correctionAnchor(expectedSuffix:"")
        let commit=engine.chooseCandidate(candidate)
        deliver(commit,client:client);candidateOffset=0;refreshRows()
        ownCommit=nil
        if !commit.isEmpty,engine.preedit.isEmpty,commit==candidate.text,engine.canManage(candidate),
           let code,let before,before.marked,let after=client.correctionAnchor(expectedSuffix:commit),
           !after.marked,before.sameBoundary(as:after),commit.utf16.count<=128,
           NineKeySpelling.isRelated(code,NineKeySpelling.encode(candidate.comment) ?? "") {
            ownCommit=OwnCommit(text:commit,remaining:commit,code:code,context:context,reading:candidate.comment,epoch:observedPersonalEpoch,anchor:after,time:now())
        }
    }
    init(engine:NativeEngine = NativeEngine(),semanticDirectory:URL?=nil,candidateLayout:DesktopCandidateLayout=KeyboardPreferences.desktopCandidateLayout,capsLockSwitchEnabled:Bool?=nil,now:@escaping()->TimeInterval={Date.timeIntervalSinceReferenceDate},personalEpoch:@escaping()->String={PersonalDataReset.generation},observePersonalReset:(@escaping()->Void)->(()->Void)={ action in
        let id=PersonalDataReset.observe(action);return {PersonalDataReset.unobserve(id)}
    },symbolPairingSettings:@escaping()->(autoPair:Bool,caretInside:Bool)={ (KeyboardPreferences.autoPairSymbols,KeyboardPreferences.caretInsidePairs) }) {
        self.engine=engine;self.candidateLayout=candidateLayout;self.now=now;self.symbolPairingSettings=symbolPairingSettings
        self.personalEpoch=personalEpoch;observedPersonalEpoch=personalEpoch()
        capsLockSwitchOverride=capsLockSwitchEnabled
        let directory=semanticDirectory ?? Bundle.main.url(forResource:"semantic-mac",withExtension:nil)
        ranker=directory.map(MacSemanticRanker.init)
        stopResetObservation=observePersonalReset { [weak self] in self?.resetPersonalState() }
    }
    deinit {stopResetObservation?();rankWork?.cancel();ranker?.cancel()}

    func input(_ text: String?, keyCode: Int, flags: Int, client: MacInputClient) -> Bool {
        refreshPersonalEpoch()
        guard engine.ready else { return false }
        let shortcuts = NSEvent.ModifierFlags([.command, .control, .option]).rawValue
        guard flags & Int(shortcuts) == 0 else {forgetCorrection();return false}
        let caps=flags & Int(NSEvent.ModifierFlags.capsLock.rawValue) != 0
        if capsLockSwitchOverride ?? KeyboardPreferences.macCapsLockSwitchEnabled {
            // macOS 27 may omit third-party IMEs from its native Caps Lock
            // switch. Reconcile only modifiers delivered to this IMK session;
            // keep the default keyDown event mask and its mouse/commit behavior.
            if caps != observedCapsLock {
                observedCapsLock=caps
                if english != caps {toggleEnglish(client:client);refreshRows()}
            }
            if keyCode==57 {return true}
            if caps,english,let text,text.unicodeScalars.count==1,
               text.utf8.allSatisfy({(65...90).contains($0) || (97...122).contains($0)}) {
                let shifted=flags & Int(NSEvent.ModifierFlags.shift.rawValue) != 0
                client.insert(shifted ? text.uppercased():text.lowercased())
                return true
            }
        } else {observedCapsLock=false}
        let code: Int32
        switch keyCode {
        case 49: code = 32
        case 51: code = 0xff08
        case 36, 76: code = 0xff0d
        case 53: code = 0xff1b
        case 123: code = 0xff51
        case 124: code = 0xff53
        case 125: code = 0xff54
        case 126: code = 0xff52
        case 116: code = 0xff55
        case 121: code = 0xff56
        default:
            guard let text, text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first else {forgetCorrection();return false}
            code = Int32(scalar.value)
        }
        let previous = engine.preedit
        if code == 0xff0d, !previous.isEmpty, !english {
            // Physical Return commits typed Latin spelling, preserving an
            // already selected Chinese prefix. Space still selects a word.
            forgetCorrection();navigationLocked=true;rankWork?.cancel();ranker?.cancel()
            let typed=engine.takePendingInput()
            candidateOffset=0;expanded=false;refreshRows();deliver(typed,client:client)
            return true
        }
        if ownCommit != nil {
            if validateCorrection(client:client),var c=ownCommit {
                if code==0xff08,previous.isEmpty,!c.remaining.isEmpty,!c.retyping,
                   now()-c.time<=10 || c.remaining != c.text {
                    c.remaining.removeLast();c.awaitingDelete=true;ownCommit=c
                    engine.resetPredictionContext()
                    // Let the host perform its native delete. The next event
                    // must prove it happened before any correction can be used.
                    return false
                }
                let letter=text.map{!$0.isEmpty && $0.utf8.allSatisfy{(97...122).contains($0) || $0==39}} ?? false
                if c.remaining.isEmpty,!c.retyping,previous.isEmpty,letter {
                    engine.noteFullyDeletedOwnCommit(code:c.code,context:c.context,rejectedText:c.text,reading:c.reading)
                    c.retyping=true;ownCommit=c
                } else if c.retyping,!previous.isEmpty,(letter || code==0xff08 || code==32 || (49...57).contains(code) || [0xff51,0xff53,0xff52,0xff54,0xff55,0xff56,0xff0d].contains(code)),flags & Int(NSEvent.ModifierFlags.shift.rawValue)==0 {
                    // Candidate navigation does not move the host caret.
                } else {forgetCorrection()}
            }
        }
        if let text,text.count==1,SymbolPairing.pairs[text] != nil {
            let settings=symbolPairingSettings()
            let plan=SymbolPairing.plan(for:text,autoPair:settings.autoPair,caretInside:settings.caretInside)
            finishComposition(client:client)
            // Own mapped opening symbols even with pairing disabled, so the
            // native punctuator cannot independently pair or rewrite them.
            engine.noteLiteralInput(plan.insertedText);client.insertPair(plan.insertedText,caretBack:plan.caretBack)
            if plan.caretBack>0 {engine.resetPredictionContext()}
            refreshRows();return true
        }
        if !english,previous.isEmpty,let text,text.count==1 {
            let hostNumeric=client.surroundingText()?.before.last?.isNumber==true
            if (48...57).contains(code) || (code==46 && (!numericLiteralTail.isEmpty || hostNumeric)) {
                numericLiteralTail=String((numericLiteralTail+text).suffix(32))
                engine.noteLiteralInput(text);client.insert(text);refreshRows();return true
            }
        }
        if code==0xff08,!numericLiteralTail.isEmpty {numericLiteralTail.removeLast()}
        else if !(48...57).contains(code),code != 46 {numericLiteralTail=""}
        if previous.isEmpty,!english,let text,text.utf8.allSatisfy({(97...122).contains($0)}) {
            engine.setHostContext(client.surroundingText())
        }
        if !english,!previous.isEmpty {
            refreshRows()
            if code == 0xff51 || code == 0xff53 {
                if flags & Int(NSEvent.ModifierFlags.shift.rawValue) != 0 {
                    if engine.movePinyinCursor(code == 0xff51 ? -1:1) {refreshRows();deliver("",client:client)}
                    return true
                }
                moveSelection(by:code == 0xff51 ? -1:1);return true
            }
            if code == 0xff52 || code == 0xff54 {
                navigationLocked=true;rankWork?.cancel();ranker?.cancel()
                if !expanded {toggleExpanded();return true}
                moveSelection(by:code == 0xff54 ? activeColumns:-activeColumns)
                return true
            }
            if code == 0xff1b,expanded {toggleExpanded();return true}
            if code == 0xff0d,expanded,let row=highlightedCandidate {chooseCandidate(row,client:client);return true}
            if code == 0xff55 || code == 0xff56 {
                navigationLocked=true;rankWork?.cancel();ranker?.cancel()
                let stride=expanded ? candidateLayout.pageSize:activeColumns
                let next=code == 0xff55 ? max(0,candidateOffset-stride):candidateOffset+stride
                if next>=rows.count {loadMoreCandidates()}
                if rows.indices.contains(next) {candidateOffset=next;selectedIndex=next}
                return true
            }
            let punctuation:[Int32:String]=[44:"，",46:"。",63:"？",33:"！",58:"：",59:"；"]
            if let symbol=punctuation[code],let first=candidateRows.first,first.pinyinRepair != nil,first.pinyinRemainder==nil {
                let corrected=engine.chooseCandidate(first)
                if !corrected.isEmpty,engine.preedit.isEmpty {
                    engine.noteLiteralInput(symbol);deliver(corrected+symbol,client:client);candidateOffset=0;return true
                }
            }
            if code == 32 || (49...57).contains(code) {
                if candidateRows.isEmpty {
                    // A punctuator/unknown spelling with no menu must not eat
                    // a digit as a candidate shortcut. Preserve the raw draft.
                    let raw=engine.takeReadablePendingInput(reading:"")
                    let literal=raw+String(UnicodeScalar(UInt32(code))!)
                    engine.noteLiteralInput(literal);deliver(literal,client:client);refreshRows();return true
                }
                if code == 32,let row=highlightedCandidate {chooseCandidate(row,client:client)}
                else {let shown=candidateRows,index=Int(code-49);if shown.indices.contains(index) {chooseCandidate(shown[index],client:client)}}
                return true
            }
        }
        let result = engine.key(code);candidateOffset=0;refreshRows()
        // Passing English through must leave the host's selected text intact.
        if result.handled || !result.commit.isEmpty || previous != engine.preedit {
            deliver(result.commit, client: client)
        }
        return result.handled
    }

    func applyCandidateLayout(_ layout:DesktopCandidateLayout) {
        guard candidateLayout != layout else{return}
        candidateLayout=layout
        navigationLocked=true;rankWork?.cancel();ranker?.cancel()
        candidateOffset=(selectedIndex/activeColumns)*activeColumns
        if expanded,rows.count<layout.pageSize {loadMoreCandidates()}
    }

    private func moveSelection(by delta:Int) {
        navigationLocked=true;rankWork?.cancel();ranker?.cancel()
        let next=selectedIndex+delta
        if next>=rows.count {loadMoreCandidates()}
        selectedIndex=max(0,min(max(0,rows.count-1),next))
        candidateOffset=(selectedIndex/activeColumns)*activeColumns
    }

    func choose(_ index: Int, client: MacInputClient) {
        let rows=engine.candidateBatch(offset:0,limit:max(36,index+1))
        guard let row=rows.first(where:{$0.index==index}) else{return}
        chooseCandidate(row,client:client)
    }

    func finishComposition(client: MacInputClient) {
        refreshPersonalEpoch();forgetCorrection()
        numericLiteralTail=""
        candidateOffset=0
        let pending = engine.takePendingInput()
        if !pending.isEmpty { client.insert(pending) }
    }

    func toggleEnglish(client: MacInputClient) {
        refreshPersonalEpoch();forgetCorrection()
        candidateOffset=0
        let next = !english
        let pending = engine.switchToEnglish(next)
        if !pending.isEmpty { client.insert(pending) }
        english = next
    }

    private func deliver(_ commit: String, client: MacInputClient) {
        if !commit.isEmpty { client.insert(commit) }
        // insertText ends the marked range. A second empty setMarkedText
        // would start a new replacement at the host's current selection.
        if !engine.preedit.isEmpty || commit.isEmpty { client.mark(engine.displayedPreedit(reading:""),cursor:engine.compositionCursorUTF16) }
    }
}
