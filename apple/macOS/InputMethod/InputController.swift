import AppKit
import Carbon
import InputMethodKit
import PrivateInputKit

private struct IMKClient: MacInputClient {
    let client: IMKTextInput
    let archiveSession: String?
    func insert(_ text:String) {
        let safe = !IsSecureEventInputEnabled()
        let sourceApp = safe ? client.bundleIdentifier() : nil
        client.insertText(text,replacementRange:NSRange(location:NSNotFound,length:0))
        guard let archiveSession else { return }
        ActivityArchiveCapture.shared.recordInput(text, sourceApp: sourceApp, document: nil,
                                                  session: archiveSession, epoch: UUID().uuidString,
                                                  safety: safe ? .safe : .secure)
    }
    func insertPair(_ text:String,caretBack:Int) {
        MacSymbolInsertion.insert(text,caretBack:caretBack,insert:insert,selection:{client.selectedRange()},read:{range in
            guard let value=client.attributedSubstring(from:range),value.length==range.length else{return nil}
            return value.string
        },placeCaret:{range in
            client.setMarkedText("",selectionRange:NSRange(location:0,length:0),replacementRange:range)
        })
    }
    func correctionAnchor(expectedSuffix:String)->MacInputAnchor? {
        guard !IsSecureEventInputEnabled() else{return nil}
        return MacInputAnchor.capture(document:String(describing:ObjectIdentifier(client as AnyObject)),selection:client.selectedRange(),marked:client.markedRange(),length:client.length(),expectedSuffix:expectedSuffix) { range in
            guard let value=client.attributedSubstring(from:range),value.length==range.length else{return nil};return value.string
        }
    }
    func surroundingText()->SurroundingText? {
        let selected=client.selectedRange(),marked=client.markedRange()
        guard selected.location != NSNotFound else{return nil}
        let length=client.length()
        guard let ranges=SurroundingText.ranges(selection:selected,marked:marked,length:length) else{return nil}
        func text(_ range:NSRange)->String? {
            if range.length==0 {return ""}
            guard let value=client.attributedSubstring(from:range),value.length<=range.length+2 else{return nil}
            return value.string
        }
        guard let before=text(ranges.before),let after=text(ranges.after) else{return nil}
        return SurroundingText(before:before,after:after)
    }
    func symbolPairContext()->SymbolPairing.EditContext? {
        guard !IsSecureEventInputEnabled() else{return nil}
        return MacSymbolInsertion.context(document:String(describing:ObjectIdentifier(client as AnyObject)),selection:client.selectedRange(),marked:client.markedRange(),length:client.length()) {range in
            guard let value=client.attributedSubstring(from:range),value.length==range.length else{return nil};return value.string
        }
    }
    func deleteSymbolPair(_ plan:SymbolPairing.DeletionPlan)->Bool {
        MacSymbolInsertion.delete(plan,context:symbolPairContext) {range in client.insertText("",replacementRange:range)}
    }
    func mark(_ text:String) {mark(text,cursor:text.utf16.count)}
    func mark(_ text:String,cursor:Int) {client.setMarkedText(text,selectionRange:NSRange(location:max(0,min(cursor,text.utf16.count)),length:0),replacementRange:NSRange(location:NSNotFound,length:0))}
}

/// Process-wide maintenance owns no IMK client or host text. Native work remains
/// serialized on main and starts only after all controllers stay hidden.
private final class MacHiddenCheckpointCoordinator {
    static let shared=MacHiddenCheckpointCoordinator()
    private var gate=MacHiddenCheckpointGate()
    private var scheduled:DispatchWorkItem?
    private var engine:NativeEngine?
    private let sourceReader=DispatchQueue(label:"live.linghe.privateinput.mac-focus-preflight",qos:.utility)
    private var completedRequest:LearningRefreshRequest?
    private var completedPolicy:Policy?
    private struct Policy:Equatable {
        let epoch:String,remember:Bool,sharing:Bool,day:Int
        var publisher:SnapshotPublisher? {remember && sharing ? .containingApp:nil}
    }
    private var policy:Policy {
        Policy(epoch:PersonalDataReset.generation,remember:KeyboardPreferences.rememberWords,
               sharing:UserDefaults(suiteName:LocalLearningCoordinator.groupID)?.bool(forKey:"learning-sharing-enabled")==true,
               day:Int(Date().timeIntervalSince1970/86400))
    }
    func activate(_ owner:UUID) {
        gate.activate(owner);scheduled?.cancel();scheduled=nil
        // Only invalidate queued work in the focus callback. A preflight's
        // temporary native session is retired after this callback returns.
        DispatchQueue.main.async { [weak self] in self?.retirePreparation() }
    }
    func changed() {gate.changed()}
    func deactivate(_ owner:UUID) {
        gate.deactivate(owner,now:ProcessInfo.processInfo.systemUptime)
        scheduled?.cancel();scheduled=nil
        guard gate.activeOwners.isEmpty else{return}
        let token=gate.ticket
        let work=DispatchWorkItem { [weak self] in self?.prepare(token) }
        scheduled=work;DispatchQueue.main.asyncAfter(deadline:.now()+gate.cooldown,execute:work)
    }
    func beforeRealInput() {
        scheduled?.cancel();scheduled=nil
        retirePreparation()
    }
    private func retirePreparation(_ expected:NativeEngine?=nil) {
        guard !gate.nativeRunning,let engine,expected==nil || expected === engine else{return}
        engine.finish();self.engine=nil
    }
    private func prepare(_ token:MacHiddenCheckpointGate.Ticket) {
        guard gate.canPrepare(token,now:ProcessInfo.processInfo.systemUptime,nativeSessions:Int(pi_active_session_count())),
              !IsSecureEventInputEnabled() else{return}
        scheduled=nil
        let context=policy
        if gate.dirty==gate.completedDirty,completedPolicy==context,let request=completedRequest {
            // Repeated empty focus must not construct/destroy a native engine
            // merely to discover that the external learning files are unchanged.
            sourceReader.async { [weak self] in
                let preparation=LearningRefreshReader.evaluate(request)
                DispatchQueue.main.async { [weak self] in
                    guard let self,self.gate.canPrepare(token,now:ProcessInfo.processInfo.systemUptime,nativeSessions:Int(pi_active_session_count())),
                          self.policy==context,!IsSecureEventInputEnabled(),
                          self.gate.needsCheckpoint(token,fingerprint:preparation.externalFingerprint,pending:preparation.pending) else{return}
                    self.startMaintenance(token,context:context)
                }
            }
        } else {startMaintenance(token,context:context)}
    }
    private func startMaintenance(_ token:MacHiddenCheckpointGate.Ticket,context:Policy) {
        guard gate.canPrepare(token,now:ProcessInfo.processInfo.systemUptime,nativeSessions:Int(pi_active_session_count())),policy==context else{return}
        // No original document/session/ranker survives deactivation. This
        // isolated maintenance engine is created outside either focus reply.
        let worker=NativeEngine(useSemantic:false,useLexicon:false)
        engine=worker
        guard worker.ready,pi_active_session_count()==1 else{retirePreparation(worker);return}
        _ = worker.privacy(!context.remember)
        worker.prepareLearningRefresh(publish:context.publisher) { [weak self,weak worker] preparation in
            guard let self,let worker else{return}
            guard self.engine === worker,self.gate.current(token),self.policy==context,
                  !IsSecureEventInputEnabled(),worker.isCurrentLearningRefreshPreparation(preparation,publish:context.publisher) else {
                self.retirePreparation(worker);return
            }
            guard self.gate.needsCheckpoint(token,fingerprint:preparation.externalFingerprint,pending:preparation.pending) else {
                self.retirePreparation(worker);return
            }
            worker.synchronizeLearningInBackground(publish: context.publisher, preparation: preparation,
                mayCommit: { [weak self, weak worker] in
                    guard let self, let worker else { return false }
                    return self.engine === worker && self.gate.current(token) && self.policy == context && !IsSecureEventInputEnabled()
                }, nativeWillBegin: { [weak self, weak worker] in
                    guard let self, let worker, self.engine === worker else { return false }
                    return self.gate.beginNative(token, nativeSessions: Int(pi_active_session_count()))
                }, nativeDidEnd: { [weak self] in self?.gate.endedNative() },
                completion: { [weak self, weak worker] result in
                    guard let self, let worker else { return }
                    if case .success(true) = result, self.engine === worker, self.gate.current(token), self.policy == context,
                       let after = worker.lastCompletedLearningPreparation,
                       worker.isCurrentLearningRefreshPreparation(after, publish: context.publisher), !after.pending {
                        self.gate.completed(token, fingerprint: after.externalFingerprint)
                        self.completedRequest = after.request; self.completedPolicy = context
                    }
                    self.retirePreparation(worker)
                })
        }
    }
}

@objc(PrivateInputController) final class PrivateInputController: IMKInputController {
    private static let acceptanceStorage: URL? = {
        #if PRIVATE_INPUT_DEVELOPMENT_DIAGNOSTICS
        if CommandLine.arguments.contains("--imk-acceptance") {
            return FileManager.default.temporaryDirectory.appendingPathComponent("PrivateInput-IMK-Acceptance-"+String(ProcessInfo.processInfo.processIdentifier),isDirectory:true)
        }
        #endif
        return nil
    }()
    private var input: MacInputSession?
    private var presented: [InputCandidate] = []
    // Keep system-owned placement for live IMK hosts. A client may return an
    // empty caret rectangle or omit optional geometry; typing must still show
    // candidates, just as the last known-good input service did.
    // IMK's server keeps an unretained pointer to the candidates object and
    // messages it while deactivating a stale controller after its host quits.
    // A per-controller instance dies with the controller and crashes there, so
    // one process-lifetime instance is shared; only the active controller uses it.
    private static var sharedCandidates:IMKCandidates?
    private var candidateWindow:IMKCandidates? { Self.sharedCandidates }
    private static let phraseNotice=MacPhraseNotice()
    private func autoPhraseCommitted(phrase:String,reading:String,session:MacInputSession) {
        let generation=focusGeneration
        DispatchQueue.global(qos:.utility).async { [weak self,weak session] in
            let status=NativeEngine.autoPhraseStatus(phrase)
            DispatchQueue.main.async {
                guard status==2,let self,let session,self.activated,self.focusGeneration==generation,self.input===session,
                      NativeEngine.firstAutoPhraseAnnouncement(phrase,reading),let client=self.liveClient() else{return}
                var caret=NSRect.zero
                guard PIReadIMKCaret(client,&caret) else{return}
                Self.phraseNotice.show(phrase:phrase,caret:caret) { [weak session] in session?.engine.forgetAutoPhrase(text:phrase,reading:reading) ?? false }
            }
        }
    }
    private let candidatePanel=MacCandidatePanel()
    private var activeClient:IMKTextInput?
    private var preferenceObserver:NSObjectProtocol?
    private var geometryTimer:Timer?
    private var archiveSession: String? = CommandLine.arguments.contains("--imk-acceptance") ? nil : UUID().uuidString
    private var archiveReportedPassthrough = false
    private let focusOwner=UUID()
    private var focusGeneration:UInt64=0
    private var activated=false
    override init!(server:IMKServer!,delegate:Any!,client inputClient:Any!) {
        super.init(server:server,delegate:delegate,client:inputClient);trace("controller-init")
        activeClient=inputClient as? IMKTextInput
        if Self.sharedCandidates==nil {
            Self.sharedCandidates=IMKCandidates(server:server,panelType:kIMKSingleRowSteppingCandidatePanel)
            Self.sharedCandidates?.setAttributes([IMKCandidatesSendServerKeyEventFirst as String:true])
        }
        preferenceObserver=NotificationCenter.default.addObserver(forName:KeyboardPreferences.updated,object:nil,queue:.main) { [weak self] _ in
            guard let self,let input=self.input else{return}
            input.applyCandidateLayout(KeyboardPreferences.desktopCandidateLayout);self.updateCandidates()
        }
        candidatePanel.choose={ [weak self] row in
            guard let self,self.activated,let client=self.liveClient() else{return}
            guard let input=self.input else{return}
            input.chooseCandidate(row,client:IMKClient(client:client,archiveSession:self.archiveSession));self.updateCandidates()
            if Self.acceptanceStorage==nil {MacHiddenCheckpointCoordinator.shared.changed()}
        }
        candidatePanel.managementMenu={ [weak self] row in
            guard let self,let input=self.input else{return nil}
            return input.managementMenu(for:row) { [weak self] in
                if Self.acceptanceStorage==nil {MacHiddenCheckpointCoordinator.shared.changed()}
                self?.updateCandidates()
            }
        }
        candidatePanel.highlight={ [weak self] row in self?.input?.highlightCandidate(row) }
        candidatePanel.toggle={ [weak self] in self?.input?.toggleExpanded();self?.updateCandidates() }
        candidatePanel.loadMore={ [weak self] in
            guard let self,let input=self.input else{return};let count=input.allCandidateRows.count;input.loadMoreCandidates()
            if count != input.allCandidateRows.count {self.updateCandidates()}
        }
    }
    private func liveClient()->IMKTextInput? {(client() as? IMKTextInput) ?? activeClient}
    private func activeInput() -> MacInputSession {
        if let input { return input }
        if Self.acceptanceStorage==nil {MacHiddenCheckpointCoordinator.shared.beforeRealInput()}
        let value=MacInputSession(engine:NativeEngine(storageBase:Self.acceptanceStorage,mixedEnglishProvider:MacEnglishDictionary.completions));input=value
        value.autoPhraseCommitted={ [weak self,weak value] phrase,reading in if let self,let value {self.autoPhraseCommitted(phrase:phrase,reading:reading,session:value)} }
        let generation=focusGeneration
        value.candidatesChanged={ [weak self,weak value] in
            guard let self,let value,self.activated,self.focusGeneration==generation,self.input === value else{return}
            self.updateCandidates()
        }
        _ = value.engine.privacy(Self.acceptanceStorage != nil || !KeyboardPreferences.rememberWords)
        _ = value.engine.setMixedEnglishEnabled(KeyboardPreferences.mixedEnglish)
        if KeyboardPreferences.startInEnglish,let client=liveClient() { value.toggleEnglish(client:IMKClient(client:client,archiveSession:archiveSession)) }
        return value
    }
    private func checkpoint(_ input:MacInputSession) {
        MacHiddenCheckpointCoordinator.shared.changed()
    }
    private func trace(_ event:String) {
        // Explicit synthetic acceptance mode; no key, host or candidate content.
        if CommandLine.arguments.contains("--imk-acceptance") { NSLog("PRIVATE_INPUT_IMK %@",event) }
    }
    override func inputText(_ string:String!,key keyCode:Int,modifiers flags:Int,client sender:Any!) -> Bool {
        if Self.phraseNotice.phrase != nil {
            // The first key after a remembered phrase being Delete means it was a
            // typo or a wrong pick: forget it like the explicit undo (key still deletes).
            if keyCode==51,flags & Int(NSEvent.ModifierFlags([.command,.control,.option,.shift]).rawValue)==0 {Self.phraseNotice.rejectByDelete()}
            else {Self.phraseNotice.hide()}
        }
        guard let client=sender as? IMKTextInput else { return false }
        if let activeClient,ObjectIdentifier(activeClient as AnyObject) != ObjectIdentifier(client as AnyObject) {input?.invalidateCorrection()}
        activeClient=client
        if !activated {activated=true;focusGeneration &+= 1;if Self.acceptanceStorage==nil {MacHiddenCheckpointCoordinator.shared.activate(focusOwner)}}
        // An empty session must not initialize Rime just for a host shortcut.
        if self.input==nil,flags & Int(NSEvent.ModifierFlags([.command,.control,.option]).rawValue) != 0 {return false}
        let input=activeInput()
        if input.engine.preedit.isEmpty { _ = input.engine.privacy(Self.acceptanceStorage != nil || !KeyboardPreferences.rememberWords);_ = input.engine.setMixedEnglishEnabled(KeyboardPreferences.mixedEnglish) }
        let archiveEnabled = archiveSession != nil && ActivityArchiveCapture.shared.permits("ime.commit.v1")
        let preeditBeforeEmpty = input.engine.preedit.isEmpty
        let hostMarkedBefore = archiveEnabled && client.markedRange().location != NSNotFound
        let output = MacArchiveMutationTrackingClient(base: IMKClient(client:client,archiveSession:archiveSession))
        let diagnosticBefore=ActivityArchiveCapture.shared.permits(ActivityInputDiagnostic.provider) ? input.engine.rawInput : ""
        defer {
            if let archiveSession, !IsSecureEventInputEnabled(),
               flags & Int(NSEvent.ModifierFlags([.command,.control,.option]).rawValue)==0 {
                ActivityArchiveCapture.shared.recordDiagnostic(action:keyCode==51 ? "delete":"key",key:string ?? "keycode:\(keyCode)",
                    before:diagnosticBefore,after:input.engine.rawInput,sourceApp:client.bundleIdentifier(),document:nil,
                    session:archiveSession,epoch:archiveSession,safety:.safe)
            }
        }
        var handled=input.input(string,keyCode:keyCode,flags:flags,client:output)
        let state = MacArchiveEnglishInsertion.State(archiveEnabled: archiveEnabled,
            secureInput: IsSecureEventInputEnabled(), english: input.english, sessionHandled: handled,
            preeditBeforeEmpty: preeditBeforeEmpty, preeditAfterEmpty: input.engine.preedit.isEmpty,
            insertedDuringSession: output.inserted, markedDuringSession: output.marked,
            hostMarkedBefore: hostMarkedBefore, hostMarkedAfter: archiveEnabled && client.markedRange().location != NSNotFound)
        if MacArchiveEnglishInsertion.insertIfEligible(string, keyCode:keyCode, flags:flags, state:state, insert:output.insert) {
            handled = true
        }
        // Native passthrough has no insert confirmation. Preserve that input path;
        // emit one empty coverage marker instead of turning key events into text logs.
        if !handled, input.english, !archiveReportedPassthrough, let archiveSession,
           flags & Int(NSEvent.ModifierFlags([.command,.control,.option]).rawValue) == 0,
           !IsSecureEventInputEnabled(), ActivityArchiveCapture.shared.permits("ime.commit.v1") {
            archiveReportedPassthrough = true
            ActivityArchiveCapture.shared.recordHostPassthroughGap(sourceApp: client.bundleIdentifier(), session: archiveSession)
        }
        if handled { trace("handled");if Self.acceptanceStorage==nil,KeyboardPreferences.rememberWords,!IsSecureEventInputEnabled() {MacHiddenCheckpointCoordinator.shared.changed()} };updateCandidates();return handled
    }
    private func updateCandidates() {
        guard activated else {geometryTimer?.invalidate();geometryTimer=nil;candidateWindow?.hide();candidatePanel.hide();return}
        if let input {
            input.applyCandidateLayout(KeyboardPreferences.desktopCandidateLayout)
            presented=input.allCandidateRows
        } else {presented=[]}
        guard !presented.isEmpty else {geometryTimer?.invalidate();geometryTimer=nil;candidateWindow?.hide();candidatePanel.hide();return}
        refreshCandidatePosition(reload:true)
        if geometryTimer==nil {
            let timer=Timer(timeInterval:0.15,repeats:true) { [weak self] _ in self?.refreshCandidatePosition(reload:false) }
            geometryTimer=timer;RunLoop.main.add(timer,forMode:.common)
        }
    }
    private func refreshCandidatePosition(reload:Bool) {
        guard activated,input?.engine.preedit.isEmpty == false else {geometryTimer?.invalidate();geometryTimer=nil;candidatePanel.hide();candidateWindow?.hide();return}
        var caret=NSRect.zero
        let located=liveClient().map{PIReadIMKCaret($0,&caret)} ?? false
        if located {
            if reload || !candidatePanel.isVisible {
                candidatePanel.show(items:presented,selected:input?.selectedIndex ?? 0,offset:input?.candidateOffset ?? 0,expanded:input?.expanded == true,caret:caret,layout:input?.candidateLayout ?? KeyboardPreferences.desktopCandidateLayout)
            } else {candidatePanel.reposition(caret:caret)}
        } else {candidatePanel.hide()}
        if candidatePanel.isVisible {candidateWindow?.hide()}
        else if let input {
            // The OS can place its own candidates even when a client omits
            // optional geometry. Never strand a custom panel at an old point.
            candidateWindow?.setSelectionKeys(Array([18,19,20,21,23,22,26,28,25].prefix(input.candidateLayout.collapsedCount)))
            if reload || candidateWindow?.isVisible() != true {
                candidateWindow?.update();candidateWindow?.show(kIMKLocateCandidatesBelowHint)
                if let selected=input.highlightedCandidate,let id=candidateWindow?.candidateStringIdentifier(selected.text),id != NSNotFound {_ = candidateWindow?.selectCandidate(withIdentifier:id)}
            }
        }
    }
    deinit {geometryTimer?.invalidate();if let preferenceObserver {NotificationCenter.default.removeObserver(preferenceObserver)};if Self.acceptanceStorage==nil {MacHiddenCheckpointCoordinator.shared.deactivate(focusOwner)}}
    override func candidateSelectionChanged(_ candidateString:NSAttributedString!) {
        // The session owns arrow/number selection. Native panel refreshes can
        // publish an old first-row highlight asynchronously; never let that
        // overwrite the user's current index. Mouse clicks commit by identity
        // through candidateSelected instead.
    }
    override func activateServer(_ sender:Any!) { super.activateServer(sender);activated=true;focusGeneration &+= 1
        if Self.acceptanceStorage==nil {MacHiddenCheckpointCoordinator.shared.activate(focusOwner)}
        archiveSession = Self.acceptanceStorage == nil ? UUID().uuidString : nil; archiveReportedPassthrough = false;trace("activate")
        let generation=focusGeneration
        // Never query the host's caret or initialize the engine while that host
        // is synchronously waiting for this activation callback to return.
        DispatchQueue.main.async { [weak self] in
            guard let self,self.activated,self.focusGeneration==generation else{return}
            ActivityArchiveCapture.shared.refresh(permitted:Self.acceptanceStorage == nil)
            guard Self.acceptanceStorage==nil,!IsSecureEventInputEnabled() else{return}
            self.updateCandidates()
        }
    }
    override func candidates(_ sender:Any!) -> [Any]! { presented.map(\.text) }
    override func composedString(_ sender:Any!) -> Any! { input?.engine.preedit ?? "" }
    override func originalString(_ sender:Any!) -> NSAttributedString! { NSAttributedString(string:input?.engine.rawInput ?? "") }
    override func commitComposition(_ sender:Any!) {
        guard let input,let client=(sender as? IMKTextInput) ?? liveClient() else { return }
        input.finishComposition(client:IMKClient(client:client,archiveSession:archiveSession));presented=[];geometryTimer?.invalidate();geometryTimer=nil;candidateWindow?.hide();candidatePanel.hide()
    }
    override func menu() -> NSMenu! {
        let menu=NSMenu()
        // The system input menu forwards commands through IMK, rather than
        // AppKit's local responder chain. Preserve the explicit states below.
        menu.autoenablesItems=false
        let mode=NSMenuItem(title:"英文输入",action:#selector(toggleEnglish(_:)),keyEquivalent:"");mode.target=self;mode.state=input?.english == true ? .on:.off;menu.addItem(mode)
        let learning=NSMenuItem(title:"更新词库",action:#selector(refreshLearning(_:)),keyEquivalent:"");learning.target=self;learning.isEnabled=input?.engine.ready == true && input?.engine.preedit.isEmpty == true;menu.addItem(learning)
        for (title,action) in [("剪贴板同步…",#selector(openSharedText(_:))),("个人词库…",#selector(openLexicon(_:))),("输入设置…",#selector(openSettings(_:)))] {
            let item=NSMenuItem(title:title,action:action,keyEquivalent:"");item.target=self;menu.addItem(item)
        }
        let help=NSMenuItem(title:"候选词频用法…",action:#selector(frequencyHelp(_:)),keyEquivalent:"");help.target=self;menu.addItem(help)
        return menu
    }
    @objc private func frequencyHelp(_ sender:Any?) {
        input?.invalidateCorrection()
        DispatchQueue.main.async {
            let alert=NSAlert();alert.messageText="调整候选词频"
            alert.informativeText="在候选词上点右键，可置顶、取消置顶或恢复默认词频。恢复默认词频会保留手动置顶。\n\n刚误选的词整段删除后，在同一输入框重新输入并选择另一个同音词，会学习这次纠正。仅删除或重复输入不会作为纠正。"
            alert.addButton(withTitle:"好");alert.runModal()
        }
    }
    // IMKInputController.doCommand(by:command:) calls each action with the
    // command dictionary (kIMKCommandMenuItemName / kIMKCommandClientName).
    // Match the documented one-argument Objective-C action signature.
    @objc private func openSettings(_ sender:Any?) { trace("menu-input");DispatchQueue.main.async { DeviceSyncWindow.shared.show(.input) } }
    @objc private func openSharedText(_ sender:Any?) { trace("menu-shared-text");DispatchQueue.main.async { DeviceSyncWindow.shared.show(.sharedText) } }
    @objc private func openLexicon(_ sender:Any?) { trace("menu-lexicon");DispatchQueue.main.async { DeviceSyncWindow.shared.show(.lexicon) } }
    @objc private func toggleEnglish(_ sender:Any?) {
        guard let client=liveClient() else { return }
        activeInput().toggleEnglish(client:IMKClient(client:client,archiveSession:archiveSession));presented=[];geometryTimer?.invalidate();geometryTimer=nil;candidateWindow?.hide();candidatePanel.hide()
    }
    @objc private func refreshLearning(_ sender:Any?) { if let input { checkpoint(input) } }
    override func candidateSelected(_ candidateString:NSAttributedString!) {
        guard activated,let candidateString,let row=presented.first(where:{$0.text==candidateString.string}),let client=liveClient() else { return }
        guard let input else{return}
        input.chooseCandidate(row,client:IMKClient(client:client,archiveSession:archiveSession));updateCandidates()
        if Self.acceptanceStorage==nil {MacHiddenCheckpointCoordinator.shared.changed()}
    }
    override func deactivateServer(_ sender:Any!) {
        Self.phraseNotice.hide()
        activated=false;focusGeneration &+= 1
        commitComposition(sender)
        if let input {input.engine.finish()}
        // Inactive IMK controllers must not keep Rime sessions alive and block
        // the quiescent checkpoint required for cross-device learning imports.
        input=nil;activeClient=nil;presented=[];geometryTimer?.invalidate();geometryTimer=nil;candidateWindow?.hide();candidatePanel.hide();trace("deactivate");super.deactivateServer(sender)
        if Self.acceptanceStorage==nil {MacHiddenCheckpointCoordinator.shared.deactivate(focusOwner)}
    }
}
