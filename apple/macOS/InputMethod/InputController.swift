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
    func mark(_ text:String) {mark(text,cursor:text.utf16.count)}
    func mark(_ text:String,cursor:Int) {client.setMarkedText(text,selectionRange:NSRange(location:max(0,min(cursor,text.utf16.count)),length:0),replacementRange:NSRange(location:NSNotFound,length:0))}
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
    private var candidateWindow:IMKCandidates?
    private let candidatePanel=MacCandidatePanel()
    private var activeClient:IMKTextInput?
    private var preferenceObserver:NSObjectProtocol?
    private var geometryTimer:Timer?
    private var clipboardTimer:Timer?
    private var clipboardItem:MacClipboardSuggestion.Item?
    private var archiveSession: String? = CommandLine.arguments.contains("--imk-acceptance") ? nil : UUID().uuidString
    private var archiveReportedPassthrough = false
    override init!(server:IMKServer!,delegate:Any!,client inputClient:Any!) {
        super.init(server:server,delegate:delegate,client:inputClient);trace("controller-init")
        activeClient=inputClient as? IMKTextInput
        candidateWindow=IMKCandidates(server:server,panelType:kIMKSingleRowSteppingCandidatePanel)
        candidateWindow?.setAttributes([IMKCandidatesSendServerKeyEventFirst as String:true])
        preferenceObserver=NotificationCenter.default.addObserver(forName:KeyboardPreferences.updated,object:nil,queue:.main) { [weak self] _ in
            guard let self,let input=self.input else{return}
            input.applyCandidateLayout(KeyboardPreferences.desktopCandidateLayout);self.updateCandidates()
        }
        candidatePanel.choose={ [weak self] row in
            guard let self,let input=self.input,let client=self.liveClient() else{return}
            if row.index == -2 {guard row.generation==self.clipboardItem?.version else{return};self.pasteClipboard(client:client);return}
            input.chooseCandidate(row,client:IMKClient(client:client,archiveSession:self.archiveSession));self.updateCandidates()
        }
        candidatePanel.managementMenu={ [weak self] row in
            guard let self,let input=self.input else{return nil}
            return input.managementMenu(for:row) { [weak self] in self?.updateCandidates() }
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
        let value=MacInputSession(engine:NativeEngine(storageBase:Self.acceptanceStorage,mixedEnglishProvider:MacEnglishDictionary.completions));input=value
        value.candidatesChanged={ [weak self] in self?.updateCandidates() }
        _ = value.engine.privacy(Self.acceptanceStorage != nil || !KeyboardPreferences.rememberWords)
        _ = value.engine.setMixedEnglishEnabled(KeyboardPreferences.mixedEnglish)
        if KeyboardPreferences.startInEnglish,let client=liveClient() { value.toggleEnglish(client:IMKClient(client:client,archiveSession:archiveSession)) }
        checkpoint(value)
        return value
    }
    private func checkpoint(_ input:MacInputSession) {
        guard input.engine.preedit.isEmpty else { return }
        let sharing=UserDefaults(suiteName:LocalLearningCoordinator.groupID)?.bool(forKey:"learning-sharing-enabled") == true
        do { try input.engine.synchronizeLearning(publish:Self.acceptanceStorage == nil && sharing && KeyboardPreferences.rememberWords ? .containingApp:nil) }
        catch { trace("checkpoint-deferred") }
    }
    private func trace(_ event:String) {
        // Explicit synthetic acceptance mode; no key, host or candidate content.
        if CommandLine.arguments.contains("--imk-acceptance") { NSLog("PRIVATE_INPUT_IMK %@",event) }
    }
    override func inputText(_ string:String!,key keyCode:Int,modifiers flags:Int,client sender:Any!) -> Bool {
        guard let client=sender as? IMKTextInput else { return false }
        activeClient=client
        let input=activeInput()
        if input.engine.preedit.isEmpty,clipboardItem != nil {
            if keyCode==51,candidatePanel.isVisible,flags & Int(NSEvent.ModifierFlags([.command,.control,.option]).rawValue)==0 {
                dismissClipboard();updateCandidates();return true
            }
            // Clipboard suggestions are explicit mouse targets. Space, digits,
            // navigation and new typing must retain their normal meanings.
            dismissClipboard()
        }
        if input.engine.preedit.isEmpty { _ = input.engine.privacy(Self.acceptanceStorage != nil || !KeyboardPreferences.rememberWords);_ = input.engine.setMixedEnglishEnabled(KeyboardPreferences.mixedEnglish) }
        let archiveEnabled = archiveSession != nil && ActivityArchiveCapture.shared.permits("ime.commit.v1")
        let preeditBeforeEmpty = input.engine.preedit.isEmpty
        let hostMarkedBefore = archiveEnabled && client.markedRange().location != NSNotFound
        let output = MacArchiveMutationTrackingClient(base: IMKClient(client:client,archiveSession:archiveSession))
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
        if handled { trace("handled") };updateCandidates();return handled
    }
    private func updateCandidates() {
        guard let input else {geometryTimer?.invalidate();geometryTimer=nil;candidateWindow?.hide();candidatePanel.hide();return}
        if input.engine.preedit.isEmpty,input.engine.managementPending {checkpoint(input)}
        input.applyCandidateLayout(KeyboardPreferences.desktopCandidateLayout)
        presented=input.allCandidateRows
        if input.engine.preedit.isEmpty,let item=MacClipboardSuggestion.shared.current() {
            clipboardItem=item
            presented=[InputCandidate(text:item.preview,comment:"",index:-2,generation:item.version)]
        } else {clipboardItem=nil}
        guard !presented.isEmpty else {geometryTimer?.invalidate();geometryTimer=nil;candidateWindow?.hide();candidatePanel.hide();return}
        refreshCandidatePosition(reload:true)
        if geometryTimer==nil {
            let timer=Timer(timeInterval:0.15,repeats:true) { [weak self] _ in self?.refreshCandidatePosition(reload:false) }
            geometryTimer=timer;RunLoop.main.add(timer,forMode:.common)
        }
    }
    private func refreshCandidatePosition(reload:Bool) {
        guard let input,!input.engine.preedit.isEmpty || clipboardItem != nil else {geometryTimer?.invalidate();geometryTimer=nil;candidatePanel.hide();candidateWindow?.hide();return}
        if let item=clipboardItem, NSPasteboard.general.changeCount != item.version || !MacClipboardSuggestion.permitted || IsSecureEventInputEnabled() {
            clipboardItem=nil;presented=[];candidatePanel.hide();candidateWindow?.hide();return
        }
        var caret=NSRect.zero
        let located=liveClient().map{PIReadIMKCaret($0,&caret)} ?? false
        if located {
            if reload || !candidatePanel.isVisible {
                candidatePanel.show(items:presented,selected:clipboardItem == nil ? input.selectedIndex:-1,offset:clipboardItem == nil ? input.candidateOffset:0,expanded:clipboardItem == nil && input.expanded,caret:caret,layout:input.candidateLayout,clipboard:clipboardItem != nil)
            } else {candidatePanel.reposition(caret:caret)}
        } else {candidatePanel.hide()}
        if candidatePanel.isVisible {candidateWindow?.hide()}
        else if clipboardItem != nil {candidateWindow?.hide()}
        else if clipboardItem == nil {
            // The OS can place its own candidates even when a client omits
            // optional geometry. Never strand a custom panel at an old point.
            candidateWindow?.setSelectionKeys(Array([18,19,20,21,23,22,26,28,25].prefix(input.candidateLayout.collapsedCount)))
            if reload || candidateWindow?.isVisible() != true {
                candidateWindow?.update();candidateWindow?.show(kIMKLocateCandidatesBelowHint)
                if let selected=input.highlightedCandidate,let id=candidateWindow?.candidateStringIdentifier(selected.text),id != NSNotFound {_ = candidateWindow?.selectCandidate(withIdentifier:id)}
            }
        }
    }
    private func dismissClipboard() {
        if let item=clipboardItem {MacClipboardSuggestion.shared.dismiss(version:item.version)}
        clipboardItem=nil
    }
    private func pasteClipboard(client:IMKTextInput) {
        let originalSession=archiveSession,selection=client.selectedRange()
        guard let item=clipboardItem,let originalInput=input,originalInput.engine.preedit.isEmpty,
              let text=MacClipboardSuggestion.shared.paste(item),clipboardItem==item,input === originalInput,
              archiveSession==originalSession,client.selectedRange()==selection,
              liveClient().map({ObjectIdentifier($0 as AnyObject)==ObjectIdentifier(client as AnyObject)}) == true else {updateCandidates();return}
        input?.invalidateCorrection();clipboardItem=nil
        let app=client.bundleIdentifier()
        client.insertText(text,replacementRange:NSRange(location:NSNotFound,length:0))
        if let archiveSession {ActivityArchiveCapture.shared.recordSystemPaste(text,sourceApp:app,document:nil,session:archiveSession,epoch:UUID().uuidString,safety:.safe)}
        updateCandidates()
    }
    deinit {geometryTimer?.invalidate();clipboardTimer?.invalidate();if let preferenceObserver {NotificationCenter.default.removeObserver(preferenceObserver)}}
    override func candidateSelectionChanged(_ candidateString:NSAttributedString!) {
        // The session owns arrow/number selection. Native panel refreshes can
        // publish an old first-row highlight asynchronously; never let that
        // overwrite the user's current index. Mouse clicks commit by identity
        // through candidateSelected instead.
    }
    override func activateServer(_ sender:Any!) { super.activateServer(sender); archiveSession = Self.acceptanceStorage == nil ? UUID().uuidString : nil; archiveReportedPassthrough = false; ActivityArchiveCapture.shared.refresh(permitted:Self.acceptanceStorage == nil); _ = activeInput();trace("activate")
        clipboardTimer?.invalidate()
        if Self.acceptanceStorage == nil {
            let timer=Timer(timeInterval:1,repeats:true) { [weak self] _ in
                guard let self,self.input?.engine.preedit.isEmpty == true else{return}
                let previous=self.clipboardItem
                let next=MacClipboardSuggestion.shared.current()
                if previous != next {self.updateCandidates()}
            }
            clipboardTimer=timer;RunLoop.main.add(timer,forMode:.common);updateCandidates()
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
        for (title,action) in [("共享文本…",#selector(openSharedText(_:))),("个人词库…",#selector(openLexicon(_:))),("输入设置…",#selector(openSettings(_:)))] {
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
        guard let candidateString,let row=presented.first(where:{$0.text==candidateString.string}),let input,let client=liveClient() else { return }
        if row.index == -2 {guard row.generation==clipboardItem?.version else{return};pasteClipboard(client:client);return}
        input.chooseCandidate(row,client:IMKClient(client:client,archiveSession:archiveSession));updateCandidates()
    }
    override func deactivateServer(_ sender:Any!) {
        clipboardTimer?.invalidate();clipboardTimer=nil;clipboardItem=nil
        commitComposition(sender)
        if let input { checkpoint(input);input.engine.finish() }
        // Inactive IMK controllers must not keep Rime sessions alive and block
        // the quiescent checkpoint required for cross-device learning imports.
        input=nil;activeClient=nil;presented=[];geometryTimer?.invalidate();geometryTimer=nil;candidateWindow?.hide();candidatePanel.hide();trace("deactivate");super.deactivateServer(sender)
    }
}
