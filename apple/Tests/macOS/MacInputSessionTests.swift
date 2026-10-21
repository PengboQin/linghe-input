import AppKit
import XCTest
import PrivateInputKit

private struct TextViewClient: MacInputClient {
    let view: NSTextView
    var permitsCorrectionAnchor=true
    func correctionAnchor(expectedSuffix:String)->MacInputAnchor? {
        guard permitsCorrectionAnchor else{return nil}
        return MacInputAnchor.capture(document:String(describing:ObjectIdentifier(view)),selection:view.selectedRange(),marked:view.markedRange(),length:(view.string as NSString).length,expectedSuffix:expectedSuffix) { range in
            (view.string as NSString).substring(with:range)
        }
    }
    func insert(_ text: String) {
        view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    func mark(_ text:String,cursor:Int) {
        view.setMarkedText(text,selectedRange:NSRange(location:cursor,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
    }
    func mark(_ text: String) {
        view.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    }
}

final class MacInputSessionTests: XCTestCase {
    func testOptInLearningCheckpointGateReusesOnlyUnchangedNativeAndSources() throws {
        let engine=try engine();defer{engine.clear();engine.finish()}
        _ = engine.privacy(false);_ = engine.nineKey(false)
        func prepare()->LearningRefreshPreparation {
            let done=expectation(description:"Utility source token then main completion")
            var result:LearningRefreshPreparation?
            engine.prepareLearningRefresh(publish:nil) { value in
                XCTAssertTrue(Thread.isMainThread);result=value;done.fulfill()
            }
            wait(for:[done],timeout:5)
            return result!
        }
        let first=prepare();try engine.synchronizeLearning(preparation:first)
        XCTAssertFalse(engine.learningRefreshWasSkipped,"First native export must run")
        let clean=prepare();try engine.synchronizeLearning(preparation:clean)
        XCTAssertTrue(engine.learningRefreshWasSkipped,"Exact clean source/native generation can reuse")
        let count=engine.learningCheckpointRuns
        for key in "nihao".utf8 {_ = engine.key(Int32(key))}
        let row=try XCTUnwrap(engine.candidateBatch(offset:0,limit:32).first{$0.text=="你好"})
        XCTAssertEqual(engine.chooseCandidate(row),"你好")
        let dirty=prepare();try engine.synchronizeLearning(preparation:dirty)
        XCTAssertFalse(engine.learningRefreshWasSkipped,"Real new native selection cannot be skipped")
        XCTAssertEqual(engine.learningCheckpointRuns,count+1)
        let after=prepare();try engine.synchronizeLearning(preparation:after)
        XCTAssertTrue(engine.learningRefreshWasSkipped)
        try engine.synchronizeLearning()
        XCTAssertFalse(engine.learningRefreshWasSkipped,"Legacy/default Mac call remains a real checkpoint")
    }

    func testNineCommonCrossSyllablePrefixDoesNotGetTrappedInShortExactParse() throws {
        let engine=try engine();defer{engine.clear();engine.finish()}
        _ = engine.privacy(true);_ = engine.nineKey(true)
        for code in ["5468","54684","546842","5468426"] {
            engine.clear();for key in code.utf8 {_ = engine.key(Int32(key))}
            let rows=engine.candidateBatch(offset:0,limit:64)
            print("SYNTHETIC_NINE_PREFIX code=\(code) head=\(rows.prefix(8).map(\.text))")
            let today=try XCTUnwrap(rows.first{$0.text=="今天"},code)
            XCTAssertEqual(rows.first?.text,"今天",code)
            if code=="5468" {XCTAssertTrue(rows.contains{$0.text=="妓女"},"A legitimate alternate reading is retained")}
            XCTAssertEqual(engine.rawInput,code,"Completion lookup never edits the actual keys")
            XCTAssertEqual(engine.chooseCandidate(today),"今天");XCTAssertTrue(engine.rawInput.isEmpty)
            XCTAssertEqual(engine.chooseCandidate(today),"","A completion commits exactly once")
        }
        for (code,head,required) in [("968","有","有"),("6364","能","梦"),("6664","弄","农")] {
            engine.clear();for key in code.utf8 {_ = engine.key(Int32(key))}
            let rows=engine.candidateBatch(offset:0,limit:64)
            XCTAssertEqual(rows.first?.text,head,code);XCTAssertTrue(rows.contains{$0.text==required},code)
            XCTAssertEqual(engine.rawInput,code,"Repeated digits are independent keys, never debounce-collapsed")
        }
    }
    func testIncompleteLongSentenceKeepsFullNativeTextAndSingleCommit() throws {
        let engine=try engine();defer{engine.clear();engine.finish()};_ = engine.privacy(true);_ = engine.nineKey(false)
        for raw in ["woxiangwanqul","woxiangwanqule"] {
            engine.clear();let input=MacInputSession(engine:engine),host=view(""),client=TextViewClient(view:host)
            type(raw,into:input,client:client)
            let row=try XCTUnwrap(input.allCandidateRows.first{$0.text=="我想玩去了"},raw)
            input.chooseCandidate(row,client:client)
            XCTAssertEqual(host.string,"我想玩去了");XCTAssertFalse(host.hasMarkedText())
            XCTAssertTrue(engine.rawInput.isEmpty);XCTAssertEqual(engine.chooseCandidate(row),"")
        }
    }
    func testMacFrequencyCorrectionUsesVerifiedNativeDeletionAndDifferentChoice() throws {
        try runMacFrequencyScenario("correction",expectsCorrection:true)
        try runMacFrequencyScenario("pinned",expectsCorrection:true)
    }
    func testMacFrequencyCorrectionProtections() throws {
        for scenario in ["same-word","delete-only","missing-delete","partial","moved","selection","other-field","timeout","undo","private","anchorless","unrelated","retype-move"] {
            try runMacFrequencyScenario(scenario,expectsCorrection:false)
        }
    }
    private func runMacFrequencyScenario(_ scenario:String,expectsCorrection:Bool)throws {
        try FileManager.default.createDirectory(at:Self.storage,withIntermediateDirectories:true)
        let file=Self.storage.appendingPathComponent("nine-choice-memory-v3.json"),saved=try? Data(contentsOf:file)
        defer {if let saved {try? saved.write(to:file,options:.atomic)} else {try? FileManager.default.removeItem(at:file)}}
        var prior=NineKeyChoiceMemory()
        for _ in 0..<8 {try prior.record(code:"64426",reading:"ni hao",text:"拟好",context:"",strength:3)}
        try JSONEncoder().encode(prior).write(to:file,options:.atomic)
        let engine=try engine();defer{engine.clear();engine.finish()};_ = engine.privacy(scenario=="private");_ = engine.nineKey(false)
        var time:TimeInterval=100
        let input=MacInputSession(engine:engine,now:{time}),host=view("合成前文：后文")
        host.setSelectedRange(NSRange(location:5,length:0))
        var client=TextViewClient(view:host,permitsCorrectionAnchor:scenario != "anchorless")
        type("nihao",into:input,client:client)
        var a=try XCTUnwrap(input.allCandidateRows.first{$0.text=="拟好"},scenario)
        if scenario=="pinned" {try engine.manage(a,pinned:true);a=try XCTUnwrap(input.allCandidateRows.first{$0.text=="拟好"})}
        defer {if scenario=="pinned" {engine.clear();try? engine.manage(a,pinned:false)}}
        if scenario != "private" {XCTAssertEqual(input.allCandidateRows.first?.text,"拟好",scenario)}
        input.chooseCandidate(a,client:client)
        XCTAssertFalse(host.hasMarkedText());XCTAssertTrue(host.string.contains("拟好"))
        let afterA=try Data(contentsOf:file)
        func configureEmptyComposition() {
            if engine.preedit.isEmpty {_ = engine.privacy(scenario=="private");_ = engine.setMixedEnglishEnabled(KeyboardPreferences.mixedEnglish)}
        }
        func backspace(actuallyDelete:Bool=true) {
            configureEmptyComposition()
            XCTAssertFalse(input.input(nil,keyCode:51,flags:0,client:client),scenario)
            if actuallyDelete {host.deleteBackward(nil)}
        }
        if scenario=="moved" {host.setSelectedRange(NSRange(location:0,length:0))}
        if scenario=="selection" {host.setSelectedRange(NSRange(location:5,length:2))}
        if scenario=="other-field" {client=TextViewClient(view:view("合成前文：拟好后文"));client.view.setSelectedRange(NSRange(location:7,length:0))}
        if scenario=="timeout" {time=111}
        if scenario=="undo" {_ = input.input("z",keyCode:6,flags:Int(NSEvent.ModifierFlags.command.rawValue),client:client)}
        if scenario != "moved",scenario != "selection",scenario != "other-field" {
            backspace(actuallyDelete:scenario != "missing-delete")
            if scenario != "partial" {backspace(actuallyDelete:scenario != "missing-delete")}
        }
        if scenario=="delete-only" {XCTAssertEqual(try Data(contentsOf:file),afterA);return}
        let spelling=scenario=="unrelated" ? "shijie":"nihao"
        for letter in spelling {configureEmptyComposition();XCTAssertTrue(input.input(String(letter),keyCode:-1,flags:0,client:client),scenario)}
        if scenario=="retype-move" {client.view.setSelectedRange(NSRange(location:0,length:0))}
        let target=scenario=="same-word" ? "拟好":(scenario=="unrelated" ? "世界":"你好")
        let b=try XCTUnwrap(input.allCandidateRows.first{$0.text==target},scenario)
        input.chooseCandidate(b,client:client)
        let learned=try JSONDecoder().decode(NineKeyChoiceMemory.self,from:Data(contentsOf:file))
        let correct=learned.entries.filter{$0.text=="你好" && $0.context.isEmpty}.map(\.count).max() ?? 0
        let rejected=learned.entries.filter{$0.text=="拟好" && $0.context.isEmpty}.map(\.count).max() ?? 0
        if expectsCorrection {
            XCTAssertGreaterThan(correct,rejected,scenario)
            input.invalidateCorrection();engine.clear();host.string="";host.setSelectedRange(NSRange(location:0,length:0))
            type("nihao",into:input,client:TextViewClient(view:host))
            XCTAssertEqual(input.allCandidateRows.first?.text,scenario=="pinned" ? "拟好":"你好","Correction respects an explicit pin; otherwise the corrected word leads")
            if scenario=="pinned" {XCTAssertTrue(engine.isPinned(a))}
            XCTAssertTrue(input.allCandidateRows.contains{$0.text=="拟好"},"Correction does not erase the rejected word")
        } else {XCTAssertLessThanOrEqual(correct,3,scenario)}
    }
    func testMacFrequencyMenuPreservesDraftRejectsStaleActionsAndKeepsPins() throws {
        let engine=try engine();defer{engine.clear();engine.finish()};_ = engine.privacy(false)
        let input=MacInputSession(engine:engine),host=view(),client=TextViewClient(view:host)
        type("shi",into:input,client:client)
        let row=try XCTUnwrap(input.allCandidateRows.dropFirst(3).first)
        defer{try? engine.manage(row,pinned:false)}
        let draft=engine.rawInput,marked=host.string
        var refreshes=0
        let stale=try XCTUnwrap(input.managementMenu(for:row){refreshes+=1})
        let menu=try XCTUnwrap(input.managementMenu(for:row){refreshes+=1})
        XCTAssertEqual(menu.items.map(\.title),["置顶","恢复默认词频"])
        menu.performActionForItem(at:0)
        XCTAssertEqual(refreshes,1);XCTAssertTrue(engine.isPinned(row));XCTAssertEqual(engine.rawInput,draft);XCTAssertEqual(host.string,marked)
        stale.performActionForItem(at:1);XCTAssertEqual(refreshes,1,"Stale menus cannot mutate current candidates")
        let pinned=try XCTUnwrap(input.allCandidateRows.first{$0.text==row.text})
        let pinnedMenu=try XCTUnwrap(input.managementMenu(for:pinned){refreshes+=1})
        XCTAssertEqual(pinnedMenu.items.map(\.title),["取消置顶","恢复默认词频"])
        pinnedMenu.performActionForItem(at:1);XCTAssertTrue(engine.isPinned(row),"Resetting learned frequency preserves explicit pin")
        let fresh=try XCTUnwrap(input.allCandidateRows.first{$0.text==row.text})
        try XCTUnwrap(input.managementMenu(for:fresh){refreshes+=1}).performActionForItem(at:0)
        XCTAssertFalse(engine.isPinned(row));XCTAssertEqual(engine.rawInput,draft);XCTAssertEqual(host.string,marked)
        _ = engine.privacy(true)
        XCTAssertNil(input.managementMenu(for:fresh){refreshes+=1})
    }
    func testMacFrequencyResetNotificationAndEpochDropOldCorrectionBeforeRetyping() throws {
        try FileManager.default.createDirectory(at:Self.storage,withIntermediateDirectories:true)
        let marker=Self.storage.appendingPathComponent(PersonalDataReset.marker),oldMarker=try? Data(contentsOf:marker)
        defer {if let oldMarker {try? oldMarker.write(to:marker,options:.atomic)} else {try? FileManager.default.removeItem(at:marker)}}
        // Inject only this session's notification transport. Never broadcast a
        // Darwin reset or call request(), which belongs to real user data.
        for deliverNotification in [true,false] {
            let engine=try engine();defer{engine.clear();engine.finish()};_ = engine.privacy(false)
            let host=view(),client=TextViewClient(view:host)
            var notify:(()->Void)?,refreshes=0
            let epoch:()->String={
                guard let value=try? String(contentsOf:marker,encoding:.utf8),UUID(uuidString:value) != nil else{return "initial"};return value
            }
            let input=MacInputSession(engine:engine,now:{100},personalEpoch:epoch,observePersonalReset:{action in notify=action;return {notify=nil}})
            input.candidatesChanged={refreshes+=1}
            type("nihao",into:input,client:client)
            let a=try XCTUnwrap(input.allCandidateRows.first{$0.text=="你好"})
            let oldMenu=try XCTUnwrap(input.managementMenu(for:a){XCTFail("Old menu cannot cross a personal reset")})
            engine.confirmOwnCommitContext(previous:"合成旧上下文",text:"")
            input.chooseCandidate(a,client:client)
            func tracksOwnCommit()throws->Bool {
                let value=try XCTUnwrap(Mirror(reflecting:input).children.first{$0.label=="ownCommit"}?.value)
                return !Mirror(reflecting:value).children.isEmpty
            }
            XCTAssertTrue(try tracksOwnCommit());XCTAssertFalse(oldMenu.items.isEmpty)
            try Data(UUID().uuidString.utf8).write(to:marker,options:.atomic)
            if deliverNotification {
                try XCTUnwrap(notify)()
                XCTAssertFalse(try tracksOwnCommit(),"The reset callback clears own text without waiting for another key")
                XCTAssertTrue(oldMenu.items.isEmpty,"Remove action closures containing old candidate text")
                XCTAssertGreaterThan(refreshes,0)
            }
            for _ in 0..<2 {
                XCTAssertFalse(input.input(nil,keyCode:51,flags:0,client:client));host.deleteBackward(nil)
            }
            XCTAssertFalse(try tracksOwnCommit(),"An epoch change also rejects tokens before a delayed notification")
            XCTAssertTrue(oldMenu.items.isEmpty);XCTAssertTrue(engine.ready)
            type("nihao",into:input,client:client)
            let b=try XCTUnwrap(input.allCandidateRows.first{$0.text != "你好" && $0.comment.replacingOccurrences(of:" ",with:"")=="nihao"})
            input.chooseCandidate(b,client:client)
            XCTAssertEqual(host.string,b.text,"Ordinary typing and choice remain usable after reset")
            let file=Self.storage.appendingPathComponent("nine-choice-memory-v3.json")
            let after=try JSONDecoder().decode(NineKeyChoiceMemory.self,from:Data(contentsOf:file))
            XCTAssertTrue(after.entries.allSatisfy{$0.context.isEmpty},"Old own context must never enter the new personal generation")
            XCTAssertEqual(after.entries.filter{$0.text==b.text}.map(\.count).max(),1,"This is an ordinary choice, not a correction from the retired generation")
        }
    }
    func testMacFrequencyResetReachesNativeCheckpointAndReopen() throws {
        // Seed a known positive count in the isolated native DB, instead of
        // assuming Rime flushes a first single-character selection immediately.
        let probe=try engine();_ = probe.privacy(false)
        for letter in "nihao".utf8 {_ = probe.key(Int32(letter))}
        let target=try XCTUnwrap(probe.candidateBatch(offset:0,limit:64).first{$0.text=="你好"})
        probe.clear();probe.finish()
        let fixture=Self.storage.appendingPathComponent("mac-frequency-native-seed.tsv")
        try Data((target.text+"\t"+target.comment+"\t17\n").utf8).write(to:fixture)
        defer{try? FileManager.default.removeItem(at:fixture)}
        XCTAssertGreaterThanOrEqual(pi_import_learning(fixture.path),0)
        let engine=try self.engine();defer{engine.clear();engine.finish()};_ = engine.privacy(false)
        try engine.synchronizeLearning()
        let file=Self.storage.appendingPathComponent("learning-checkpoint-v1.json")
        func state()throws->RimeLearningCheckpoint {try JSONDecoder().decode(RimeLearningCheckpoint.self,from:Data(contentsOf:file))}
        let key=target.comment.lowercased().trimmingCharacters(in:.whitespaces)+"\u{001F}"+target.text
        XCTAssertGreaterThan(try state().observedCounts[key] ?? 0,0)
        let input=MacInputSession(engine:engine),host=view(),client=TextViewClient(view:host)
        type("nihao",into:input,client:client)
        let fresh=try XCTUnwrap(input.allCandidateRows.first{$0.text==target.text && $0.comment==target.comment})
        let draft=engine.rawInput,marked=host.string
        try XCTUnwrap(input.managementMenu(for:fresh){}).performActionForItem(at:1)
        XCTAssertTrue(engine.managementPending);XCTAssertEqual(engine.rawInput,draft);XCTAssertEqual(host.string,marked)
        XCTAssertThrowsError(try engine.synchronizeLearning(),"A draft cannot be discarded to reset native frequency")
        input.finishComposition(client:client);try engine.synchronizeLearning()
        XCTAssertFalse(engine.managementPending);XCTAssertTrue(try state().pendingResets.isEmpty)
        XCTAssertEqual(try state().observedCounts[key] ?? 0,0,"Read-back of actual native export proves reset")
        engine.finish()
        let reopened=try self.engine();defer{reopened.finish()};try reopened.synchronizeLearning()
        XCTAssertEqual(try state().observedCounts[key] ?? 0,0,"Reopen must not revive stale native counts")
    }
    func testMacFrequencyAnchorReadsOnlyBoundedRangesAndRejectsSelectedText() {
        let text=String(repeating:"合",count:1000)+"拟好"+String(repeating:"后",count:1000)
        var reads:[NSRange]=[]
        let a=MacInputAnchor.capture(document:"synthetic",selection:NSRange(location:1002,length:0),marked:NSRange(location:NSNotFound,length:0),length:2002,expectedSuffix:"拟好") {range in reads.append(range);return (text as NSString).substring(with:range)}
        XCTAssertNotNil(a);XCTAssertEqual(a?.position,1000);XCTAssertLessThanOrEqual(reads.map(\.length).reduce(0,+),66)
        XCTAssertNil(MacInputAnchor.capture(document:"synthetic",selection:NSRange(location:1000,length:2),marked:NSRange(location:NSNotFound,length:0),length:2002,expectedSuffix:"拟好"){_ in XCTFail("Selection must prevent all reads");return nil})
    }
    func testResetEpochKeepsMultipleNativeSessionsUsable() throws {
        let first=try engine(),second=try engine(),retired=try engine();defer {first.finish();second.finish();retired.finish()}
        _ = first.privacy(true);_ = second.privacy(true)
        for c in "nihao".utf8 {_ = first.key(Int32(c))}
        for c in "shijie".utf8 {_ = second.key(Int32(c))}
        try Data(UUID().uuidString.utf8).write(to:Self.storage.appendingPathComponent(PersonalDataReset.marker),options:.atomic)
        _ = first.key(110);retired.finish();_ = second.key(104);_ = first.key(105);_ = second.key(97)
        XCTAssertEqual(first.rawInput,"ni");XCTAssertEqual(second.rawInput,"ha")
        XCTAssertTrue(first.candidates.contains("你"));XCTAssertTrue(second.candidates.contains("哈"))
    }
    // Lexical policy on systems where all test characters are renderable;
    // real missing-glyph exclusion is covered by MacCandidateVisibilityTests.
    func testRareExactSyllableKeepsWordAndRecallsCommonPrefixWithStableSelection() throws {
        let engine=try engine(displayable:{_ in true});defer{engine.clear();engine.finish()};_ = engine.privacy(true)
        for key in "din".utf8 {_ = engine.key(Int32(key))}
        let rows=engine.candidateBatch(offset:0,limit:64)
        XCTAssertEqual(rows.first?.text,"定","Preserve native frequency order within the completed reading")
        let rareIndex=try XCTUnwrap(rows.firstIndex{$0.text=="𨈖"})
        for text in ["定","顶","丁"] {XCTAssertLessThan(try XCTUnwrap(rows.firstIndex{$0.text==text}),rareIndex)}
        XCTAssertEqual(engine.rawInput,"din");XCTAssertEqual(rows[rareIndex].comment,"din")
        XCTAssertEqual(rows[rareIndex].text.unicodeScalars.map(\.value),[0x28216])
        XCTAssertEqual((engine.candidateBatch(offset:0,limit:2)+engine.candidateBatch(offset:2,limit:4)).map(\.text),Array(rows.prefix(6)).map(\.text))
        let completion=try XCTUnwrap(rows.first{$0.text=="定"})
        XCTAssertTrue(completion.prefixCompletion);XCTAssertNil(completion.pinyinRepair)
        XCTAssertEqual(engine.chooseCandidate(completion),"定");XCTAssertEqual(engine.chooseCandidate(completion),"")
        XCTAssertTrue(engine.rawInput.isEmpty)
        engine.clear();for key in "din".utf8 {_ = engine.key(Int32(key))}
        let rare=try XCTUnwrap(engine.candidateBatch(offset:0,limit:64).first{$0.text=="𨈖"})
        XCTAssertEqual(engine.chooseCandidate(rare),"𨈖","The valid uncommon character remains selectable")
        let mixed=NativeEngine(sharedResources:try XCTUnwrap(Bundle(for:Self.self).url(forResource:"rime",withExtension:nil)),storageBase:Self.storage,mixedEnglishProvider:{_ in ["dinner"]},candidateIsDisplayable:{_ in true})
        defer{mixed.clear();mixed.finish()};_ = mixed.privacy(true);_ = mixed.setMixedEnglishEnabled(true)
        for key in "din".utf8 {_ = mixed.key(Int32(key))}
        let mixedRows=mixed.candidateBatch(offset:0,limit:64)
        XCTAssertEqual(mixedRows.first?.text,"定");XCTAssertTrue(mixedRows.contains{$0.text=="dinner"});XCTAssertTrue(mixedRows.contains{$0.text=="𨈖"})
        print("SYNTHETIC_DIN54 default=\(rows.map{($0.text,$0.comment,$0.index)}) mixed=\(mixedRows.map(\.text))")
    }
    func testRareExactSyllableManualPinAndLearningRemainAuthoritative() throws {
        let file=Self.storage.appendingPathComponent("nine-choice-memory-v3.json"),saved=try? Data(contentsOf:file)
        defer {if let saved {try? saved.write(to:file,options:.atomic)} else {try? FileManager.default.removeItem(at:file)}}
        try FileManager.default.createDirectory(at:Self.storage,withIntermediateDirectories:true)
        try JSONEncoder().encode(NineKeyChoiceMemory()).write(to:file,options:.atomic)
        let engine=try engine(displayable:{_ in true});defer{engine.clear();engine.finish()};_ = engine.privacy(false)
        for key in "din".utf8 {_ = engine.key(Int32(key))}
        let rare=try XCTUnwrap(engine.candidateBatch(offset:0,limit:64).first{$0.text=="𨈖"})
        let ding=try XCTUnwrap(engine.candidateBatch(offset:0,limit:64).first{$0.text=="丁"})
        try engine.manage(ding,pinned:true);defer{try? engine.manage(ding,pinned:false)}
        XCTAssertEqual(engine.candidateBatch(offset:0,limit:64).first?.text,"丁","Pins also apply to newly recalled prefix choices")
        try engine.manage(ding,pinned:false)
        try engine.manage(rare,pinned:true);defer{try? engine.manage(rare,pinned:false)}
        XCTAssertEqual(engine.candidateBatch(offset:0,limit:64).first?.text,"𨈖")
        try engine.manage(rare,pinned:false)
        XCTAssertEqual(engine.candidateBatch(offset:0,limit:64).first?.text,"定")
        let completion=try XCTUnwrap(engine.candidateBatch(offset:0,limit:64).first{$0.text=="定"})
        XCTAssertEqual(engine.chooseCandidate(completion),"定")
        let afterCompletion=try JSONDecoder().decode(NineKeyChoiceMemory.self,from:Data(contentsOf:file))
        XCTAssertTrue(afterCompletion.entries.isEmpty,"A valid prefix selection must not teach din as a misspelling of ding")
        engine.clear();engine.resetPredictionContext();for key in "din".utf8 {_ = engine.key(Int32(key))}
        let fresh=try XCTUnwrap(engine.candidateBatch(offset:0,limit:64).first{$0.text=="𨈖"})
        XCTAssertEqual(engine.chooseCandidate(fresh),"𨈖")
        engine.clear();engine.resetPredictionContext();for key in "din".utf8 {_ = engine.key(Int32(key))}
        XCTAssertEqual(engine.candidateBatch(offset:0,limit:64).first?.text,"𨈖","An intentional selection overrides public default")
    }
    func testRareExactSyllablePolicyLeavesCommonCompleteSpellingsAlone() throws {
        let engine=try engine(displayable:{_ in true});defer{engine.clear();engine.finish()};_ = engine.privacy(true)
        let expected=["di":"地","ding":"定","dian":"点","die":"跌","diu":"丢","dia":"嗲","den":"㩐","dei":"得","kei":"克","nun":"嫩"]
        for raw in expected.keys.sorted() {
            engine.clear();for key in raw.utf8 {_ = engine.key(Int32(key))}
            let rows=engine.candidateBatch(offset:0,limit:64)
            XCTAssertEqual(rows.first?.text,expected[raw],raw)
            XCTAssertFalse(rows.contains{$0.prefixCompletion},raw)
            print("SYNTHETIC_DIN54 protection raw=\(raw) head=\(rows.prefix(6).map(\.text))")
        }
    }
    func testCommonExpressionCandidateBaseline() throws {
        let engine=try engine();defer{engine.clear();engine.finish()};_ = engine.privacy(true)
        for raw in ["douxian","douyaoxian","yixie","shihou","zhongguo","lishi"] {
            engine.clear();for c in raw.utf8 {_ = engine.key(Int32(c))}
            let rows=engine.candidateBatch(offset:0,limit:96)
            print("SYNTHETIC_COMMON raw=\(raw) head=\(rows.prefix(12).map{($0.text,$0.comment,pi_language_score("",$0.text))})")
            if raw=="douxian" {
                XCTAssertEqual(rows.first?.text,"都先")
                XCTAssertTrue(rows.contains{$0.text=="窦宪"},"Keep the uncommon but valid alternative")
            }
            let expected=["yixie":"一些","shihou":"时候","zhongguo":"中国","lishi":"历史"]
            if let word=expected[raw] {XCTAssertEqual(rows.first?.text,word,"Sparse grammar must not displace a frequent whole word")}
            let paged=engine.candidateBatch(offset:0,limit:5)+engine.candidateBatch(offset:5,limit:7)
            XCTAssertEqual(paged.map(\.text),Array(rows.prefix(12)).map(\.text))
        }
    }
    func testCommonPriorPreservesExplicitRareChoiceAndPin() throws {
        let engine=try engine();defer{engine.clear();engine.finish()}
        for _ in 0..<2 {
            engine.clear();engine.resetPredictionContext()
            for c in "douxian".utf8 {_ = engine.key(Int32(c))}
            let rare=try XCTUnwrap(engine.candidateBatch(offset:0,limit:96).first{$0.text=="窦宪"})
            XCTAssertEqual(engine.chooseCandidate(rare),"窦宪")
            XCTAssertEqual(engine.chooseCandidate(rare),"")
        }
        engine.clear();engine.resetPredictionContext()
        for c in "douxian".utf8 {_ = engine.key(Int32(c))}
        XCTAssertEqual(engine.candidateBatch(offset:0,limit:8).first?.text,"窦宪","Repeated explicit choices outrank public commonness")
        let rare=try XCTUnwrap(engine.candidateBatch(offset:0,limit:96).first{$0.text=="窦宪"})
        try engine.manage(rare,pinned:true);defer{try? engine.manage(rare,pinned:false)}
        XCTAssertEqual(engine.candidateBatch(offset:0,limit:8).first?.text,"窦宪")
        engine.clear();XCTAssertTrue(engine.privacy(true))
        for c in "douxian".utf8 {_ = engine.key(Int32(c))}
        XCTAssertEqual(engine.candidateBatch(offset:0,limit:8).first?.text,"都先","Private input must use public priors without reading stored pins")
        engine.clear();XCTAssertTrue(engine.privacy(false))
        for c in "douxian".utf8 {_ = engine.key(Int32(c))}
        XCTAssertEqual(engine.candidateBatch(offset:0,limit:8).first?.text,"窦宪","Private input must retain the ordinary-mode pin for later use")
    }
    @MainActor func testLiteralDecimalAndVersionNeverWaitForAnEmptyCandidateMenu() throws {
        let engine=try engine();defer{engine.clear();engine.finish()};_ = engine.privacy(true)
        for raw in ["1.4","0.05","1.2.3","-1.4"] {
            engine.clear();let input=MacInputSession(engine:engine),host=view(""),client=TextViewClient(view:host)
            for c in raw {let handled=input.input(String(c),keyCode:0,flags:0,client:client);if !handled {client.insert(String(c))}}
            print("SYNTHETIC_LITERAL raw=\(raw) body=\(host.string) pending=\(engine.rawInput) rows=\(input.candidateRows.count)")
            XCTAssertEqual(host.string,raw);XCTAssertTrue(engine.preedit.isEmpty)
        }
    }
    @MainActor func testEnglishDraftIsContinuousThroughCompletionAndNearKeyRepair() throws {
        let resources=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"rime",withExtension:nil))
        let engine=NativeEngine(sharedResources:resources,storageBase:Self.storage,useSemantic:false,mixedEnglishProvider:MacEnglishDictionary.completions)
        defer{engine.clear();engine.finish()};_ = engine.privacy(true);_ = engine.setMixedEnglishEnabled(true)
        for raw in ["apple","aoole","applr","aple","appple","aplpe"] {
            engine.clear();let input=MacInputSession(engine:engine),host=view(""),client=TextViewClient(view:host)
            var prefix=""
            for c in raw {prefix.append(c);_ = input.input(String(c),keyCode:0,flags:0,client:client);XCTAssertEqual(host.string,prefix,raw)}
            let row=try XCTUnwrap(engine.candidateBatch(offset:0,limit:96).first{$0.text.lowercased()=="apple" && $0.latinInput != nil},raw)
            input.chooseCandidate(row,client:client);XCTAssertEqual(host.string,"apple");XCTAssertFalse(host.hasMarkedText())
            XCTAssertEqual(engine.chooseCandidate(row),"")
        }
    }
    func testPinyinUmlautAliasesUseRealNativeWordsAndCanonicalSelection() throws {
        let engine=try engine();defer{engine.clear();engine.finish()};_ = engine.privacy(true)
        for raw in ["lve","lue","lüe","nve","nue","nüe"] {
            engine.clear();for c in raw.unicodeScalars {_ = engine.key(Int32(c.value))}
            let expected=raw.hasPrefix("l") ? "略":"虐",rows=engine.candidateBatch(offset:0,limit:64)
            print("SYNTHETIC_ALIAS raw=\(raw) head=\(rows.prefix(6).map(\.text))")
            let row=try XCTUnwrap(rows.first{$0.text==expected},raw)
            XCTAssertEqual(engine.chooseCandidate(row),expected);XCTAssertTrue(engine.rawInput.isEmpty)
        }
        for (raw,word) in [("lu","路"),("lv","绿"),("nu","怒"),("nv","女")] {
            engine.clear();for c in raw.utf8 {_ = engine.key(Int32(c))}
            XCTAssertTrue(engine.candidateBatch(offset:0,limit:64).contains{$0.text==word},raw)
        }
    }
    func testAliasSpellingKeepsTheSameExplicitPin() throws {
        let engine=try engine();defer{engine.clear();engine.finish()}
        for key in "lve".utf8 {_ = engine.key(Int32(key))}
        let row=try XCTUnwrap(engine.candidateBatch(offset:0,limit:32).first{$0.text=="掠"})
        try engine.manage(row,pinned:true);defer{try? engine.manage(row,pinned:false)}
        engine.clear();for key in "lue".utf8 {_ = engine.key(Int32(key))}
        let rows=engine.candidateBatch(offset:0,limit:32)
        XCTAssertEqual(rows.first?.text,"掠");XCTAssertTrue(engine.isPinned(try XCTUnwrap(rows.first)))
    }
    func testFullPinyinMissingExtraAndSwapRecallAndSafeCommit() throws {
        let resources=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"rime",withExtension:nil))
        let engine=NativeEngine(sharedResources:resources,storageBase:Self.storage,useSemantic:false)
        _ = engine.privacy(true)
        for input in ["shshenme","shishenmee","sihshenme"] {
            engine.clear();for key in input.utf8 {_ = engine.key(Int32(key))}
            let before=engine.rawInput,start=Date.timeIntervalSinceReferenceDate,rows=engine.candidateBatch(offset:0,limit:32)
            print("SYNTHETIC_PINYIN input=\(input) head=\(rows.prefix(8).map(\.text)) ms=\((Date.timeIntervalSinceReferenceDate-start)*1000)")
            XCTAssertEqual(engine.rawInput,before)
            let row=try XCTUnwrap(rows.first{$0.text=="是什么"},input)
            XCTAssertEqual(engine.chooseCandidate(row),"是什么");XCTAssertTrue(engine.rawInput.isEmpty)
            XCTAssertEqual(engine.chooseCandidate(row),"")
        }
        engine.clear();engine.finish()
    }
    func testFullPinyinLongOmissionsAndSelectedPrefixAreRetained() throws {
        let engine=try engine();_ = engine.privacy(true)
        for (raw,expected) in [("zaoshangho","早上好"),("wshenme","为什么"),("woenjitiantianqi","我们今天天气")] {
            engine.clear();for key in raw.utf8 {_ = engine.key(Int32(key))}
            let rows=engine.candidateBatch(offset:0,limit:64)
            print("SYNTHETIC_PINYIN_LONG raw=\(raw) head=\(rows.prefix(8).map(\.text))")
            let row=try XCTUnwrap(rows.first{$0.text==expected},raw)
            XCTAssertEqual(engine.chooseCandidate(row),expected)
        }
        engine.clear();for key in "nihaoshshenme".utf8 {_ = engine.key(Int32(key))}
        let prefix=try XCTUnwrap(engine.candidateBatch(offset:0,limit:96).first{$0.text=="你好" && $0.pinyinRepair==nil})
        XCTAssertEqual(engine.chooseCandidate(prefix),"")
        let original=engine.rawInput,row=try XCTUnwrap(engine.candidateBatch(offset:0,limit:64).first{$0.text=="是什么"})
        XCTAssertEqual(engine.rawInput,original)
        XCTAssertEqual(engine.chooseCandidate(row),"你好是什么")
        engine.clear();engine.finish()
    }
    @MainActor func testFullPinyinRepairSpaceQuestionAndDeletionPreserveHost() throws {
        let engine=try engine();_ = engine.privacy(true)
        let input=MacInputSession(engine:engine),host=view("前文："),client=TextViewClient(view:host)
        type("shshenme",into:input,client:client)
        XCTAssertTrue(host.hasMarkedText());XCTAssertTrue(host.string.hasPrefix("前文："))
        XCTAssertEqual(input.candidateRows.first?.text,"是什么")
        XCTAssertTrue(input.input("?",keyCode:44,flags:0,client:client))
        XCTAssertEqual(host.string,"前文：是什么？");XCTAssertFalse(host.hasMarkedText())
        type("shshenme",into:input,client:client)
        XCTAssertTrue(input.input(nil,keyCode:51,flags:0,client:client));XCTAssertEqual(engine.rawInput,"shshenm")
        type("e",into:input,client:client)
        XCTAssertTrue(input.input(" ",keyCode:49,flags:0,client:client))
        XCTAssertEqual(host.string,"前文：是什么？是什么");XCTAssertTrue(engine.rawInput.isEmpty)
        engine.finish()
    }
    func testMalformedNineInputKeepsRecoverablePrefixAndUntouchedTail() throws {
        let resources=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"rime",withExtension:nil))
        let engine=NativeEngine(sharedResources:resources,storageBase:Self.storage,useSemantic:false)
        _ = engine.privacy(true);_ = engine.nineKey(true)
        var partialCount=0
        let cases=["6477777777777777777777777777777777","64426699999999999999999999999999","22222222222222222222222222222222","7426345","6464444444444"]
        for input in cases {
            engine.clear();for key in input.utf8 {_ = engine.key(Int32(key))}
            let before=engine.rawInput,rows=engine.partialRecoveryCandidates()
            XCTAssertEqual(engine.rawInput,before)
            if let partial=rows.first(where:{$0.partialCode != nil}),let prefix=partial.partialCode {
                partialCount+=1
                XCTAssertEqual(engine.chooseCandidate(partial),partial.text)
                XCTAssertEqual(engine.rawInput,String(before.dropFirst(prefix.count)))
                XCTAssertEqual(engine.chooseCandidate(partial),"", "A stale prefix cannot be committed twice")
            }
        }
        print("SYNTHETIC_PARTIAL_RECOVERY_CASES=\(partialCount)")
        XCTAssertGreaterThan(partialCount,0)
        engine.clear();engine.finish()
    }
    func testMixedInitialsFamilyRetainsWholeSuffixAndIndependentPrefixChoices() throws {
        let resources=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"rime",withExtension:nil))
        let engine=NativeEngine(sharedResources:resources,storageBase:Self.storage,useSemantic:false)
        defer{engine.clear();engine.finish()};_ = engine.privacy(true)
        var tested=0
        for nine in [true,false] {
            engine.clear();_ = engine.nineKey(nine)
            for n in 2...6 {
                for (tail,word) in [("hao","好"),("haode","好的"),("xiexie","谢谢"),("keyi","可以")] {
                    engine.clear();engine.resetPredictionContext()
                    let letters=String(repeating:"h",count:n)+tail,raw=nine ? NineKeySpelling.encode(letters)!:letters
                    for key in raw.utf8 {_ = engine.key(Int32(key))}
                    var rows=engine.candidateBatch(offset:0,limit:128)
                    let expected=String(repeating:"哈",count:n)+word
                    print("MIXED_FAMILY nine=\(nine) n=\(n) tail=\(tail) rows=\(rows.count) target=\(rows.firstIndex{$0.text==expected} ?? -1)")
                    guard let candidate=rows.first(where:{$0.text==expected}) else {XCTFail(raw);print("MIXED_MISSING "+rows.map{$0.text+"|"+$0.comment+"|"+($0.initialsInput ?? "-")}.joined(separator:";"));continue}
                    XCTAssertEqual(engine.rawInput,raw)
                    if nine,engine.needsNinePrediction {finishPrediction(engine);rows=engine.candidateBatch(offset:0,limit:128)}
                    let current=try XCTUnwrap(rows.first{$0.text==expected},raw)
                    if nine {
                        let first=try XCTUnwrap(rows.first)
                        XCTAssertEqual(first.initialsInput?.count,raw.count,"A valid full mixed spelling must precede a proposal that drops suffix keys")
                        XCTAssertTrue(rows.contains{($0.initialsInput?.count ?? raw.count)<raw.count},"Keep selectable prefixes, not just a single best sentence")
                    }
                    XCTAssertEqual(engine.chooseCandidate(current),expected,raw)
                    XCTAssertTrue(engine.rawInput.isEmpty,raw)
                    XCTAssertEqual(engine.chooseCandidate(candidate),"")
                    tested+=1
                }
            }
        }
        XCTAssertEqual(tested,40)
        engine.clear();_ = engine.nineKey(true)
        let raw="44444426";for key in raw.utf8 {_ = engine.key(Int32(key))}
        let prefix=try XCTUnwrap(engine.candidateBatch(offset:0,limit:128).first{$0.text==String(repeating:"哈",count:5) && $0.initialsInput?.count==5})
        XCTAssertEqual(engine.chooseCandidate(prefix),String(repeating:"哈",count:5));XCTAssertEqual(engine.rawInput,"426")
        XCTAssertTrue(engine.candidateBatch(offset:0,limit:32).contains{$0.text=="好"})
    }
    func testMixedInitialsCoverSeveralPrefixFamiliesWithoutDisplacingNormalNineHead() throws {
        let resources=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"rime",withExtension:nil))
        let engine=NativeEngine(sharedResources:resources,storageBase:Self.storage,useSemantic:false)
        defer{engine.clear();engine.finish()};_ = engine.privacy(true);_ = engine.nineKey(true)
        for (initial,word,n) in [("h","哈",2),("h","哈",5),("x","谢",2),("b","拜",2),("m","慢",2)] {
            for (suffix,last) in [("hao","好"),("haode","好的"),("ni","你")] {
                engine.clear();let raw=NineKeySpelling.encode(String(repeating:initial,count:n)+suffix)!
                for c in raw.utf8{_ = engine.key(Int32(c))}
                let rows=engine.candidateBatch(offset:0,limit:160),expected=String(repeating:word,count:n)+last
                print("PREFIX_FAMILY initial=\(initial) n=\(n) suffix=\(suffix) target=\(rows.firstIndex{$0.text==expected} ?? -1) count=\(rows.count)")
                let row=try XCTUnwrap(rows.first{$0.text==expected},raw)
                XCTAssertEqual(engine.chooseCandidate(row),expected);XCTAssertTrue(engine.rawInput.isEmpty)
            }
        }
        for c in "968".utf8{_ = engine.key(Int32(c))}
        XCTAssertEqual(engine.candidateBatch(offset:0,limit:32).first?.text,"有")
    }
    func testMacSystemEnglishDictionaryIsConnectedTo26KeyMixedCandidates() throws {
        let resources=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"rime",withExtension:nil))
        let engine=NativeEngine(sharedResources:resources,storageBase:Self.storage,useSemantic:false,mixedEnglishProvider:MacEnglishDictionary.completions)
        defer{engine.clear();engine.finish()};_ = engine.privacy(true);_ = engine.setMixedEnglishEnabled(true)
        for key in "eleph".utf8 {_ = engine.key(Int32(key))}
        let row=try XCTUnwrap(engine.candidateBatch(offset:0,limit:64).first{$0.text.lowercased()=="elephant" && $0.latinInput != nil})
        XCTAssertEqual(engine.chooseCandidate(row),row.text);XCTAssertTrue(engine.rawInput.isEmpty)
    }
    func testNineInitialsRespectExplicitPinBeforeRepeatedExpressions() throws {
        let engine=try engine();defer{engine.clear();engine.finish()}
        _ = engine.nineKey(true);_ = engine.privacy(false)
        for key in "4444".utf8 {_ = engine.key(Int32(key))}
        let row=try XCTUnwrap(engine.candidateBatch(offset:0,limit:32).first{$0.text=="红红火火"})
        try engine.manage(row,pinned:true)
        defer{try? engine.manage(row,pinned:false)}
        let head=try XCTUnwrap(engine.candidateBatch(offset:0,limit:32).first)
        XCTAssertEqual(head.text,row.text);XCTAssertTrue(engine.isPinned(head));XCTAssertEqual(engine.rawInput,"4444")
        XCTAssertEqual(engine.chooseCandidate(head),"红红火火")
    }
    func testNineInitialsFallbackRetainsLongTailAndRejectsStaleSelection() throws {
        let engine=try engine();defer{engine.clear();engine.finish()}
        _ = engine.nineKey(true);_ = engine.privacy(true)
        let raw=String(repeating:"4",count:17)
        for key in raw.utf8 {_ = engine.key(Int32(key))}
        let start=Date.timeIntervalSinceReferenceDate
        let row=try XCTUnwrap(engine.candidateBatch(offset:0,limit:32).first{$0.initialsInput != nil})
        print("SYNTHETIC_INITIALS_17 ms=\((Date.timeIntervalSinceReferenceDate-start)*1000)")
        XCTAssertEqual(engine.rawInput,raw);XCTAssertEqual(row.initialsInput?.count,8)
        XCTAssertEqual(engine.chooseCandidate(row),row.text)
        XCTAssertEqual(engine.rawInput,String(repeating:"4",count:9))
        XCTAssertEqual(engine.chooseCandidate(row),"");XCTAssertEqual(engine.rawInput.count,9)
        engine.clear();for key in "4444".utf8 {_ = engine.key(Int32(key))}
        let stale=try XCTUnwrap(engine.candidateBatch(offset:0,limit:32).first{$0.text=="哈哈哈哈"})
        _ = engine.key(52);XCTAssertEqual(engine.chooseCandidate(stale),"");XCTAssertEqual(engine.rawInput,"44444")
    }
    func testNineInitialsKeepVisibleCandidatesAndSelectOnceWithAndWithoutPrediction() throws {
        let resources=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"rime",withExtension:nil))
        for privateMode in [true,false] {
            let engine=NativeEngine(sharedResources:resources,storageBase:Self.storage,useSemantic:false)
            defer {engine.clear();engine.finish()}
            _ = engine.nineKey(true);_ = engine.privacy(privateMode)
            for (raw,target) in [("44","哈哈"),("444","哈哈哈"),("4444","哈哈哈哈"),("42424242","哈哈哈哈")] {
                engine.clear();engine.resetPredictionContext()
                for c in raw.utf8 {_ = engine.key(Int32(c))}
                let original=engine.rawInput,rows=engine.candidateBatch(offset:0,limit:64)
                XCTAssertFalse(rows.isEmpty);XCTAssertTrue(rows.contains{$0.text==target},raw)
                let shown=engine.displayedPreedit(reading:rows[0].comment)
                XCTAssertFalse(shown.contains("…"));XCTAssertFalse(shown.contains(where:{$0.isNumber}))
                XCTAssertEqual(shown.replacingOccurrences(of:" ",with:""),raw.contains("2") ? "hahahaha":String(repeating:"h",count:raw.count))
                if engine.needsNinePrediction {finishPrediction(engine)}
                let candidate=try XCTUnwrap(engine.candidateBatch(offset:0,limit:64).first{$0.text==target},raw)
                XCTAssertEqual(engine.rawInput,original)
                XCTAssertEqual(engine.chooseCandidate(candidate),target);XCTAssertTrue(engine.rawInput.isEmpty)
                XCTAssertEqual(engine.chooseCandidate(candidate),"", "Selection must not replay an old candidate")
            }
        }
    }
    func testHelloMissingAndRepeatedKeyRecallWithAndWithoutNeuralModel() throws {
        let resources=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"rime",withExtension:nil))
        for semantic in [false,true] {
            let engine=NativeEngine(sharedResources:resources,storageBase:Self.storage,useSemantic:semantic);_ = engine.privacy(true);_ = engine.nineKey(true)
            for input in ["6426","644426"] {
                engine.clear();engine.resetPredictionContext();for c in input.unicodeScalars{_ = engine.key(Int32(c.value))};finishPrediction(engine)
                let rows=engine.candidateBatch(offset:0,limit:160),rank=rows.firstIndex{$0.text=="你好"}
                print("SYNTHETIC_HELLO_RECALL semantic=\(semantic) input=\(input) rank=\(rank ?? -1) head=\(rows.prefix(5).map(\.text))")
                let hello=try XCTUnwrap(rows.first{$0.text=="你好"});XCTAssertEqual(engine.chooseCandidate(hello),"你好")
            }
            engine.clear();engine.finish()
        }
    }
    func testMobilePredictionSlicesPreserveFullStreamAndCancelPreparation() throws {
        let resources=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"rime",withExtension:nil))
        let inputs=["64425","642696942644374884"]
        var reference:[[String]]=[]
        for sliced in [false,true] {
            let engine=NativeEngine(sharedResources:resources,storageBase:Self.storage,useSemantic:false)
            _ = engine.privacy(true);_ = engine.nineKey(true)
            defer {engine.clear();engine.finish()}
            for (i,input) in inputs.enumerated() {
                engine.clear();engine.resetPredictionContext()
                for c in input.unicodeScalars {_ = engine.key(Int32(c.value))}
                XCTAssertTrue(engine.beginNinePrediction())
                var completed=false,turns=0,maxCallMS=0.0
                for _ in 0..<3000 {
                    let probes=engine.predictionQueryCount,start=Date.timeIntervalSinceReferenceDate
                    let done=engine.advanceNinePrediction(maxQueriesPerSlice:sliced ? 1:Int.max)
                    maxCallMS=max(maxCallMS,(Date.timeIntervalSinceReferenceDate-start)*1000);turns+=1
                    if sliced {XCTAssertLessThanOrEqual(engine.predictionQueryCount-probes,1)}
                    if done {completed=true;break}
                    RunLoop.current.run(until:Date().addingTimeInterval(0.001))
                }
                XCTAssertTrue(completed);XCTAssertEqual(engine.rawInput,input)
                let rows=engine.candidateBatch(offset:0,limit:160)
                let signature=rows.map{$0.text+"|"+$0.comment+"|"+($0.replacementInput ?? "")}
                if sliced {XCTAssertEqual(signature,reference[i])} else {reference.append(signature)}
                print("SYNTHETIC_MOBILE_SLICE sliced=\(sliced) length=\(input.count) turns=\(turns) preparation_ms=\(engine.predictionPreparationMS) probe_max_ms=\(engine.predictionMaxProbeMS) call_max_ms=\(maxCallMS) queries=\(engine.predictionQueryCount)")
            }
            engine.clear()
            for c in "64425".unicodeScalars {_ = engine.key(Int32(c.value))}
            let initial=engine.rawInput,revision=engine.revision
            XCTAssertTrue(engine.beginNinePrediction())
            _ = engine.advanceNinePrediction(maxQueriesPerSlice:1)
            engine.cancelNinePrediction()
            XCTAssertFalse(engine.hasPreparedNinePrediction);XCTAssertEqual(engine.rawInput,initial);XCTAssertEqual(engine.revision,revision)
            _ = engine.key(54)
            XCTAssertEqual(engine.rawInput,initial+"6")
            let current=engine.candidateBatch(offset:0,limit:12)
            XCTAssertFalse(current.isEmpty)
        }
    }
    func testMobileNeuralExplorationSlicesAndCacheDisabledBothComplete() throws {
        let resources=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"rime",withExtension:nil))
        for cached in [true,false] {
            let engine=NativeEngine(sharedResources:resources,storageBase:Self.storage,useSemantic:true,cachePredictionQueries:cached)
            _ = engine.privacy(true);_ = engine.nineKey(true)
            defer {engine.clear();engine.finish()}
            let code="6442664426744543"
            for c in code.unicodeScalars {_ = engine.key(Int32(c.value))}
            XCTAssertTrue(engine.beginNinePrediction())
            var completed=false,largest=0
            for _ in 0..<5000 {
                let before=engine.predictionQueryCount
                let done=engine.advanceNinePrediction(maxQueriesPerSlice:1)
                largest=max(largest,engine.predictionQueryCount-before)
                if done {completed=true;break}
                RunLoop.current.run(until:Date().addingTimeInterval(0.002))
            }
            XCTAssertTrue(completed);XCTAssertLessThanOrEqual(largest,1)
            XCTAssertTrue(engine.hasPreparedNinePrediction);XCTAssertEqual(engine.rawInput,code)
            XCTAssertGreaterThan(engine.semanticBatches,0,"This case must exercise the neural exploration stages, not silently skip them")
            XCTAssertFalse(engine.candidateBatch(offset:0,limit:160).isEmpty)
            print("SYNTHETIC_MOBILE_NEURAL cached=\(cached) batches=\(engine.semanticBatches) assemblies=\(engine.assembledCandidateCount) call_max_ms=\(engine.predictionMaxSliceMS) probe_max_ms=\(engine.predictionMaxProbeMS)")
        }
    }
    func testMobileWarmProbeIsReusedClearedAndReleasedOnMemoryPressure() throws {
        let resources=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"rime",withExtension:nil))
        let engine=NativeEngine(sharedResources:resources,storageBase:Self.storage,useSemantic:false,retainPredictionProbe:true)
        _ = engine.privacy(true);_ = engine.nineKey(true)
        let sessions=pi_active_session_count()
        defer {engine.clear();engine.finish()}
        for round in 0..<3 {
            engine.clear()
            for c in "64425".unicodeScalars {_ = engine.key(Int32(c.value))}
            XCTAssertTrue(engine.beginNinePrediction())
            var completed=false
            for _ in 0..<2000 {
                if engine.advanceNinePrediction(maxQueriesPerSlice:1) {completed=true;break}
                RunLoop.current.run(until:Date().addingTimeInterval(0.001))
            }
            XCTAssertTrue(completed);XCTAssertEqual(pi_active_session_count(),sessions+1)
            let chosen=try XCTUnwrap(engine.candidateBatch(offset:0,limit:128).first{$0.text=="你好"})
            XCTAssertEqual(engine.chooseCandidate(chosen),"你好");XCTAssertTrue(engine.rawInput.isEmpty)
            XCTAssertEqual(pi_active_session_count(),sessions+1)
            print("SYNTHETIC_MOBILE_WARM round=\(round) prepare_ms=\(engine.predictionPreparationMS) slice_max_ms=\(engine.predictionMaxSliceMS)")
        }
        engine.suspendPredictionForMemoryPressure()
        XCTAssertEqual(pi_active_session_count(),sessions)
        engine.finish();XCTAssertEqual(pi_active_session_count(),sessions-1)
    }
    func testProbeCachePreservesCandidatesAndFreesRepeatedWork() throws {
        let resources=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"rime",withExtension:nil))
        let inputs=["642696942644374884","74642296354263243496","6442664426744543"]
        var original:[[String]]=[],queries:[Int]=[],hits=0
        for cached in [false,true] {
            let engine=NativeEngine(sharedResources:resources,storageBase:Self.storage,useSemantic:false,expandedSentenceRecall:false,cachePredictionQueries:cached)
            _ = engine.privacy(true);_ = engine.nineKey(true)
            for (i,input) in inputs.enumerated() {
                engine.clear();engine.resetPredictionContext();for c in input.unicodeScalars{_ = engine.key(Int32(c.value))};finishPrediction(engine)
                let signature=engine.candidateBatch(offset:0,limit:160).map{$0.text+"|"+$0.comment+"|"+($0.replacementInput ?? "")}
                if !cached { original.append(signature);queries.append(engine.predictionQueryCount) }
                else { XCTAssertEqual(signature,original[i]);XCTAssertLessThanOrEqual(engine.predictionQueryCount,queries[i]);hits+=engine.predictionCacheHits;print("SYNTHETIC_PROBE_CACHE before=\(queries[i]) after=\(engine.predictionQueryCount) hits=\(engine.predictionCacheHits)") }
                XCTAssertEqual(engine.rawInput,input)
            }
            engine.clear();engine.finish()
        }
        XCTAssertGreaterThan(hits,0,"Cache must avoid measured repeated Rime queries")
    }
    func testConfirmedTypoAlsoLearnsCanonicalSpellingAndPrivateModeDoesNotWrite() throws {
        let file=Self.storage.appendingPathComponent("nine-choice-memory-v3.json"),saved=try? Data(contentsOf:file)
        defer { if let saved { try? saved.write(to:file,options:.atomic) } else { try? FileManager.default.removeItem(at:file) } }
        try FileManager.default.createDirectory(at:Self.storage,withIntermediateDirectories:true)
        try JSONEncoder().encode(NineKeyChoiceMemory()).write(to:file,options:.atomic)
        let engine=try engine();defer{engine.clear();engine.finish()};_ = engine.nineKey(true);_ = engine.privacy(false)
        for c in "64425".unicodeScalars{_ = engine.key(Int32(c.value))};finishPrediction(engine)
        let word=try XCTUnwrap(engine.candidateBatch(offset:0,limit:128).first{$0.text=="你好" && $0.replacementInput != nil})
        XCTAssertEqual(engine.chooseCandidate(word),"你好")
        let memory=try JSONDecoder().decode(NineKeyChoiceMemory.self,from:Data(contentsOf:file));try memory.validate()
        XCTAssertTrue(memory.entries.contains{$0.code=="64425" && $0.text=="你好"})
        XCTAssertTrue(memory.entries.contains{$0.code=="64426" && $0.text=="你好"})
        let before=try Data(contentsOf:file);_ = engine.privacy(true);engine.resetPredictionContext()
        for c in "64425".unicodeScalars{_ = engine.key(Int32(c.value))};finishPrediction(engine)
        let privateWord=try XCTUnwrap(engine.candidateBatch(offset:0,limit:128).first{$0.text=="你好" && $0.replacementInput != nil})
        XCTAssertEqual(engine.chooseCandidate(privateWord),"你好");XCTAssertEqual(try Data(contentsOf:file),before)
        _ = engine.privacy(false);engine.resetPredictionContext()
        engine.noteFullyDeletedOwnCommit(code:"744543",context:"",rejectedText:"世界",reading:"shi jie")
        for c in "7445426".unicodeScalars{_ = engine.key(Int32(c.value))}
        let time=try XCTUnwrap(engine.candidateBatch(offset:0,limit:128).first{$0.text=="时间"})
        XCTAssertEqual(engine.chooseCandidate(time),"时间")
        let corrected=try JSONDecoder().decode(NineKeyChoiceMemory.self,from:Data(contentsOf:file))
        XCTAssertEqual(corrected.entries.first{$0.code=="744543" && $0.text=="时间"}?.count,3)
        XCTAssertEqual(corrected.entries.first{$0.code=="7445426" && $0.text=="时间"}?.count,3)
        for old in memory.entries { XCTAssertTrue(corrected.entries.contains(old)) }
    }
    func testBoundaryRecallSyntheticComparisonPreservesDraftAndOriginals() throws {
        let fixtures=[("jin tian xia wu wo men yi qi chi fan","今天下午我们一起吃饭"),("wo men ming tian zai lian xi","我们明天再联系"),("qing ba wen jian fa gei wo","请把文件发给我"),("zhe jian shi qing mei you wen ti","这件事情没有问题"),("wo xiang he ni shang liang yi xia","我想和你商量一下"),("wo men xian ba wen ti shuo qing chu","我们先把问题说清楚")]
        let resources=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"rime",withExtension:nil));var rows:[[String:Any]]=[]
        for expanded in [false,true] {
            let engine=NativeEngine(sharedResources:resources,storageBase:Self.storage,expandedSentenceRecall:expanded)
            _ = engine.nineKey(true);_ = engine.privacy(true)
            for (reading,text) in fixtures {
                let code=try XCTUnwrap(NineKeySpelling.encode(reading)),chars=Array(code)
                for b in stride(from:8,to:chars.count,by:8) where chars[b-1] != chars[b] {
                    var wrong=chars;wrong.swapAt(b-1,b);let input=String(wrong)
                    engine.clear();engine.resetPredictionContext();for c in input.unicodeScalars{_ = engine.key(Int32(c.value))}
                    let originals=engine.candidateBatch(offset:0,limit:64);finishPrediction(engine)
                    let result=engine.candidateBatch(offset:0,limit:160)
                    XCTAssertEqual(engine.rawInput,input);XCTAssertLessThanOrEqual(engine.predictionQueryCount,240)
                    for old in originals{XCTAssertTrue(result.contains{$0.text==old.text && $0.index==old.index})}
                    rows.append(["expanded":expanded,"expected":text,"boundary":b,"code":input,"rank":result.firstIndex{$0.text==text} ?? -1,"queries":engine.predictionQueryCount,"elapsedMS":engine.predictionElapsedMS,"maxSliceMS":engine.predictionMaxSliceMS])
                }
            }
            engine.clear();engine.finish()
        }
        for old in rows where (old["expanded"] as? Bool)==false && (old["rank"] as? Int ?? -1)>=0 {
            let new=rows.first{$0["expanded"] as? Bool==true && $0["code"] as? String==old["code"] as? String}
            XCTAssertGreaterThanOrEqual(new?["rank"] as? Int ?? -1,0)
        }
        try Self.saveDiagnostic(rows,name:"boundary-recall")
    }
    func testDeletedHomophoneMovesBackImmediatelyInNineAndPinyin26WithoutLosingOtherWords() throws {
        let engine=try engine();defer{engine.clear();engine.finish()};_ = engine.privacy(true)
        for nine in [true,false] {
            engine.clear();engine.resetPredictionContext();_ = engine.nineKey(nine)
            let input=nine ? "64426":"nihao"
            for c in input.unicodeScalars{_ = engine.key(Int32(c.value))}
            let rows=engine.candidateBatch(offset:0,limit:64)
            let peers=rows.filter{$0.comment.replacingOccurrences(of:" ",with:"").replacingOccurrences(of:"'",with:"")=="nihao" && !engine.isPinned($0)}
            XCTAssertGreaterThan(peers.count,1)
            let rejected=try XCTUnwrap(peers.first);engine.clear()
            engine.noteFullyDeletedOwnCommit(code:"64426",context:"",rejectedText:rejected.text,reading:rejected.comment)
            for c in input.unicodeScalars{_ = engine.key(Int32(c.value))}
            let after=engine.candidateBatch(offset:0,limit:64),changed=after.filter{peers.map(\.text).contains($0.text)}
            XCTAssertNotEqual(changed.first?.text,rejected.text);XCTAssertTrue(changed.contains{$0.text==rejected.text})
            XCTAssertEqual(Set(rows.map(\.text)),Set(after.map(\.text)));XCTAssertEqual(engine.rawInput,input)
            for (before,next) in zip(rows,after) where !peers.map(\.text).contains(before.text) { XCTAssertEqual(before.text,next.text) }
        }
    }
    func testActualSameCodeReselectionWritesStrongCorrectionRatherThanOneOrdinaryUse() throws {
        try FileManager.default.createDirectory(at:Self.storage,withIntermediateDirectories:true)
        let file=Self.storage.appendingPathComponent("nine-choice-memory-v3.json"),saved=try? Data(contentsOf:file)
        defer { if let saved { try? saved.write(to:file,options:.atomic) } else { try? FileManager.default.removeItem(at:file) } }
        var memory=NineKeyChoiceMemory();try memory.record(code:"64426",reading:"ni hao",text:"拟好",context:"",strength:3)
        try JSONEncoder().encode(memory).write(to:file,options:.atomic)
        let engine=try engine();defer{engine.clear();engine.finish()};_ = engine.privacy(false);_ = engine.nineKey(true)
        engine.noteFullyDeletedOwnCommit(code:"64426",context:"",rejectedText:"拟好",reading:"ni hao")
        for c in "64426".unicodeScalars{_ = engine.key(Int32(c.value))}
        let word=try XCTUnwrap(engine.candidateBatch(offset:0,limit:64).first{$0.text=="你好"})
        XCTAssertEqual(engine.chooseCandidate(word),"你好")
        let after=try JSONDecoder().decode(NineKeyChoiceMemory.self,from:Data(contentsOf:file))
        XCTAssertGreaterThan(try XCTUnwrap(after.entries.first{$0.text=="你好"}).count,try XCTUnwrap(after.entries.first{$0.text=="拟好"}).count)
        XCTAssertEqual(after.entries.first{$0.text=="拟好"}?.count,3)
    }
    func testConfirmedHomophoneMemoryLoadsBeforeSemanticPredictionInBothLayouts() throws {
        let file=Self.storage.appendingPathComponent("nine-choice-memory-v3.json"),saved=try? Data(contentsOf:file)
        defer { if let saved { try? saved.write(to:file,options:.atomic) } else { try? FileManager.default.removeItem(at:file) } }
        var memory=NineKeyChoiceMemory()
        for _ in 0..<8 { try memory.record(code:"64426",reading:"ni hao",text:"拟好",context:"",strength:3) }
        try memory.recordCorrection(code:"64426",reading:"ni hao",text:"你好",context:"")
        try JSONEncoder().encode(memory).write(to:file,options:.atomic)
        for nine in [true,false] {
            let engine=try engine();defer{engine.clear();engine.finish()};_ = engine.privacy(false);_ = engine.nineKey(nine)
            for c in (nine ? "64426":"nihao").unicodeScalars{_ = engine.key(Int32(c.value))}
            let words=engine.candidateBatch(offset:0,limit:64).filter{$0.comment.replacingOccurrences(of:" ",with:"").replacingOccurrences(of:"'",with:"")=="nihao" && !engine.isPinned($0)}
            XCTAssertEqual(words.first?.text,"你好")
            engine.clear();for c in (nine ? "968":"you").unicodeScalars{_ = engine.key(Int32(c.value))}
            XCTAssertEqual(engine.candidateBatch(offset:0,limit:12).first?.text,"有")
        }
    }
    func testRecentInputReconstructionIsAtomicAndModeBounded() throws {
        let engine=try engine();defer{engine.clear();engine.finish()};_ = engine.privacy(true)
        for nine in [true,false] {
            _ = engine.nineKey(nine)
            let input=nine ? "64426":"nihao"
            XCTAssertTrue(engine.restoreRecentInput(input,nineKey:nine,context:"我说"))
            XCTAssertEqual(engine.rawInput,input);XCTAssertEqual(engine.precedingOwnText,"我说")
            XCTAssertFalse(engine.restoreRecentInput("xiexie",nineKey:nine,context:""));XCTAssertEqual(engine.rawInput,input)
            let word=try XCTUnwrap(engine.candidateBatch(offset:0,limit:64).first{$0.text=="你好"})
            XCTAssertEqual(engine.chooseCandidate(word),"你好")
            XCTAssertFalse(engine.restoreRecentInput(input,nineKey:!nine,context:""));XCTAssertTrue(engine.rawInput.isEmpty)
            XCTAssertFalse(engine.restoreRecentInput("ni\nhao",nineKey:nine,context:""));XCTAssertTrue(engine.rawInput.isEmpty)
            engine.resetPredictionContext()
        }
    }
    func testSystemSupplementsPreserveCommonChineseAndRejectStaleCandidates() throws {
        let engine=try engine();defer{engine.clear();engine.finish()};_ = engine.privacy(true)
        let words=SupplementaryLexicon(pairs:[("you","synthetic supplement"),("you","有"),("quanfou","synthetic phrase"),("lvming","吕明")])
        XCTAssertTrue(engine.setSupplementaryLexicon(words));_ = engine.nineKey(true)
        for c in "968".unicodeScalars{_ = engine.key(Int32(c.value))}
        let rows=engine.candidateBatch(offset:0,limit:64)
        XCTAssertEqual(rows.first?.text,"有");XCTAssertEqual(rows.filter{$0.text=="有"}.count,1)
        let extra=try XCTUnwrap(rows.first{$0.text=="synthetic supplement"});XCTAssertFalse(engine.canManage(extra))
        XCTAssertFalse(engine.setSupplementaryLexicon(SupplementaryLexicon(pairs:[])))
        XCTAssertEqual(engine.chooseCandidate(extra),"synthetic supplement");XCTAssertEqual(engine.chooseCandidate(extra),"")
        _ = engine.nineKey(false)
        for c in "lvming".unicodeScalars{_ = engine.key(Int32(c.value))}
        let name=try XCTUnwrap(engine.candidateBatch(offset:0,limit:32).first{$0.text=="吕明" && $0.supplementaryTrigger != nil})
        var forged=name;forged=InputCandidate(text:"forged",comment:name.comment,index:name.index,sourceInput:name.sourceInput,generation:name.generation,supplementaryTrigger:name.supplementaryTrigger)
        XCTAssertEqual(engine.chooseCandidate(forged),"");XCTAssertEqual(engine.rawInput,"lvming")
        XCTAssertEqual(engine.chooseCandidate(name),"吕明")
        XCTAssertTrue(engine.setSupplementaryLexicon(SupplementaryLexicon(pairs:[])))
        for c in "lvming".unicodeScalars{_ = engine.key(Int32(c.value))}
        XCTAssertFalse(engine.candidateBatch(offset:0,limit:32).contains{$0.supplementaryTrigger != nil})
    }
    func testMixedEnglishPreservesChinesePrefixAndRejectsStaleOrForgedCandidates() throws {
        let engine=try engine();defer { engine.clear();engine.finish() };_ = engine.privacy(true);_ = engine.nineKey(false);XCTAssertTrue(engine.setMixedEnglishEnabled(true))
        for c in "nihaoapi".unicodeScalars { _ = engine.key(Int32(c.value)) }
        let hello=try XCTUnwrap(engine.candidateBatch(offset:0,limit:128).first{$0.text=="你好"})
        XCTAssertEqual(engine.chooseCandidate(hello),"")
        let api=try XCTUnwrap(engine.candidateBatch(offset:0,limit:32).first{$0.text=="API" && $0.latinInput != nil})
        XCTAssertFalse(engine.canManage(api));XCTAssertEqual(engine.chooseCandidate(api),"你好API");XCTAssertTrue(engine.rawInput.isEmpty)
        XCTAssertEqual(engine.chooseCandidate(api),"")
        for c in "review".unicodeScalars { _ = engine.key(Int32(c.value)) }
        let word=try XCTUnwrap(engine.candidateBatch(offset:0,limit:32).first{$0.text=="review" && $0.latinInput != nil})
        XCTAssertEqual(engine.displayedPreedit(reading:""),"review")
        var forged=word;forged=InputCandidate(text:"forged",comment:word.comment,index:word.index,sourceInput:word.sourceInput,generation:word.generation,latinInput:word.latinInput)
        let raw=engine.rawInput;XCTAssertEqual(engine.chooseCandidate(forged),"");XCTAssertEqual(engine.rawInput,raw)
        _ = engine.key(115);let next=engine.rawInput;XCTAssertEqual(engine.chooseCandidate(word),"");XCTAssertEqual(engine.rawInput,next)
        engine.clear();for c in "xiexie".unicodeScalars { _ = engine.key(Int32(c.value)) }
        XCTAssertEqual(engine.chooseCandidate(try XCTUnwrap(engine.candidateBatch(offset:0,limit:32).first{$0.text=="谢谢"})),"谢谢")
        for c in "nihaoapi".unicodeScalars { _ = engine.key(Int32(c.value)) }
        let prefix=try XCTUnwrap(engine.candidateBatch(offset:0,limit:128).first{$0.text=="你好"})
        XCTAssertEqual(engine.chooseCandidate(prefix),"")
        XCTAssertEqual(engine.takeReadablePendingInput(reading:""),"你好api")
        let store=PersonalLexiconStore(directory:Self.storage),saved=try? Data(contentsOf:PersonalLexiconStore(directory:Self.storage).url)
        defer { if let saved { try? saved.write(to:store.url,options:.atomic) } else { try? FileManager.default.removeItem(at:store.url) } }
        var personal=PersonalLexicon();try personal.upsert(.init(kind:.phrase,text:"API",trigger:"api"));try store.save(personal)
        for c in "api".unicodeScalars { _ = engine.key(Int32(c.value)) }
        let duplicates=engine.candidateBatch(offset:0,limit:64).filter{$0.text=="API"}
        XCTAssertEqual(duplicates.count,1);XCTAssertNotNil(duplicates.first?.personalID)
    }
    func testMixedNineKeepsNativeCandidatesPagingAndHonorsSyllableLock() throws {
        let engine=try engine();defer { engine.clear();engine.finish() };_ = engine.privacy(true);_ = engine.nineKey(true)
        for c in "43556".unicodeScalars { _ = engine.key(Int32(c.value)) };let before=engine.candidateBatch(offset:0,limit:64)
        engine.clear();XCTAssertTrue(engine.setMixedEnglishEnabled(true))
        for c in "43556".unicodeScalars { _ = engine.key(Int32(c.value)) }
        let pages=stride(from:0,to:80,by:8).flatMap{engine.candidateBatch(offset:$0,limit:8)}
        XCTAssertNotNil(pages.first{$0.text=="hello" && $0.latinInput != nil})
        XCTAssertEqual(pages.first?.text,before.first?.text)
        for old in before { XCTAssertTrue(pages.contains{$0.text==old.text && $0.index==old.index}) }
        XCTAssertEqual(Set(pages.map{"\($0.index):\($0.text)"}).count,pages.count)
        let he=try XCTUnwrap(engine.nineSyllables.firstIndex(of:"he"));XCTAssertTrue(engine.selectNineSyllable(he))
        XCTAssertFalse(engine.candidateBatch(offset:0,limit:128).contains{$0.latinInput != nil})
        engine.clear();for c in "274".unicodeScalars { _ = engine.key(Int32(c.value)) }
        let initially=engine.candidateBatch(offset:0,limit:32)
        let englishSlot=try XCTUnwrap(initially.firstIndex{$0.text=="API" && $0.latinInput != nil})
        let fixedPrefix=Array(initially.prefix(englishSlot+1).map(\.text))
        finishPrediction(engine)
        XCTAssertEqual(Array(engine.candidateBatch(offset:0,limit:32).prefix(englishSlot+1).map(\.text)),fixedPrefix)
        let api=try XCTUnwrap(engine.candidateBatch(offset:0,limit:32).first{$0.text=="API" && $0.latinInput != nil})
        XCTAssertEqual(engine.chooseCandidate(api),"API")
        for c in "968".unicodeScalars { _ = engine.key(Int32(c.value)) };finishPrediction(engine)
        XCTAssertEqual(engine.candidateBatch(offset:0,limit:12).first?.text,"有")
    }
    func testMixedDictionaryCacheDisableCaretAndPureEnglishBoundaries() throws {
        var calls=0
        let resources=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"rime",withExtension:nil))
        let engine=NativeEngine(sharedResources:resources,storageBase:Self.storage,mixedEnglishProvider:{ raw in calls+=1;return raw=="rev" ? ["review"]:[] })
        defer { engine.clear();engine.finish() };_ = engine.nineKey(false);_ = engine.privacy(true);_ = engine.setMixedEnglishEnabled(true)
        for c in "rev".unicodeScalars { _ = engine.key(Int32(c.value)) }
        for _ in 0..<4 { XCTAssertTrue(engine.candidateBatch(offset:0,limit:12).contains{$0.text=="review" && $0.latinInput != nil}) }
        XCTAssertEqual(calls,1)
        let pending=engine.rawInput;XCTAssertFalse(engine.setMixedEnglishEnabled(false));XCTAssertEqual(engine.rawInput,pending)
        _ = engine.key(0xff51);XCTAssertFalse(engine.candidateBatch(offset:0,limit:32).contains{$0.latinInput != nil})
        engine.clear();XCTAssertTrue(engine.setMixedEnglishEnabled(false))
        for c in "review".unicodeScalars { _ = engine.key(Int32(c.value)) };XCTAssertFalse(engine.candidateBatch(offset:0,limit:32).contains{$0.latinInput != nil})
        engine.clear();_ = engine.setMixedEnglishEnabled(true);_ = engine.switchToEnglish(true)
        let commit=engine.key(104);XCTAssertFalse(commit.handled);XCTAssertTrue(commit.commit.isEmpty);XCTAssertTrue(engine.rawInput.isEmpty);XCTAssertTrue(engine.candidateBatch(offset:0,limit:32).isEmpty)
    }
    func testShortRecallComparisonKeepsDraftAndOriginalCandidates() throws {
        let fixtures=[("ming tian","明天"),("jin tian","今天"),("xie xie","谢谢"),("you yi xie","有一些"),("ke yi","可以"),("zhi dao","知道"),("shen me","什么"),("wei shen me","为什么"),("mei guan xi","没关系"),("shou dao","收到"),("xin ku","辛苦"),("yin su","因素"),("lian xi","联系"),("hui yi","会议")]
        let resources=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"rime",withExtension:nil))
        var rows:[[String:Any]]=[]
        for expanded in [false,true] {
            let engine=NativeEngine(sharedResources:resources,storageBase:Self.storage,expandedShortRecall:expanded)
            XCTAssertTrue(engine.ready);_ = engine.privacy(true);_ = engine.nineKey(true)
            for (reading,text) in fixtures {
                let code=try XCTUnwrap(NineKeySpelling.encode(reading)),chars=Array(code),middle=chars.count/2
                var extra=chars;extra.insert(chars[middle],at:middle)
                var missing=chars;missing.remove(at:middle)
                var swap=chars;swap.swapAt(middle-1,middle)
                for (kind,input) in [("clean",code),("extra",String(extra)),("missing",String(missing)),("swap",String(swap))] {
                    engine.clear();engine.resetPredictionContext()
                    for c in input.unicodeScalars { _ = engine.key(Int32(c.value)) }
                    let original=engine.candidateBatch(offset:0,limit:64);finishPrediction(engine)
                    let result=engine.candidateBatch(offset:0,limit:128)
                    XCTAssertEqual(engine.rawInput,input)
                    for old in original { XCTAssertTrue(result.contains{$0.text==old.text && $0.index==old.index}) }
                    rows.append(["expanded":expanded,"expected":text,"kind":kind,"rank":result.firstIndex{$0.text==text} ?? -1,"queries":engine.predictionQueryCount,"elapsedMS":engine.predictionElapsedMS,"maxSliceMS":engine.predictionMaxSliceMS])
                }
            }
            engine.clear();engine.finish()
        }
        let before=rows.filter{($0["expanded"] as? Bool)==false},after=rows.filter{($0["expanded"] as? Bool)==true}
        for old in before where (old["rank"] as? Int ?? -1)>=0 {
            let new=after.first{$0["expected"] as? String==old["expected"] as? String && $0["kind"] as? String==old["kind"] as? String}
            XCTAssertGreaterThanOrEqual(new?["rank"] as? Int ?? -1,0,"Extra recall must retain known short fixtures")
        }
        XCTAssertGreaterThanOrEqual(after.first{$0["expected"] as? String=="知道" && $0["kind"] as? String=="missing"}?["rank"] as? Int ?? -1,0)
        try Self.saveDiagnostic(rows,name:"short-recall")
    }
    func testPersonalTermsAndPhrasesCommitOnceInBothLayoutsAndKeepNativeTail() throws {
        let store=PersonalLexiconStore(directory:Self.storage)
        var lexicon=PersonalLexicon()
        try lexicon.upsert(.init(kind:.word,text:"拟好",trigger:"ni hao"))
        try lexicon.upsert(.init(kind:.word,text:"米好",trigger:"mi hao"))
        try lexicon.upsert(.init(kind:.phrase,text:"合成地址\n请先联系",trigger:"dz"))
        try store.save(lexicon);defer { try? store.save(PersonalLexicon()) }
        let engine=try engine();defer { engine.clear();engine.finish() };_ = engine.privacy(true)
        for nine in [true,false] {
            _ = engine.nineKey(nine)
            for c in (nine ? "64426":"nihao").unicodeScalars { _ = engine.key(Int32(c.value)) }
            let before=engine.candidateBatch(offset:0,limit:256)
            print("SYNTHETIC_PERSONAL nine=\(nine) raw=\(engine.rawInput) pending=\(engine.preedit) active=\(engine.predictionScope) rows=\(before.prefix(4).map(\.text))")
            XCTAssertEqual(before.first?.text,"拟好");XCTAssertTrue(before.contains{$0.text=="你好"})
            if nine { finishPrediction(engine);XCTAssertEqual(engine.candidateBatch(offset:0,limit:12).first?.text,"拟好") }
            let candidate=try XCTUnwrap(engine.candidateBatch(offset:0,limit:12).first{$0.text=="拟好"})
            XCTAssertFalse(engine.canManage(candidate));XCTAssertEqual(engine.chooseCandidate(candidate),"拟好")
            XCTAssertTrue(engine.rawInput.isEmpty);XCTAssertEqual(engine.chooseCandidate(candidate),"")
            for c in (nine ? "39":"dz").unicodeScalars { _ = engine.key(Int32(c.value)) }
            let phrase=try XCTUnwrap(engine.candidateBatch(offset:0,limit:12).first{$0.personalID != nil})
            XCTAssertEqual(engine.chooseCandidate(phrase),"合成地址\n请先联系")
        }
    }
    func testPersonalLexiconFilterSelectedPrefixDeletionAndRevocation() throws {
        let store=PersonalLexiconStore(directory:Self.storage);var lexicon=PersonalLexicon()
        try lexicon.upsert(.init(kind:.word,text:"拟好",trigger:"ni hao"))
        try lexicon.upsert(.init(kind:.word,text:"米好",trigger:"mi hao"))
        try lexicon.upsert(.init(kind:.word,text:"世届",trigger:"shi jie"))
        try store.save(lexicon);defer { try? store.save(PersonalLexicon()) }
        let engine=try engine();defer { engine.clear();engine.finish() };_ = engine.nineKey(true)
        for c in "64426".unicodeScalars { _ = engine.key(Int32(c.value)) }
        let ni=try XCTUnwrap(engine.nineSyllables.firstIndex(of:"ni"));XCTAssertTrue(engine.selectNineSyllable(ni))
        let rows=engine.candidateBatch(offset:0,limit:12)
        XCTAssertNotNil(rows.first{$0.text=="拟好"});XCTAssertNil(rows.first{$0.text=="米好"})
        let stale=try XCTUnwrap(rows.first{$0.personalID != nil});_ = engine.key(50)
        let pending=engine.rawInput;XCTAssertEqual(engine.chooseCandidate(stale),"");XCTAssertEqual(engine.rawInput,pending)
        engine.clear()
        for c in "64426744543".unicodeScalars { _ = engine.key(Int32(c.value)) }
        let hello=try XCTUnwrap(engine.candidateBatch(offset:0,limit:128).first{$0.text=="你好"})
        XCTAssertEqual(engine.chooseCandidate(hello),"")
        let world=try XCTUnwrap(engine.candidateBatch(offset:0,limit:12).first{$0.text=="世届"})
        XCTAssertEqual(engine.chooseCandidate(world),"你好世届")
        XCTAssertTrue(engine.nineKey(false))
        for c in "nihaoshijie".unicodeScalars { _ = engine.key(Int32(c.value)) }
        let hello26=try XCTUnwrap(engine.candidateBatch(offset:0,limit:128).first{$0.text=="你好"})
        XCTAssertEqual(engine.chooseCandidate(hello26),"")
        let world26=try XCTUnwrap(engine.candidateBatch(offset:0,limit:12).first{$0.text=="世届"})
        XCTAssertEqual(engine.chooseCandidate(world26),"你好世届")
        XCTAssertTrue(engine.nineKey(true))
        for c in "64426".unicodeScalars { _ = engine.key(Int32(c.value)) }
        let revoked=try XCTUnwrap(engine.candidateBatch(offset:0,limit:12).first{$0.personalID != nil})
        try store.save(PersonalLexicon());let raw=engine.rawInput
        XCTAssertEqual(engine.chooseCandidate(revoked),"");XCTAssertEqual(engine.rawInput,raw)
        engine.clear();for c in "64426".unicodeScalars { _ = engine.key(Int32(c.value)) }
        XCTAssertFalse(engine.candidateBatch(offset:0,limit:12).contains{$0.personalID != nil})
    }
    func testPinyin26PartialWordRetainsWorldCandidate() throws {
        let engine=try engine();defer { engine.clear();engine.finish() };_ = engine.privacy(true);_ = engine.nineKey(false)
        for c in "nihaoshijie".unicodeScalars { _ = engine.key(Int32(c.value)) }
        let hello=try XCTUnwrap(engine.candidateBatch(offset:0,limit:128).first{$0.text=="你好"})
        XCTAssertEqual(engine.chooseCandidate(hello),"")
        let remaining=engine.candidateBatch(offset:0,limit:128)
        print("SYNTHETIC_PARTIAL26 raw=\(engine.rawInput) preedit=\(engine.preedit) candidates=\(remaining.prefix(12).map{$0.text})")
        let world=try XCTUnwrap(remaining.first{$0.text=="世界"});XCTAssertEqual(engine.chooseCandidate(world),"你好世界")
    }
    func testLearnedPinyin26PartialWordAfterExpandedPaging() throws {
        let engine=try engine();defer { engine.clear();engine.finish() };_ = engine.nineKey(false)
        for c in "nihao".unicodeScalars { _ = engine.key(Int32(c.value)) }
        let learned=try XCTUnwrap(engine.candidateBatch(offset:0,limit:12).first{$0.text=="你好"})
        try engine.manage(learned,pinned:true)
        defer { try? engine.manage(learned,pinned:false) }
        XCTAssertEqual(engine.chooseCandidate(try XCTUnwrap(engine.candidateBatch(offset:0,limit:12).first{$0.text=="你好"})),"你好")
        for c in "nihaoshijie".unicodeScalars { _ = engine.key(Int32(c.value)) }
        let before=engine.candidateBatch(offset:0,limit:12);_ = engine.candidateBatch(offset:12,limit:48)
        let hello=try XCTUnwrap(before.first{$0.text=="你好"});engine.cancelNinePrediction()
        XCTAssertEqual(engine.chooseCandidate(hello),"")
        let after=engine.candidateBatch(offset:0,limit:48)
        print("SYNTHETIC_PAGING_PARTIAL \(after.prefix(6).map{$0.text})")
        XCTAssertNotNil(after.first{$0.text=="世界"})
    }
    private static func saveDiagnostic(_ rows:[[String:Any]],name:String) throws {
        var root=URL(fileURLWithPath:#filePath);for _ in 0..<4 { root.deleteLastPathComponent() }
        let directory=root.appendingPathComponent("evidence/native-diagnostics")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let file=directory.appendingPathComponent(UUID().uuidString+"-"+name+".json")
        try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:file)
        print("DIAGNOSTIC_ARTIFACT "+file.lastPathComponent)
    }
    func testManualNineFilterIncludesNonPredictedReadingsAndRetainsTail() throws {
        let engine=try engine();defer { engine.clear();engine.finish() };_ = engine.privacy(true);_ = engine.nineKey(true)
        for c in "782636874472666".unicodeScalars { _ = engine.key(Int32(c.value)) }
        let quan=try XCTUnwrap(engine.nineSyllables.firstIndex(of:"quan"));XCTAssertTrue(engine.selectNineSyllable(quan))
        finishPrediction(engine)
        XCTAssertTrue(Set(["dou","e","en","fo","fou"]).isSubset(of:Set(engine.nineSyllables)))
        let fou=try XCTUnwrap(engine.nineSyllables.firstIndex(of:"fou"));XCTAssertTrue(engine.selectNineSyllable(fou))
        XCTAssertEqual(engine.rawInput,"quan'fou'74472666")
        _ = engine.key(0xff08);XCTAssertEqual(engine.rawInput,"quan'36874472666")
        for reading in ["dou","shi","pao","mo"] {
            let index=try XCTUnwrap(engine.nineSyllables.firstIndex(of:reading));XCTAssertTrue(engine.selectNineSyllable(index))
        }
        XCTAssertEqual(engine.rawInput,"quan'dou'shi'pao'mo'")
        engine.clear()
        for c in "7826368".unicodeScalars { _ = engine.key(Int32(c.value)) }
        let first=try XCTUnwrap(engine.nineSyllables.firstIndex(of:"quan"));XCTAssertTrue(engine.selectNineSyllable(first))
        let whole=try XCTUnwrap(engine.candidateBatch(offset:0,limit:128).first{$0.text=="全"})
        XCTAssertEqual(engine.chooseCandidate(whole),"")
        let alternative=try XCTUnwrap(engine.nineSyllables.firstIndex(of:"fou"));XCTAssertTrue(engine.selectNineSyllable(alternative))
        let negative=try XCTUnwrap(engine.candidateBatch(offset:0,limit:128).first{$0.text=="否"})
        XCTAssertEqual(engine.chooseCandidate(negative),"全否")
    }
    func testSyntheticQualityAblation() throws {
        let fixtures=[("wo men xia ge xing qi zai lian xi","我们下个星期再联系"),("qing ba di zhi zai fa yi bian","请把地址再发一遍"),("hui yi jie shu hou zai tao lun","会议结束后再讨论"),("jin tian wan shang zao dian xiu xi","今天晚上早点休息"),("wo xiang mai yi ben xin shu","我想买一本新书"),("zhe ge di fang bi jiao an jing","这个地方比较安静"),("ming tian ji de dai shang yu san","明天记得带上雨伞"),("wo yi jing ba dong xi zhun bei hao le","我已经把东西准备好了")]
        let resources=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"rime",withExtension:nil))
        var rows:[[String:Any]]=[]
        for (label,semantic,lexicon) in [("baseline24",false,false),("lexicalOnly",false,true),("semanticAndLexical",true,true)] {
            let engine=NativeEngine(sharedResources:resources,storageBase:Self.storage,useSemantic:semantic,useLexicon:lexicon);XCTAssertTrue(engine.ready);_ = engine.privacy(true);_ = engine.nineKey(true)
            for (reading,expected) in fixtures {
                let code=try XCTUnwrap(NineKeySpelling.encode(reading)),original=Array(code),middle=original.count/2
                var extra=original;extra.insert(extra[middle],at:middle)
                var missing=original;missing.remove(at:middle)
                var swapped=original
                if let i=(1..<original.count-1).min(by:{abs($0-middle)<abs($1-middle)}),swapped[i] != swapped[i+1] { swapped.swapAt(i,i+1) } else { swapped.swapAt(0,1) }
                var double=original;double.insert(double[double.count-2],at:double.count-2);double.remove(at:2)
                for (kind,source) in [("clean",code),("extra",String(extra)),("missing",String(missing)),("swap",String(swapped)),("double",String(double))] {
                    engine.clear();engine.resetPredictionContext();for c in source.unicodeScalars { _ = engine.key(Int32(c.value)) }
                    let originals=engine.candidateBatch(offset:0,limit:64);finishPrediction(engine);let values=engine.candidateBatch(offset:0,limit:160)
                    XCTAssertEqual(engine.rawInput,source)
                    for candidate in originals { XCTAssertTrue(values.contains{$0.index==candidate.index && $0.text==candidate.text}) }
                    rows.append(["configuration":label,"kind":kind,"expected":expected,"code":source,"rank":values.firstIndex{$0.text==expected} ?? -1,"elapsedMS":engine.predictionElapsedMS,"maxSliceMS":engine.predictionMaxSliceMS,"semanticBatches":engine.semanticBatches,"assemblies":engine.assembledCandidateCount,"queries":engine.predictionQueryCount,"firstNative":originals.first?.text ?? "","firstReading":originals.first?.comment ?? "","firstSemanticScore":engine.semanticScores[originals.first?.text ?? ""] ?? 1,"tokenScores":engine.semanticScores.keys.filter{$0.contains("#")}.count,"footprintMB":engine.predictionFootprintMB,"peakMB":Double(pi_process_peak_memory_footprint())/1048576])
                }
            }
            engine.clear();engine.finish()
        }
        try Self.saveDiagnostic(rows,name:"ablation")
    }
    func testAssembledSentenceCommitsAtomicallyAndRejectsStaleSelection() throws {
        let engine=try engine();defer { engine.clear();engine.finish() };_ = engine.privacy(true);_ = engine.nineKey(true)
        let code=try XCTUnwrap(NineKeySpelling.encode("qing ba di zhi zai fa yi bian"))
        for c in code.unicodeScalars { _ = engine.key(Int32(c.value)) };finishPrediction(engine)
        let candidate=try XCTUnwrap(engine.candidateBatch(offset:0,limit:160).first{$0.text=="请把地址再发一遍"})
        XCTAssertNotNil(candidate.assemblyID);XCTAssertEqual(engine.rawInput,code)
        XCTAssertEqual(engine.chooseCandidate(candidate),"请把地址再发一遍");XCTAssertTrue(engine.rawInput.isEmpty)
        XCTAssertEqual(engine.chooseCandidate(candidate),"")
        engine.resetPredictionContext();for c in code.unicodeScalars { _ = engine.key(Int32(c.value)) };finishPrediction(engine)
        let stale=try XCTUnwrap(engine.candidateBatch(offset:0,limit:160).first{$0.assemblyID != nil})
        _ = engine.key(50);let after=engine.rawInput;XCTAssertEqual(engine.chooseCandidate(stale),"");XCTAssertEqual(engine.rawInput,after)
    }
    func testAssembledSentenceRetainsSelectedPrefixAndLearnsOnlyOnSelection() throws {
        let engine=try engine();defer { engine.clear();engine.finish() };_ = engine.nineKey(true);_ = engine.privacy(false)
        let file=Self.storage.appendingPathComponent("nine-choice-memory-v3.json"),before=try? Data(contentsOf:file)
        let code=try XCTUnwrap(NineKeySpelling.encode("qing ba di zhi zai fa yi bian"))
        for c in code.unicodeScalars { _ = engine.key(Int32(c.value)) }
        let please=try XCTUnwrap(engine.candidateBatch(offset:0,limit:128).first{$0.text=="请"});XCTAssertEqual(engine.chooseAbsolute(please.index),"")
        let original=engine.rawInput;let native=engine.candidateBatch(offset:0,limit:8);finishPrediction(engine)
        print("SYNTHETIC_PREFIX scope=\(engine.predictionScope) input=\(original) preedit=\(engine.preedit) original=\(native.map{$0.text+":"+$0.comment}) final=\(engine.candidateBatch(offset:0,limit:50).map(\.text)) assemblies=\(engine.assembledCandidateCount) batches=\(engine.semanticBatches)")
        let target=try XCTUnwrap(engine.candidateBatch(offset:0,limit:160).first{$0.text=="把地址再发一遍"})
        XCTAssertNotNil(target.assemblyID);XCTAssertEqual(try? Data(contentsOf:file),before);XCTAssertEqual(engine.rawInput,original)
        XCTAssertEqual(engine.chooseCandidate(target),"请把地址再发一遍");XCTAssertTrue(engine.rawInput.isEmpty);XCTAssertEqual(pi_active_session_count(),1)
        let learned=try JSONDecoder().decode(NineKeyChoiceMemory.self,from:Data(contentsOf:file));XCTAssertTrue(learned.entries.contains{$0.text==target.text})
        try engine.manage(target,pinned:true);XCTAssertTrue(engine.isPinned(target))
        try engine.manage(target,pinned:nil)
        let reset=try JSONDecoder().decode(NineKeyChoiceMemory.self,from:Data(contentsOf:file));XCTAssertFalse(reset.entries.contains{$0.text==target.text})
        try engine.manage(target,pinned:false)
    }
    func testMissingSemanticResourcesFallBackWithoutBlockingTyping() {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let ranker=SemanticRanker(directory:directory);XCTAssertFalse(ranker.configured)
        let finished=expectation(description:"No model fallback")
        ranker.evaluate([.init(id:"test",before:"",text:"合成句子",after:"")]) { scores,metrics in
            XCTAssertTrue(scores.isEmpty);XCTAssertFalse(metrics.available);finished.fulfill()
        }
        wait(for:[finished],timeout:1)
    }
    func testCommonYouPathStaysAheadOfUnrequestedKeyEdits() throws {
        let engine=try engine();defer { engine.clear();engine.finish() };_ = engine.privacy(true);_ = engine.nineKey(true)
        var rows:[[String:Any]]=[]
        for reading in ["you","you yi xie yin su","you xie yin su","wo bu","you jia","zou lang"] {
            let code=try XCTUnwrap(NineKeySpelling.encode(reading));engine.clear();engine.resetPredictionContext()
            for c in code.unicodeScalars {
                _ = engine.key(Int32(c.value))
                let before=engine.candidateBatch(offset:0,limit:12);finishPrediction(engine)
                let after=engine.candidateBatch(offset:0,limit:12)
                rows.append(["fixture":reading,"code":engine.rawInput,"native":before.prefix(4).map{$0.text+"|"+$0.comment},"ranked":after.prefix(4).map{$0.text+"|"+$0.comment},"semantic":after.prefix(4).map{engine.semanticScores[$0.text] ?? 1}])
                if engine.rawInput=="968" { XCTAssertEqual(after.first?.text,"有");XCTAssertEqual(after.first?.comment,"you") }
                if engine.rawInput=="96894943" { XCTAssertEqual(after.first?.text,"有一些") }
                if reading=="you yi xie yin su",engine.rawInput==code { XCTAssertEqual(after.first?.text,"有一些因素") }
                if reading=="wo bu",engine.rawInput==code { XCTAssertEqual(after.first?.text,"我不") }
                if reading=="zou lang",engine.rawInput==code { XCTAssertEqual(after.first?.text,"走廊") }
                if reading=="you jia",engine.rawInput==code { XCTAssertTrue(after.contains{$0.text=="油价"}) }
                if reading=="you",engine.rawInput==code { XCTAssertTrue(after.contains{$0.text=="又"});XCTAssertTrue(after.contains{$0.text=="走"}) }
            }
        }
        try Self.saveDiagnostic(rows,name:"you")
    }
    func testIncrementalDisplayNeverBreaksCleanNineCandidateCommit() throws {
        let engine=try engine();defer { engine.clear();engine.finish() };_ = engine.privacy(true);_ = engine.nineKey(true)
        for digit in "64426".unicodeScalars {
            _ = engine.key(Int32(digit.value))
            let rows=engine.candidateBatch(offset:0,limit:12)
            _ = engine.displayedPreedit(reading:rows.first?.comment ?? "")
            _ = engine.nineSyllables
        }
        finishPrediction(engine)
        let target=try XCTUnwrap(engine.candidateBatch(offset:0,limit:96).first{$0.text=="你好"})
        XCTAssertEqual(engine.rawInput,"64426");XCTAssertEqual(engine.chooseCandidate(target),"你好")
    }
    func testContinuationAfterPunctuationIsExplicitAndRejectsOldContext() throws {
        let engine=try engine();defer { engine.clear();engine.finish() }
        _ = engine.privacy(true);_ = engine.nineKey(true)
        engine.confirmOwnCommitContext(previous:"",text:"如果明天下雨")
        engine.noteLiteralInput("，")
        XCTAssertEqual(engine.precedingOwnText,"如果明天下雨，")
        let initial=engine.continuationBatch()
        XCTAssertTrue(initial.contains{$0.text=="就"});XCTAssertTrue(engine.rawInput.isEmpty)
        let completed=expectation(description:"Local continuation ranking")
        engine.rankContinuations { completed.fulfill() };wait(for:[completed],timeout:20)
        let candidate=try XCTUnwrap(engine.continuationBatch().first{$0.text=="就"})
        XCTAssertEqual(engine.chooseContinuation(candidate),"就")
        XCTAssertEqual(engine.precedingOwnText,"如果明天下雨，就")
        XCTAssertEqual(engine.chooseContinuation(candidate),"")
        engine.resetPredictionContext();XCTAssertTrue(engine.continuationBatch().isEmpty)
        engine.confirmOwnCommitContext(previous:"",text:"因为今天下雨，")
        let stale=try XCTUnwrap(engine.continuationBatch().first)
        _ = engine.key(54)
        XCTAssertEqual(engine.chooseContinuation(stale),"");XCTAssertEqual(engine.rawInput,"6")
    }
    func testLongerContextChangesNeuralScoresWithSameImmediateSuffix() throws {
        let directory=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"semantic",withExtension:nil)),ranker=SemanticRanker(directory:directory)
        let contexts=["设计师要先做一个可交互的样机，大家讨论的是","图案没有棱角而且半径相等，大家讨论的是"]
        let candidates=["一个原型","一个圆形"]
        var requests:[SemanticRanker.Request]=[]
        for i in 0..<2 { for j in 0..<2 { requests.append(.init(id:"\(i)-\(j)",before:contexts[i],text:candidates[j],after:"")) } }
        let finished=expectation(description:"Context inference")
        ranker.evaluate(requests) { scores,metrics in
            XCTAssertGreaterThan(metrics.batches,0);XCTAssertEqual(scores.count,4)
            XCTAssertNotEqual(scores["0-0"],scores["1-0"])
            print("SYNTHETIC_CONTEXT prototype_a=\(scores["0-0"] ?? .nan) circle_a=\(scores["0-1"] ?? .nan) prototype_b=\(scores["1-0"] ?? .nan) circle_b=\(scores["1-1"] ?? .nan)")
            finished.fulfill()
        }
        wait(for:[finished],timeout:20);ranker.suspend()
    }
    func testPublicLexiconRecoversPreviouslyUnqueriedReading() throws {
        let directory=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"semantic",withExtension:nil))
        let lexicon=try NineKeyLexicon(url:directory.appendingPathComponent("nine-lexicon.bin"))
        XCTAssertGreaterThanOrEqual(lexicon.frequency("5468426"),110731)
        let alternatives=lexicon.alternatives("548426")
        XCTAssertTrue(alternatives.contains{$0.input=="5468426"})
        XCTAssertTrue(alternatives.allSatisfy{NineKeySpelling.editCost("548426",$0.input) != nil})
        XCTAssertTrue(lexicon.alternatives("nihao").isEmpty)
    }
    func testRealNeuralModelAndCancellation() throws {
        let directory=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"semantic",withExtension:nil))
        let ranker=SemanticRanker(directory:directory);XCTAssertTrue(ranker.configured)
        let completed=expectation(description:"Real Core ML inference")
        ranker.evaluate([.init(id:"good",before:"",text:"我想喝水",after:""),.init(id:"bad",before:"",text:"我想和税",after:"")]) { values,metrics in
            XCTAssertTrue(metrics.available);XCTAssertGreaterThan(metrics.batches,0)
            XCTAssertGreaterThan(values["good"] ?? -.infinity,values["bad"] ?? .infinity);completed.fulfill()
        }
        wait(for:[completed],timeout:20)
        let cancelled=expectation(description:"Cancelled inference must not publish");cancelled.isInverted=true
        ranker.evaluate([.init(id:"old",before:"",text:"测试旧请求",after:"")]) { _,_ in cancelled.fulfill() };ranker.cancel()
        wait(for:[cancelled],timeout:0.15);ranker.suspend()
    }
    func testSyntheticSemanticBaselineComparison() throws {
        let engine=try engine();defer { engine.finish() };XCTAssertTrue(engine.languageModelReady)
        var root=URL(fileURLWithPath:#filePath);for _ in 0..<4 { root.deleteLastPathComponent() }
        let pairs=try JSONDecoder().decode([[String]].self,from:Data(contentsOf:root.appendingPathComponent("experiments/semantic/sentence_pairs.json")))
        var rows:[[String:Any]]=[]
        for pair in pairs {
            let a=pi_language_score("",pair[0]),b=pi_language_score("",pair[1]);XCTAssertTrue(a.isFinite && b.isFinite)
            rows.append(["preferred":pair[0],"contrast":pair[1],"preferredScore":a,"contrastScore":b,"orderedCorrectly":a>b])
        }
        try Self.saveDiagnostic(rows,name:"octagram-pairs")
    }
    func testMaximumNumericTailCompletesAndCancellationPreservesEvents() throws {
        let engine=try engine();defer { engine.clear();_ = engine.privacy(false);engine.finish() };_ = engine.privacy(true);_ = engine.nineKey(true)
        let code=String(repeating:"64426",count:19)
        for c in code.unicodeScalars { _ = engine.key(Int32(c.value)) }
        finishPrediction(engine)
        XCTAssertEqual(engine.rawInput,code);XCTAssertLessThanOrEqual(engine.predictionQueryCount,240)
        print("SYNTHETIC_MAX_TAIL elapsed_ms=\(engine.predictionElapsedMS) slice_ms=\(engine.predictionMaxSliceMS) queries=\(engine.predictionQueryCount) footprint_mb=\(engine.predictionFootprintMB)")
        _ = engine.key(54);XCTAssertEqual(engine.rawInput.count,96)
        XCTAssertTrue(engine.beginNinePrediction());_ = engine.advanceNinePrediction(timeBudget:0);engine.cancelNinePrediction()
        _ = engine.key(0xff08);XCTAssertEqual(engine.rawInput,code)
    }
    func testJointCorrectionSyntheticMatrixAndDraftSafety() throws {
        let engine=try engine();defer { engine.clear();_ = engine.privacy(false);engine.finish() }
        _ = engine.privacy(true);_ = engine.nineKey(true)
        // Public phrases and deterministic errors, never user text. Discovery
        // matrix records coverage separately from invariants and accuracy claims.
        for reading in ["ni hao wo xiang he shui","jin tian xia wu wo men yi qi chi fan","wo men ming tian zai jian"] {
            let code=try XCTUnwrap(NineKeySpelling.encode(reading))
            engine.clear();engine.resetPredictionContext()
            for c in code.unicodeScalars { _ = engine.key(Int32(c.value)) }
            let baseline=engine.candidateBatch(offset:0,limit:32).first{NineKeySpelling.encode($0.comment)==code}
            var wrong=Array(code);wrong.insert(wrong[wrong.count-2],at:wrong.count-2);wrong.remove(at:2)
            let source=String(wrong);engine.clear()
            for c in source.unicodeScalars { _ = engine.key(Int32(c.value)) }
            let originals=engine.candidateBatch(offset:0,limit:64)
            finishPrediction(engine)
            let result=engine.candidateBatch(offset:0,limit:128)
            XCTAssertEqual(engine.rawInput,source)
            for old in originals { XCTAssertTrue(result.contains{$0.index==old.index && $0.text==old.text}) }
            let rank=baseline.flatMap{ item in result.firstIndex{$0.text==item.text && $0.replacementInput==code} }
            print("SYNTHETIC_NEURAL batches=\(engine.semanticBatches) ms=\(engine.semanticElapsedMS) expected_score=\(engine.semanticScores[baseline?.text ?? ""] ?? .nan)")
            print("SYNTHETIC_JOINT reading=\(reading) recovered_rank=\(rank ?? -1) elapsed_ms=\(engine.predictionElapsedMS) slice_ms=\(engine.predictionMaxSliceMS) footprint_mb=\(engine.predictionFootprintMB)")
            XCTAssertLessThanOrEqual(engine.predictionQueryCount,240)
            XCTAssertNotNil(rank,"Semantic/lexical recall must retain old cases and recover the previous miss")
            XCTAssertGreaterThan(engine.semanticBatches,0)
            if let rank { XCTAssertEqual(engine.chooseCandidate(result[rank]),baseline!.text) }
        }
    }
    func testJointChoiceLearnsConfirmedDirectionAndResetsWithoutTouchingOldFile() throws {
        let engine=try engine();defer { engine.clear();engine.finish() };_ = engine.privacy(false);_ = engine.nineKey(true)
        engine.resetPredictionContext();let source="642696942644374884"
        for c in source.unicodeScalars { _ = engine.key(Int32(c.value)) };finishPrediction(engine)
        let target=try XCTUnwrap(engine.candidateBatch(offset:0,limit:96).first{$0.text=="你好我想喝水" && $0.replacementInput != nil})
        XCTAssertEqual(engine.chooseCandidate(target),target.text)
        let file=Self.storage.appendingPathComponent("nine-choice-memory-v3.json")
        let memory=try JSONDecoder().decode(NineKeyChoiceMemory.self,from:Data(contentsOf:file))
        XCTAssertTrue(memory.entries.contains{$0.code==source && $0.text==target.text && $0.count>=2})
        engine.resetPredictionContext();for c in source.unicodeScalars { _ = engine.key(Int32(c.value)) };finishPrediction(engine)
        XCTAssertTrue(engine.candidateBatch(offset:0,limit:96).contains{$0.text==target.text && $0.replacementInput != nil})
        try engine.manage(target,pinned:nil)
        let reset=try JSONDecoder().decode(NineKeyChoiceMemory.self,from:Data(contentsOf:file));XCTAssertFalse(reset.entries.contains{$0.code==source && $0.text==target.text})
    }
    func testV2MigrationKeepsOriginalAndCorruptV3CannotResurrectV2() throws {
        let v2=Self.storage.appendingPathComponent("nine-choice-memory-v2.json"),v3=Self.storage.appendingPathComponent("nine-choice-memory-v3.json")
        try FileManager.default.createDirectory(at:Self.storage,withIntermediateDirectories:true)
        let old2=try? Data(contentsOf:v2),old3=try? Data(contentsOf:v3)
        defer { for (file,data) in [(v2,old2),(v3,old3)] { if let data { try? data.write(to:file) } else { try? FileManager.default.removeItem(at:file) } } }
        try? FileManager.default.removeItem(at:v3)
        let data=Data(#"{"version":2,"entries":[{"code":"64425","reading":"nihao","text":"你好","context":"今天我说","count":8}]}"#.utf8)
        try data.write(to:v2)
        let migrated=try engine();migrated.finish()
        XCTAssertEqual(try Data(contentsOf:v2),data)
        let new=try JSONDecoder().decode(NineKeyChoiceMemory.self,from:Data(contentsOf:v3));XCTAssertEqual(new.version,3);XCTAssertEqual(new.entries.first?.count,8)
        let broken=Data("synthetic-corrupt-v3".utf8);try broken.write(to:v3)
        let typing=try engine();defer { typing.clear();typing.finish() };_ = typing.nineKey(true)
        for c in "64426".unicodeScalars { _ = typing.key(Int32(c.value)) }
        let target=try XCTUnwrap(typing.candidateBatch(offset:0,limit:32).first{$0.text=="你好"});XCTAssertEqual(typing.chooseCandidate(target),"你好")
        XCTAssertEqual(try Data(contentsOf:v3),broken);XCTAssertEqual(try Data(contentsOf:v2),data)
    }
    func testLegacyChoiceFileMigrationAndCorruptNewFilePreserveData() throws {
        let legacy=Self.storage.appendingPathComponent("nine-choice-memory-v1.json"),current=Self.storage.appendingPathComponent("nine-choice-memory-v3.json")
        try FileManager.default.createDirectory(at:Self.storage,withIntermediateDirectories:true)
        let originalLegacy=try? Data(contentsOf:legacy),originalCurrent=try? Data(contentsOf:current)
        defer {
            for (file,data) in [(legacy,originalLegacy),(current,originalCurrent)] {
                if let data { try? data.write(to:file,options:.atomic) } else { try? FileManager.default.removeItem(at:file) }
            }
        }
        try? FileManager.default.removeItem(at:current)
        let data=Data(#"{"version":1,"entries":[{"code":"64425","reading":"nihao","text":"你好","context":"","count":5}]}"#.utf8)
        try data.write(to:legacy,options:.atomic)
        let migrated=try engine();migrated.finish()
        XCTAssertEqual(try Data(contentsOf:legacy),data)
        let decoded=try JSONDecoder().decode(NineKeyChoiceMemory.self,from:Data(contentsOf:current));XCTAssertEqual(decoded.version,3);XCTAssertEqual(decoded.entries.first?.count,5)
        let broken=Data("synthetic-corrupt-v2".utf8);try broken.write(to:current,options:.atomic)
        let fallback=try engine();defer { fallback.clear();fallback.finish() };_ = fallback.nineKey(true)
        for c in "64426".unicodeScalars { _ = fallback.key(Int32(c.value)) }
        let candidate=try XCTUnwrap(fallback.candidateBatch(offset:0,limit:32).first{$0.text=="你好"})
        XCTAssertEqual(fallback.chooseCandidate(candidate),"你好");XCTAssertEqual(try Data(contentsOf:current),broken)
    }
    func testLongCodeCorrectionAndCommaContextWithoutRewritingDraft() throws {
        let engine=try engine();defer { engine.clear();_ = engine.privacy(false);engine.finish() }
        _ = engine.privacy(true);_ = engine.nineKey(true)
        let code=try XCTUnwrap(NineKeySpelling.encode("jin tian xia wu wo men yi qi chi fan"))
        XCTAssertGreaterThan(code.count,24)
        for c in code.unicodeScalars { _ = engine.key(Int32(c.value)) }
        let baseline=try XCTUnwrap(engine.candidateBatch(offset:0,limit:32).first{NineKeySpelling.encode($0.comment)==code})
        engine.clear();let mistyped=code+String(code.last!)
        for c in mistyped.unicodeScalars { _ = engine.key(Int32(c.value)) }
        finishPrediction(engine)
        let target=try XCTUnwrap(engine.candidateBatch(offset:0,limit:96).first{$0.text==baseline.text})
        XCTAssertEqual(engine.rawInput,mistyped);XCTAssertEqual(engine.chooseCandidate(target),baseline.text)
        let before=engine.precedingOwnText;engine.noteLiteralInput("，")
        XCTAssertEqual(engine.precedingOwnText,before+"，")
        engine.confirmOwnCommitContext(previous:before+"，",text:"然后继续")
        XCTAssertTrue(engine.precedingOwnText.contains("，然后继续"))
    }
    func testCorrectionsRetainSelectedChineseAndLockedReading() throws {
        let engine=try engine();defer { engine.clear();engine.finish() };_ = engine.nineKey(true)
        for c in "64425".unicodeScalars { _ = engine.key(Int32(c.value)) }
        let ni=try XCTUnwrap(engine.candidateBatch(offset:0,limit:64).first{$0.text=="你"})
        XCTAssertEqual(engine.chooseAbsolute(ni.index),"")
        XCTAssertTrue(engine.preedit.hasPrefix("你"));let original=engine.rawInput
        finishPrediction(engine)
        let hao=try XCTUnwrap(engine.candidateBatch(offset:0,limit:96).first{$0.text=="好" && $0.replacementInput != nil})
        XCTAssertEqual(engine.rawInput,original);XCTAssertTrue(engine.preedit.hasPrefix("你"))
        XCTAssertEqual(engine.chooseCandidate(hao),"你好")
        engine.resetPredictionContext();for c in "64425".unicodeScalars { _ = engine.key(Int32(c.value)) }
        let filter=try XCTUnwrap(engine.nineSyllables.firstIndex(of:"ni"));_ = engine.selectNineSyllable(filter)
        finishPrediction(engine)
        let full=try XCTUnwrap(engine.candidateBatch(offset:0,limit:96).first{$0.text=="你好" && $0.replacementInput != nil})
        XCTAssertTrue(full.replacementInput!.hasPrefix("ni'"));XCTAssertEqual(engine.chooseCandidate(full),"你好")
    }
    func testExtraAndMissingKeysProduceRealCanonicalCandidates() throws {
        let engine=try engine();defer { engine.clear();engine.finish() };_ = engine.nineKey(true)
        for input in ["644426","6426","64462"] {
            engine.clear();engine.resetPredictionContext()
            for c in input.unicodeScalars { _ = engine.key(Int32(c.value)) }
            let before=engine.rawInput;finishPrediction(engine)
            let choices=engine.candidateBatch(offset:0,limit:64)
            print("SYNTHETIC_INSERT_DELETE code=\(input) head=\(choices.prefix(16).map{$0.text})")
            let target=try XCTUnwrap(choices.first{$0.text=="你好"})
            XCTAssertEqual(engine.rawInput,before)
            XCTAssertEqual(engine.chooseCandidate(target),"你好")
        }
    }
    func testDeleteUnwindsNineFiltersAfterLaterCharacters() throws {
        let engine=try engine();defer { engine.clear();engine.finish() };_ = engine.nineKey(true)
        for c in "64426".unicodeScalars { _ = engine.key(Int32(c.value)) }
        let original=engine.rawInput
        let ni=try XCTUnwrap(engine.nineSyllables.firstIndex(of:"ni"));XCTAssertTrue(engine.selectNineSyllable(ni))
        let firstFilter=engine.rawInput
        let hao=try XCTUnwrap(engine.nineSyllables.firstIndex(of:"hao"));XCTAssertTrue(engine.selectNineSyllable(hao))
        XCTAssertEqual(engine.key(0xff08).commit,"");XCTAssertEqual(engine.rawInput,firstFilter)
        _ = engine.key(56);XCTAssertEqual(engine.rawInput,firstFilter+"8")
        _ = engine.key(0xff08);XCTAssertEqual(engine.rawInput,firstFilter)
        _ = engine.key(0xff08);XCTAssertEqual(engine.rawInput,original)
        _ = engine.key(0xff08);XCTAssertEqual(engine.rawInput,"6442")
        engine.clear();for c in "64426".unicodeScalars { _ = engine.key(Int32(c.value)) }
        let mi=try XCTUnwrap(engine.nineSyllables.firstIndex(of:"mi"));_ = engine.selectNineSyllable(mi)
        _ = engine.key(0xff51);let edited=engine.rawInput
        _ = engine.key(0xff08);XCTAssertNotEqual(engine.rawInput,original)
        XCTAssertEqual(engine.rawInput.count,edited.count-1);XCTAssertFalse(engine.canUndoNineSyllable)
    }
    private func finishPrediction(_ engine:NativeEngine) {
        XCTAssertTrue(engine.beginNinePrediction())
        for _ in 0..<2000 { if engine.advanceNinePrediction() { return };RunLoop.current.run(until:Date().addingTimeInterval(0.005)) }
        XCTFail("Bounded prediction must complete")
    }
    func testOfflineCollocationAndNineTypoSelection() throws {
        let engine=try engine();defer { engine.clear();engine.finish() }
        XCTAssertTrue(engine.languageModelReady)
        let fluent=pi_language_score("我想","喝水"),unrelated=pi_language_score("我想","和税")
        print("SYNTHETIC_COLLOCATION fluent=\(fluent) unrelated=\(unrelated)")
        XCTAssertGreaterThan(fluent,unrelated)
        for pair in [("今天","天气很好","田七很号"),("请把","文件发给我","稳件法给卧")] {
            let good=pi_language_score(pair.0,pair.1),bad=pi_language_score(pair.0,pair.2)
            print("SYNTHETIC_PAIR fluent=\(good) unrelated=\(bad)");XCTAssertGreaterThan(good,bad)
        }
        let memoryBefore=pi_process_memory_footprint()
        _ = engine.nineKey(true);engine.resetPredictionContext()
        for c in "64425".unicodeScalars { _ = engine.key(Int32(c.value)) }
        let original=engine.rawInput,start=Date.timeIntervalSinceReferenceDate
        let native=engine.candidateBatch(offset:0,limit:64)
        finishPrediction(engine)
        let values=engine.candidateBatch(offset:0,limit:64)
        let fullStream=engine.candidateBatch(offset:0,limit:96)
        for old in native { XCTAssertTrue(fullStream.contains{$0.index==old.index && $0.text==old.text}) }
        let target=try XCTUnwrap(values.first{$0.text=="你好" && $0.replacementInput=="64426"})
        print("SYNTHETIC_NINE latency_ms=\((Date.timeIntervalSinceReferenceDate-start)*1000) correction_rank=\(values.firstIndex{$0.text=="你好"} ?? -1) slice_ms=\(engine.predictionMaxSliceMS) footprint_mb=\(engine.predictionFootprintMB) footprint_delta_mb=\((Double(pi_process_memory_footprint())-Double(memoryBefore))/1048576)")
        XCTAssertEqual(engine.rawInput,original,"Scoring must not rewrite composition")
        XCTAssertEqual(engine.chooseCandidate(target),"你好")
        XCTAssertTrue(engine.rawInput.isEmpty)
        let memory=try JSONDecoder().decode(NineKeyChoiceMemory.self,from:Data(contentsOf:Self.storage.appendingPathComponent("nine-choice-memory-v3.json")))
        XCTAssertGreaterThan(memory.boost(code:original,reading:"ni hao",text:"你好",context:""),0)
        try engine.manage(target,pinned:nil)
        let reset=try JSONDecoder().decode(NineKeyChoiceMemory.self,from:Data(contentsOf:Self.storage.appendingPathComponent("nine-choice-memory-v3.json")))
        XCTAssertEqual(reset.boost(code:original,reading:"ni hao",text:"你好",context:""),0)
    }
    func testStaleCorrectionAndLockedSyllablesNeverRewriteInput() throws {
        let engine=try engine();defer { engine.clear();engine.finish() };_ = engine.nineKey(true)
        for c in "64425".unicodeScalars { _ = engine.key(Int32(c.value)) };finishPrediction(engine)
        let target=try XCTUnwrap(engine.candidateBatch(offset:0,limit:64).first{$0.replacementInput != nil})
        _ = engine.key(50);let changed=engine.rawInput
        XCTAssertEqual(engine.chooseCandidate(target),"");XCTAssertEqual(engine.rawInput,changed)
        engine.clear();engine.resetPredictionContext()
        for c in "64425".unicodeScalars { _ = engine.key(Int32(c.value)) };finishPrediction(engine)
        let repeated=engine.rawInput
        XCTAssertEqual(engine.chooseCandidate(target),"","Identical keys in a later generation must not reactivate an old candidate")
        XCTAssertEqual(engine.rawInput,repeated)
        engine.clear();for c in "64426".unicodeScalars { _ = engine.key(Int32(c.value)) }
        _ = engine.key(0xff51);XCTAssertFalse(engine.needsNinePrediction);_ = engine.key(0xff53)
        let index=try XCTUnwrap(engine.nineSyllables.firstIndex(of:"ni"));XCTAssertTrue(engine.selectNineSyllable(index))
        XCTAssertTrue(engine.needsNinePrediction)
    }
    func testPrivatePredictionDoesNotPersistConfirmedChoice() throws {
        let engine=try engine();defer { engine.clear();_ = engine.privacy(false);engine.finish() }
        let file=Self.storage.appendingPathComponent("nine-choice-memory-v3.json"),before=try? Data(contentsOf:file)
        _ = engine.privacy(true);_ = engine.nineKey(true)
        for c in "64425".unicodeScalars { _ = engine.key(Int32(c.value)) };finishPrediction(engine)
        let target=try XCTUnwrap(engine.candidateBatch(offset:0,limit:64).first{$0.text=="你好" && $0.replacementInput != nil})
        XCTAssertEqual(engine.chooseCandidate(target),"你好");XCTAssertEqual(try? Data(contentsOf:file),before)
    }
    func testBurstEventsAbortOldPredictionWithoutLossOrReordering() throws {
        let engine=try engine();defer { engine.clear();engine.finish() };_ = engine.nineKey(true)
        var expected=""
        for c in "644256442564425".unicodeScalars {
            expected += String(c);_ = engine.key(Int32(c.value));XCTAssertEqual(engine.rawInput,expected)
            if expected.count==4 { XCTAssertTrue(engine.beginNinePrediction());_ = engine.advanceNinePrediction(timeBudget:0) }
        }
        for _ in 0..<expected.count { expected.removeLast();_ = engine.key(0xff08);XCTAssertEqual(engine.rawInput,expected) }
        XCTAssertTrue(engine.preedit.isEmpty)
    }
    func testMemoryPressureKeepsPendingInputAndOfflineCandidates() throws {
        let engine=try engine();defer { engine.clear();engine.finish() };_ = engine.nineKey(true)
        for c in "64426".unicodeScalars { _ = engine.key(Int32(c.value)) }
        let draft=engine.rawInput;engine.suspendPredictionForMemoryPressure()
        XCTAssertEqual(engine.rawInput,draft);XCTAssertTrue(engine.ready);XCTAssertFalse(engine.needsNinePrediction)
        let target=try XCTUnwrap(engine.candidateBatch(offset:0,limit:32).first{$0.text=="你好"})
        XCTAssertEqual(engine.chooseCandidate(target),"你好")
    }
    func testMacVisiblePersonalPhraseUsesSpaceAndNumberWithoutNativeSubstitution() throws {
        let file=Self.storage.appendingPathComponent("personal-lexicon-v1.json"),saved=try? Data(contentsOf:file)
        defer { if let saved { try? saved.write(to:file,options:.atomic) } else { try? FileManager.default.removeItem(at:file) } }
        var lexicon=PersonalLexicon();try lexicon.upsert(.init(kind:.phrase,text:"合成快捷短语",trigger:"cs"),syllables:[])
        try PersonalLexiconStore(directory:Self.storage).save(lexicon)
        let engine=try engine();defer{engine.clear();engine.finish()}
        let input=MacInputSession(engine:engine),host=view("前文："),client=TextViewClient(view:host)
        for key in [" ","1"] {
            type("cs",into:input,client:client)
            XCTAssertEqual(input.candidateRows.first?.text,"合成快捷短语")
            XCTAssertTrue(input.input(key,keyCode:-1,flags:0,client:client))
            XCTAssertFalse(host.hasMarkedText());XCTAssertTrue(engine.rawInput.isEmpty)
            XCTAssertTrue(input.candidateRows.isEmpty)
        }
        XCTAssertEqual(host.string,"前文：合成快捷短语合成快捷短语")
        input.finishComposition(client:client)
        XCTAssertEqual(host.string,"前文：合成快捷短语合成快捷短语")
    }
    func testMacVisibleCandidatePagingSelectsTheDisplayedRowAndKeepsShortcuts() throws {
        let engine=try engine();defer{engine.clear();engine.finish()}
        let input=MacInputSession(engine:engine),host=view(),client=TextViewClient(view:host)
        type("shi",into:input,client:client)
        let first=input.candidateRows
        XCTAssertEqual(first.count,6)
        XCTAssertTrue(input.input(nil,keyCode:121,flags:0,client:client))
        XCTAssertEqual(input.candidateOffset,6)
        let shown=try XCTUnwrap(input.candidateRows.first)
        XCTAssertEqual(shown.text,engine.candidateBatch(offset:6,limit:1).first?.text)
        XCTAssertFalse(input.input("1",keyCode:18,flags:Int(NSEvent.ModifierFlags.command.rawValue),client:client))
        XCTAssertEqual(engine.rawInput,"shi")
        XCTAssertTrue(input.input("1",keyCode:18,flags:0,client:client))
        XCTAssertEqual(host.string,shown.text);XCTAssertFalse(host.hasMarkedText())
    }
    func testMacIdleLearningCheckpointImportsRemotePinAndPublishesWithoutClearingDraft() throws {
        let engine=try engine();defer{engine.clear();engine.finish()};_ = engine.privacy(false)
        let shared=SharedLearningSnapshot(directory:Self.storage.appendingPathComponent("Shared"))
        var remote=LearningModel();try remote.setPinned(reading:"ni hao",text:"拟好",pinned:true,device:"synthetic-mac20-remote")
        try shared.publish(remote.export(),by:.containingApp)
        for c in "nihao".unicodeScalars { _ = engine.key(Int32(c.value)) }
        let draft=engine.rawInput
        XCTAssertThrowsError(try engine.synchronizeLearning(publish:.containingApp))
        XCTAssertEqual(engine.rawInput,draft)
        engine.clear();try engine.synchronizeLearning(publish:.containingApp)
        for c in "nihao".unicodeScalars { _ = engine.key(Int32(c.value)) }
        XCTAssertEqual(engine.candidateBatch(offset:0,limit:1).first?.text,"拟好")
        let archive=try XCTUnwrap(shared.read());var merged=LearningModel();try merged.merge(archive)
        XCTAssertTrue(merged.entries.values.contains{$0.text=="拟好" && $0.pinned})
        engine.clear()
    }

    @MainActor func testShiftLeftRightEditCompositionCaretWithoutCandidatePaging() throws {
        let engine=try engine();defer{engine.clear();engine.finish()};_ = engine.privacy(true)
        let input=MacInputSession(engine:engine),host=view(),client=TextViewClient(view:host)
        type("nihao",into:input,client:client)
        XCTAssertTrue(input.input(nil,keyCode:123,flags:Int(NSEvent.ModifierFlags.shift.rawValue),client:client))
        XCTAssertTrue(input.input(nil,keyCode:123,flags:Int(NSEvent.ModifierFlags.shift.rawValue),client:client))
        XCTAssertEqual(engine.rawInput,"nihao");XCTAssertEqual(input.candidateOffset,0)
        XCTAssertLessThan(engine.compositionCursorUTF16,engine.preedit.utf16.count)
        XCTAssertEqual(host.selectedRange().location,engine.compositionCursorUTF16)
        type("i",into:input,client:client);XCTAssertEqual(engine.rawInput,"nihiao")
    }
    @MainActor func testNativePanelSelectionCallbackKeepsSpaceAndVisiblePageAligned() throws {
        let engine=try engine();defer{engine.clear();engine.finish()};_ = engine.privacy(true)
        let input=MacInputSession(engine:engine),host=view("前文："),client=TextViewClient(view:host)
        type("shi",into:input,client:client)
        let selected=try XCTUnwrap(input.allCandidateRows.dropFirst(13).first)
        input.highlightCandidate(selected)
        XCTAssertEqual(input.selectedIndex,13);XCTAssertEqual(input.candidateOffset,12)
        XCTAssertEqual(input.highlightedCandidate?.text,selected.text)
        XCTAssertTrue(input.input(" ",keyCode:49,flags:0,client:client))
        XCTAssertEqual(host.string,"前文："+selected.text)
        // A native callback referring to an old word list cannot change a
        // new composition's highlighted candidate or its stored input.
        type("nihao",into:input,client:client)
        let raw=engine.rawInput,first=input.highlightedCandidate?.text
        input.highlightCandidate(InputCandidate(text:"不存在的合成候选",comment:"",index:Int.min))
        XCTAssertEqual(engine.rawInput,raw);XCTAssertEqual(input.highlightedCandidate?.text,first)
    }
    @MainActor func testNativeExpandedCandidateArrowsSpaceEscapeAndLazyTail() throws {
        let engine=try engine();defer{engine.clear();engine.finish()};_ = engine.privacy(true)
        let input=MacInputSession(engine:engine),host=view("前文："),client=TextViewClient(view:host)
        type("shi",into:input,client:client)
        XCTAssertFalse(input.expanded)
        let raw=engine.rawInput
        XCTAssertTrue(input.input(nil,keyCode:125,flags:0,client:client));XCTAssertTrue(input.expanded)
        XCTAssertEqual(engine.rawInput,raw);XCTAssertEqual(input.selectedIndex,0)
        XCTAssertTrue(input.input(nil,keyCode:125,flags:0,client:client));XCTAssertEqual(input.selectedIndex,6)
        let selected=try XCTUnwrap(input.highlightedCandidate)
        XCTAssertTrue(input.input(" ",keyCode:49,flags:0,client:client))
        XCTAssertEqual(host.string,"前文："+selected.text);XCTAssertFalse(input.expanded)
        type("shi",into:input,client:client)
        XCTAssertTrue(input.input(nil,keyCode:126,flags:0,client:client));XCTAssertTrue(input.expanded)
        XCTAssertTrue(input.input(nil,keyCode:53,flags:0,client:client));XCTAssertFalse(input.expanded);XCTAssertEqual(engine.rawInput,"shi")
        input.loadMoreCandidates();XCTAssertGreaterThan(input.allCandidateRows.count,36)
        XCTAssertTrue(input.input(nil,keyCode:53,flags:0,client:client));XCTAssertTrue(engine.rawInput.isEmpty)
    }
    func testMacBERTPreservesExplicitlyLearnedPinyinRepair() throws {
        let engine=try engine();defer{engine.clear();engine.finish()};_ = engine.privacy(false)
        engine.resetPredictionContext()
        for key in "shshenme".utf8 {_ = engine.key(Int32(key))}
        let first=try XCTUnwrap(engine.candidateBatch(offset:0,limit:36).first{$0.text=="是什么"})
        XCTAssertEqual(engine.chooseCandidate(first),"是什么")
        engine.resetPredictionContext()
        for key in "shshenme".utf8 {_ = engine.key(Int32(key))}
        let learned=try XCTUnwrap(engine.candidateBatch(offset:0,limit:36).first{$0.text=="是什么"})
        XCTAssertTrue(learned.learnedPreference,"Explicit user corrections must be excluded from neural movement")
    }
    @MainActor func testMacBERTIsActuallyConnectedToPinyinRepairAndDraftIsPreserved() throws {
        let engine=try engine();defer{engine.clear();engine.finish()};_ = engine.privacy(true)
        let input=MacInputSession(engine:engine,semanticDirectory:try XCTUnwrap(Bundle(for:Self.self).url(forResource:"semantic-mac",withExtension:nil))),host=view(),client=TextViewClient(view:host)
        let done=expectation(description:"MacBERT candidate callback")
        input.candidatesChanged={done.fulfill()}
        type("shshenme",into:input,client:client)
        let raw=engine.rawInput
        wait(for:[done],timeout:60)
        XCTAssertTrue(input.modelMetrics.available);XCTAssertGreaterThan(input.modelMetrics.batches,0)
        XCTAssertEqual(engine.rawInput,raw);XCTAssertEqual(input.candidateRows.first?.text,"是什么")
        XCTAssertTrue(input.input(" ",keyCode:49,flags:0,client:client));XCTAssertEqual(host.string,"是什么")
    }

    @MainActor func testHostContextIsBoundedEphemeralAndUsedForAbbreviationRanking() throws {
        let engine=try engine();defer{engine.clear();engine.finish()};_ = engine.privacy(true)
        struct ContextClient:MacInputClient {
            let host:NSTextView
            func insert(_ text:String){host.insertText(text,replacementRange:NSRange(location:NSNotFound,length:0))}
            func mark(_ text:String){host.setMarkedText(text,selectedRange:NSRange(location:text.utf16.count,length:0),replacementRange:NSRange(location:NSNotFound,length:0))}
            func surroundingText()->SurroundingText? {SurroundingText(before:"今天晚上我们一起",after:"，你决定吧。")}
        }
        let host=view(),client=ContextClient(host:host)
        let input=MacInputSession(engine:engine,semanticDirectory:try XCTUnwrap(Bundle(for:Self.self).url(forResource:"semantic-mac",withExtension:nil)))
        let done=expectation(description:"native abbreviation uses bounded host context")
        input.candidatesChanged={done.fulfill()}
        for c in "csm" {XCTAssertTrue(input.input(String(c),keyCode:-1,flags:0,client:client))}
        XCTAssertEqual(engine.modelContext.before,"今天晚上我们一起");XCTAssertEqual(engine.modelContext.after,"，你决定吧。")
        XCTAssertEqual(engine.precedingOwnText,"")
        wait(for:[done],timeout:60)
        print("PINYIN29_CONTEXT_HEAD=\(input.candidateRows.map(\.text))")
        XCTAssertTrue(input.modelMetrics.available);XCTAssertTrue(input.candidateRows.contains{$0.text=="吃什么"})
        let row=try XCTUnwrap(input.candidateRows.first{$0.text=="吃什么"});input.chooseCandidate(row,client:client)
        XCTAssertEqual(host.string,"吃什么");XCTAssertEqual(engine.precedingOwnText,"吃什么")
        engine.resetPredictionContext();XCTAssertFalse(engine.hasHostContext)
    }
    func testSyntheticInitialsPrefixAndDoubleSwapBaseline() throws {
        let engine=try engine();defer{engine.clear();engine.finish()};_ = engine.privacy(true)
        let syllables=try String(contentsOf:try XCTUnwrap(Bundle(for:Self.self).url(forResource:"semantic",withExtension:nil)).appendingPathComponent("pinyin-syllables.txt"))
        let decoder=PinyinCorrection(syllables:Set(syllables.split(separator:"\n").map(String.init)))
        let proposed=decoder.proposals("linaxaing",limit:64)
        print("PINYIN29_PROPOSALS target=\(proposed.firstIndex{$0.spelling=="lianxiang"} ?? -1) head=\(proposed.prefix(12).map(\.spelling))")
        for (raw,target) in [("csm","吃什么"),("shih","时候"),("linaxaing","联想"),("lianxiang","联想"),("shihou","时候")] {
            engine.clear();for key in raw.utf8 {_ = engine.key(Int32(key))}
            let start=Date.timeIntervalSinceReferenceDate,rows=engine.candidateBatch(offset:0,limit:96)
            XCTAssertNotNil(rows.prefix(9).first{$0.text==target},raw)
            if raw=="linaxaing" {XCTAssertEqual(rows.first?.text,target,"Repeated-initial support must preserve ordinary full-spelling repair priority")}
            print("PINYIN29_BASELINE raw=\(raw) target=\(rows.firstIndex{$0.text==target} ?? -1) head=\(rows.prefix(12).map{"\($0.text)[\($0.comment)]"}) ms=\((Date.timeIntervalSinceReferenceDate-start)*1000)")
            let chosen=try XCTUnwrap(rows.first{$0.text==target})
            XCTAssertEqual(engine.chooseCandidate(chosen),target)
        }
    }

    @MainActor func testEveryDigitSelectsInitialVisibleCandidateWithoutMovingCaret() throws {
        let engine=try engine();defer{engine.clear();engine.finish()};_ = engine.privacy(true)
        for digit in 1...6 {
            let input=MacInputSession(engine:engine),host=view("合成："),client=TextViewClient(view:host)
            type("shi",into:input,client:client)
            let expected=input.candidateRows[digit-1].text
            XCTAssertTrue(input.input(String(digit),keyCode:[18,19,20,21,23,22][digit-1],flags:0,client:client))
            XCTAssertEqual(host.string,"合成："+expected);XCTAssertTrue(engine.preedit.isEmpty)
        }
    }
    @MainActor func testHorizontalHighlightAndGridColumnNavigationDoNotAlterPinyin() throws {
        let engine=try engine();defer{engine.clear();engine.finish()};_ = engine.privacy(true)
        let input=MacInputSession(engine:engine),host=view(),client=TextViewClient(view:host)
        type("shi",into:input,client:client);let caret=engine.compositionCursorUTF16
        for _ in 0..<7 {_ = input.input(nil,keyCode:124,flags:0,client:client)}
        XCTAssertEqual(input.selectedIndex,7);XCTAssertEqual(input.candidateOffset,6)
        XCTAssertEqual(engine.rawInput,"shi");XCTAssertEqual(engine.compositionCursorUTF16,caret)
        _ = input.input(nil,keyCode:126,flags:0,client:client);XCTAssertTrue(input.expanded);XCTAssertEqual(input.selectedIndex,7)
        _ = input.input(nil,keyCode:125,flags:0,client:client);XCTAssertEqual(input.selectedIndex,13)
        _ = input.input(nil,keyCode:126,flags:0,client:client);XCTAssertEqual(input.selectedIndex,7)
        _ = input.input(nil,keyCode:123,flags:0,client:client);XCTAssertEqual(input.selectedIndex,6)
        let selected=try XCTUnwrap(input.highlightedCandidate)
        _ = input.input(" ",keyCode:49,flags:0,client:client);XCTAssertEqual(host.string,selected.text)
    }
    func testMobilePinyinScorerUsesBothHostSidesWithoutLearningTheirText() throws {
        let resources=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"rime",withExtension:nil))
        let engine=NativeEngine(sharedResources:resources,storageBase:Self.storage,useSemantic:true)
        defer{engine.clear();engine.finish()};_ = engine.privacy(true)
        engine.setHostContext(SurroundingText(before:"今天我的",after:"很好。"))
        for key in "xinqing".utf8 {_ = engine.key(Int32(key))}
        XCTAssertEqual(engine.modelContext.before,"今天我的");XCTAssertEqual(engine.modelContext.after,"很好。")
        XCTAssertEqual(engine.precedingOwnText,"")
        let rows=engine.candidateBatch(offset:0,limit:24),done=expectation(description:"mobile local context scores")
        engine.rankPinyinCandidates(rows) {ordered in
            XCTAssertEqual(Set(ordered.map(\.text)),Set(rows.map(\.text)))
            XCTAssertTrue(engine.semanticLastMetrics.available);XCTAssertEqual(engine.precedingOwnText,"")
            done.fulfill()
        };wait(for:[done],timeout:30)
        engine.clear();XCTAssertFalse(engine.hasHostContext)
    }
    func testHostContextPowersIdleContinuationAndStaleRowsAreRejected() throws {
        let engine=try engine();defer{engine.clear();engine.finish()};_ = engine.privacy(true)
        engine.setHostContext(SurroundingText(before:"你好",after:"合成后文"))
        XCTAssertEqual(engine.precedingOwnText,"")
        if let row=engine.continuationBatch().first {
            XCTAssertEqual(row.continuationContext,"你好")
            engine.setHostContext(SurroundingText(before:"另一个字段",after:""))
            XCTAssertEqual(engine.chooseContinuation(row),"")
        }
        engine.resetPredictionContext();XCTAssertFalse(engine.hasHostContext)
    }
    @MainActor func testCustomColumnsDriveNumbersArrowsAndPagingWithoutLosingInput() throws {
        let engine=try engine();defer{engine.clear();engine.finish()};_ = engine.privacy(true)
        for configuration in [DesktopCandidateLayout(collapsedCount:3,expandedColumns:5,expandedRows:4),.init(collapsedCount:9,expandedColumns:3,expandedRows:3)] {
            let input=MacInputSession(engine:engine,candidateLayout:configuration),host=view(),client=TextViewClient(view:host)
            type("shi",into:input,client:client);XCTAssertEqual(input.candidateRows.count,configuration.collapsedCount)
            _ = input.input(nil,keyCode:125,flags:0,client:client)
            _ = input.input(nil,keyCode:125,flags:0,client:client)
            XCTAssertEqual(input.selectedIndex,configuration.expandedColumns)
            _ = input.input(nil,keyCode:124,flags:0,client:client)
            XCTAssertEqual(input.selectedIndex,configuration.expandedColumns+1)
            let word=try XCTUnwrap(input.candidateRows.dropFirst(1).first)
            _ = input.input("2",keyCode:19,flags:0,client:client);XCTAssertEqual(host.string,word.text)
            type("shi",into:input,client:client);_ = input.input(nil,keyCode:125,flags:0,client:client)
            _ = input.input(nil,keyCode:121,flags:0,client:client)
            XCTAssertEqual(input.selectedIndex,configuration.pageSize);XCTAssertEqual(engine.rawInput,"shi")
            input.applyCandidateLayout(.init(collapsedCount:5,expandedColumns:4,expandedRows:5))
            XCTAssertEqual(input.candidateOffset,(input.selectedIndex/4)*4);XCTAssertEqual(engine.rawInput,"shi")
            engine.clear()
        }
    }
    private static let storage = FileManager.default.temporaryDirectory.appendingPathComponent("PrivateInput-MacHost-" + UUID().uuidString)
    override class func tearDown() {
        pi_finalize()
        try? FileManager.default.removeItem(at: storage)
        super.tearDown()
    }
    private func engine(displayable:@escaping(String)->Bool={CandidateGlyphSupport.supports($0)}) throws -> NativeEngine {
        XCTAssertTrue(Thread.isMainThread)
        let resources = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "rime", withExtension: nil))
        let engine = NativeEngine(sharedResources: resources, storageBase: Self.storage,candidateIsDisplayable:displayable)
        XCTAssertTrue(engine.ready, "Use the compiled dictionary and an isolated synthetic database")
        return engine
    }
    private func type(_ letters: String, into input: MacInputSession, client: TextViewClient) {
        for letter in letters { XCTAssertTrue(input.input(String(letter), keyCode: -1, flags: 0, client: client)) }
    }
    private func view(_ text: String = "") -> NSTextView {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 250))
        view.isRichText = false; view.string = text
        view.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
        return view
    }

    func testDamagedAuxiliaryCheckpointDoesNotDisableOfflineInput() throws {
        let file = Self.storage.appendingPathComponent("learning-checkpoint-v1.json")
        try FileManager.default.createDirectory(at: Self.storage, withIntermediateDirectories: true)
        let original = try? Data(contentsOf: file), broken = Data("synthetic-invalid-checkpoint".utf8)
        try broken.write(to: file, options: .atomic)
        defer { if let original { try? original.write(to: file, options: .atomic) } else { try? FileManager.default.removeItem(at: file) } }
        let engine = try engine(); defer { engine.finish() }
        for c in "nihao".unicodeScalars { _ = engine.key(Int32(c.value)) }
        XCTAssertTrue(engine.candidateBatch(offset: 0, limit: 12).contains { $0.text == "你好" })
        XCTAssertEqual(try Data(contentsOf: file), broken, "Do not overwrite damaged learning state to make typing work")
        engine.clear(); XCTAssertThrowsError(try engine.synchronizeLearning())
    }
    func testCandidateManagementKeepsDraftAndPersistsThroughCheckpoint() throws {
        let engine = try engine(); defer { engine.finish() }
        _ = engine.privacy(false); _ = engine.nineKey(false)
        for c in "shi".unicodeScalars { _ = engine.key(Int32(c.value)) }
        let target = try XCTUnwrap(engine.candidateBatch(offset: 12, limit: 24).first)
        let draft = engine.rawInput
        try engine.manage(target, pinned: true)
        XCTAssertEqual(engine.rawInput, draft)
        XCTAssertEqual(engine.candidateBatch(offset: 0, limit: 12).first?.text, target.text)
        XCTAssertTrue(engine.isPinned(target))
        try engine.manage(target, pinned: nil)
        XCTAssertEqual(engine.rawInput, draft)
        XCTAssertThrowsError(try engine.synchronizeLearning())
        engine.clear(); try engine.synchronizeLearning()
        for c in "shi".unicodeScalars { _ = engine.key(Int32(c.value)) }
        XCTAssertEqual(engine.candidateBatch(offset: 0, limit: 12).first?.text, target.text)
        XCTAssertTrue(engine.isPinned(target))
        try engine.manage(target, pinned: false)
        XCTAssertFalse(engine.isPinned(target))
        engine.clear(); try engine.synchronizeLearning()
    }
    func testReadableNineDraftRetainsSelectedPrefixAndDoesNotInsertDigits() throws {
        let engine = try engine(); defer { engine.finish() }
        _ = engine.nineKey(true)
        for c in "64426744543".unicodeScalars { _ = engine.key(Int32(c.value)) }
        let first = try XCTUnwrap(engine.candidateBatch(offset: 0, limit: 128).first(where: { $0.text == "你好" }))
        XCTAssertEqual(engine.chooseAbsolute(first.index), "")
        let world = try XCTUnwrap(engine.candidateBatch(offset: 0, limit: 64).first(where: { $0.text == "世界" }))
        try engine.manage(world, pinned: true)
        XCTAssertEqual(engine.candidateBatch(offset: 0, limit: 12).first?.text, "世界", "Pin must match the unselected tail after partial choice")
        XCTAssertEqual(engine.takeReadablePendingInput(reading: "shi jie"), "你好shijie")
        XCTAssertTrue(engine.preedit.isEmpty)
        try engine.manage(world, pinned: false)
        _ = engine.nineKey(false)
    }
    func testCandidateClickReplacesMarkedTextAndDoesNotReplay() throws {
        let engine = try engine(); defer { engine.finish() }
        let input = MacInputSession(engine: engine), host = view("前文："), client = TextViewClient(view: host)
        type("nihao", into: input, client: client)
        XCTAssertTrue(host.hasMarkedText())
        let index = try XCTUnwrap(engine.candidates.firstIndex(of: "你好"))
        input.choose(index, client: client)
        XCTAssertEqual(host.string, "前文：你好")
        XCTAssertFalse(host.hasMarkedText())
        input.finishComposition(client: client)
        XCTAssertEqual(host.string, "前文：你好", "Ending a committed composition must not insert twice")
    }

    func testPartialCandidateKeepsMarkedCompositionUntilFinalSelection() throws {
        let engine = try engine(); defer { engine.finish() }
        let input = MacInputSession(engine: engine), host = view(), client = TextViewClient(view: host)
        type("nihaoshijie", into: input, client: client)
        var index: Int?
        for _ in 0..<12 {
            if let found = engine.candidates.firstIndex(of: "你好") { index = found; break }
            guard engine.hasNextPage else { break }
            XCTAssertTrue(input.input(nil, keyCode: 121, flags: 0, client: client))
        }
        input.choose(try XCTUnwrap(index, "Real Rime must expose a partial phrase candidate"), client: client)
        XCTAssertFalse(engine.preedit.isEmpty)
        XCTAssertFalse(engine.candidates.isEmpty)
        XCTAssertTrue(host.hasMarkedText())
        input.choose(try XCTUnwrap(engine.candidates.firstIndex(of: "世界")), client: client)
        XCTAssertEqual(host.string, "你好世界")
        XCTAssertFalse(host.hasMarkedText())
    }

    func testHostEndsCompositionByPreservingOriginalLettersOnce() throws {
        let engine = try engine(); defer { engine.finish() }
        let input = MacInputSession(engine: engine), host = view("原文 "), client = TextViewClient(view: host)
        type("nihao", into: input, client: client)
        input.finishComposition(client: client)
        XCTAssertEqual(host.string, "原文 nihao")
        XCTAssertFalse(host.hasMarkedText())
        XCTAssertTrue(engine.preedit.isEmpty)
        input.finishComposition(client: client)
        XCTAssertEqual(host.string, "原文 nihao")
    }

    func testNilTextControlKeysAndShortcutPassthrough() throws {
        let engine = try engine(); defer { engine.finish() }
        let input = MacInputSession(engine: engine), host = view(), client = TextViewClient(view: host)
        type("nihao", into: input, client: client)
        for modifier in [NSEvent.ModifierFlags.command, .control, .option] {
            XCTAssertFalse(input.input("a", keyCode: 0, flags: Int(modifier.rawValue), client: client))
            XCTAssertEqual(engine.rawInput, "nihao")
        }
        XCTAssertTrue(input.input(nil, keyCode: 51, flags: 0, client: client))
        XCTAssertEqual(engine.rawInput, "niha")
        XCTAssertTrue(input.input(nil, keyCode: 53, flags: 0, client: client))
        XCTAssertTrue(engine.preedit.isEmpty)
        XCTAssertFalse(host.hasMarkedText())
        XCTAssertEqual(host.string, "")
    }

    func testCapsLockSwitchesChineseEnglishAndShiftCaseWithoutReplayingLetters() throws {
        let engine=try engine();defer{engine.finish()}
        let input=MacInputSession(engine:engine,capsLockSwitchEnabled:true),host=view(),client=TextViewClient(view:host)
        let caps=Int(NSEvent.ModifierFlags.capsLock.rawValue),shift=Int(NSEvent.ModifierFlags.shift.rawValue)
        XCTAssertTrue(input.input("A",keyCode:0,flags:caps,client:client));XCTAssertTrue(input.english);XCTAssertEqual(host.string,"a")
        XCTAssertTrue(input.input("B",keyCode:11,flags:caps,client:client));XCTAssertTrue(input.english);XCTAssertEqual(host.string,"ab")
        XCTAssertTrue(input.input("c",keyCode:8,flags:caps|shift,client:client));XCTAssertEqual(host.string,"abC")
        XCTAssertTrue(input.input("n",keyCode:45,flags:0,client:client));XCTAssertFalse(input.english);XCTAssertEqual(engine.rawInput,"n")
        type("ihao",into:input,client:client)
        XCTAssertTrue(input.input(" ",keyCode:49,flags:0,client:client));XCTAssertEqual(host.string,"abC你好")
    }
    func testCapsLockPreservesDraftOnceAndReplacesHostSelectionOnce() throws {
        let engine=try engine();defer{engine.finish()}
        let input=MacInputSession(engine:engine,capsLockSwitchEnabled:true),host=view(),client=TextViewClient(view:host)
        let caps=Int(NSEvent.ModifierFlags.capsLock.rawValue)
        type("nihao",into:input,client:client)
        XCTAssertTrue(input.input("A",keyCode:0,flags:caps,client:client));XCTAssertEqual(host.string,"nihaoa");XCTAssertFalse(host.hasMarkedText())
        host.setSelectedRange(NSRange(location:0,length:host.string.utf16.count))
        XCTAssertTrue(input.input("B",keyCode:11,flags:caps,client:client));XCTAssertEqual(host.string,"b");XCTAssertTrue(engine.rawInput.isEmpty)
        XCTAssertTrue(input.input(nil,keyCode:57,flags:0,client:client));XCTAssertFalse(input.english)
        XCTAssertTrue(input.input(nil,keyCode:57,flags:0,client:client));XCTAssertFalse(input.english)
    }
    func testCapsLockCompatibilityCanBeDisabledAndNeverConsumesShortcuts() throws {
        let engine=try engine();defer{engine.finish()}
        let input=MacInputSession(engine:engine,capsLockSwitchEnabled:true),host=view("原文"),client=TextViewClient(view:host)
        let caps=Int(NSEvent.ModifierFlags.capsLock.rawValue)
        for modifier in [NSEvent.ModifierFlags.command,.control,.option] {
            XCTAssertFalse(input.input("A",keyCode:0,flags:caps|Int(modifier.rawValue),client:client));XCTAssertFalse(input.english);XCTAssertEqual(host.string,"原文")
        }
        let disabled=MacInputSession(engine:engine,capsLockSwitchEnabled:false)
        _ = disabled.input("A",keyCode:0,flags:caps,client:client);XCTAssertFalse(disabled.english)
    }
    func testEnglishAndLearningRefreshPreserveHostSelection() throws {
        let engine = try engine(); defer { engine.finish() }
        let input = MacInputSession(engine: engine), host = view("保留文本"), client = TextViewClient(view: host)
        host.setSelectedRange(NSRange(location: 0, length: 4))
        input.toggleEnglish(client: client)
        XCTAssertTrue(input.english)
        try engine.synchronizeLearning()
        XCTAssertFalse(input.input("A", keyCode: 0, flags: Int(NSEvent.ModifierFlags.shift.rawValue), client: client))
        XCTAssertEqual(host.string, "保留文本")
        XCTAssertEqual(host.selectedRange(), NSRange(location: 0, length: 4))
        XCTAssertTrue(engine.preedit.isEmpty)
        // Simulate the host handling the unconsumed key only once.
        host.insertText("A", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(host.string, "A")
        input.toggleEnglish(client: client)
        type("nihao", into: input, client: client)
        XCTAssertFalse(engine.candidates.isEmpty)
    }

    func testModeSwitchPreservesDraftWithoutGuessingChinese() throws {
        let engine = try engine(); defer { engine.finish() }
        let input = MacInputSession(engine: engine), host = view(), client = TextViewClient(view: host)
        type("nihao", into: input, client: client)
        input.toggleEnglish(client: client)
        XCTAssertEqual(host.string, "nihao")
        XCTAssertFalse(host.hasMarkedText())
        XCTAssertTrue(input.english)
    }

    /// Real MacInputSession + native NSTextView, with archive capability supplied
    /// as a synthetic Boolean. No actual archive queue, permission or upload.
    private func routeArchiveEnglish(_ text:String?,key:Int,flags:Int,input:MacInputSession,
                                     client:TextViewClient,enabled:Bool) -> Bool {
        let beforeEmpty=input.engine.preedit.isEmpty,markedBefore=client.view.hasMarkedText()
        let tracked=MacArchiveMutationTrackingClient(base:client)
        let handled=input.input(text,keyCode:key,flags:flags,client:tracked)
        let state=MacArchiveEnglishInsertion.State(archiveEnabled:enabled,secureInput:false,english:input.english,
            sessionHandled:handled,preeditBeforeEmpty:beforeEmpty,preeditAfterEmpty:input.engine.preedit.isEmpty,
            insertedDuringSession:tracked.inserted,markedDuringSession:tracked.marked,
            hostMarkedBefore:markedBefore,hostMarkedAfter:client.view.hasMarkedText())
        let inserted=MacArchiveEnglishInsertion.insertIfEligible(text,keyCode:key,flags:flags,state:state,insert:tracked.insert)
        return handled || inserted
    }
    func testArchiveEnglishFallbackReplacesSelectionOnceAndKeepsNativeExceptions() throws {
        let engine=try engine();defer{engine.clear();engine.finish()}
        let input=MacInputSession(engine:engine,capsLockSwitchEnabled:false),host=view("保留后文"),client=TextViewClient(view:host)
        host.setSelectedRange(NSRange(location:0,length:2));input.toggleEnglish(client:client)
        XCTAssertTrue(input.english);XCTAssertFalse(host.hasMarkedText())
        let shift=Int(NSEvent.ModifierFlags.shift.rawValue)
        XCTAssertTrue(routeArchiveEnglish("A",key:0,flags:shift,input:input,client:client,enabled:true))
        XCTAssertEqual(host.string,"A后文");XCTAssertEqual(host.selectedRange(),NSRange(location:1,length:0))
        XCTAssertTrue(routeArchiveEnglish(" ",key:49,flags:0,input:input,client:client,enabled:true))
        XCTAssertTrue(routeArchiveEnglish(".",key:47,flags:0,input:input,client:client,enabled:true))
        XCTAssertEqual(host.string,"A .后文")
        for modifier in [NSEvent.ModifierFlags.command,.control,.option,.function] {
            XCTAssertFalse(routeArchiveEnglish("x",key:7,flags:Int(modifier.rawValue),input:input,client:client,enabled:true))
            XCTAssertEqual(host.string,"A .后文")
        }
        XCTAssertFalse(routeArchiveEnglish("é",key:14,flags:0,input:input,client:client,enabled:true))
        XCTAssertFalse(routeArchiveEnglish("B",key:11,flags:shift,input:input,client:client,enabled:false))
        XCTAssertEqual(host.string,"A .后文")
        // Simulate exactly one native insertion after archive-off passthrough.
        host.insertText("B",replacementRange:NSRange(location:NSNotFound,length:0))
        XCTAssertEqual(host.string,"A .B后文");XCTAssertTrue(engine.preedit.isEmpty)
    }
    func testArchiveEnglishFallbackNeverDuplicatesChineseCandidateOrExistingMark() throws {
        let engine=try engine();defer{engine.clear();engine.finish()}
        let input=MacInputSession(engine:engine,capsLockSwitchEnabled:false),host=view(),client=TextViewClient(view:host)
        for character in "nihao" {
            XCTAssertTrue(routeArchiveEnglish(String(character),key:0,flags:0,input:input,client:client,enabled:true))
        }
        XCTAssertTrue(host.hasMarkedText())
        XCTAssertTrue(routeArchiveEnglish(" ",key:49,flags:0,input:input,client:client,enabled:true))
        XCTAssertEqual(host.string,"你好");XCTAssertFalse(host.hasMarkedText());XCTAssertTrue(engine.preedit.isEmpty)
        input.toggleEnglish(client:client)
        host.setMarkedText("é",selectedRange:NSRange(location:1,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        let marked=host.string
        XCTAssertFalse(routeArchiveEnglish("a",key:0,flags:0,input:input,client:client,enabled:true))
        XCTAssertEqual(host.string,marked);XCTAssertTrue(host.hasMarkedText())
    }

}
