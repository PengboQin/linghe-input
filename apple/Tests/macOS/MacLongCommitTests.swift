import AppKit
import XCTest
import PrivateInputKit

/// This suite owns one temporary native DB and must run in its own XCTest
/// process, separate from suites which own another process-global Rime path.
final class MacLongCommitTests:XCTestCase {
    private static let storage=FileManager.default.temporaryDirectory.appendingPathComponent("PrivateInput-LongCommit-"+UUID().uuidString)
    private struct Client:MacInputClient {
        let view:NSTextView
        func insert(_ text:String) {view.insertText(text,replacementRange:NSRange(location:NSNotFound,length:0))}
        func mark(_ text:String) {mark(text,cursor:text.utf16.count)}
        func mark(_ text:String,cursor:Int) {view.setMarkedText(text,selectedRange:NSRange(location:cursor,length:0),replacementRange:NSRange(location:NSNotFound,length:0))}
        func insertPair(_ text:String,caretBack:Int) {
            MacSymbolInsertion.insert(text,caretBack:caretBack,insert:insert,selection:{view.selectedRange()},read:{range in
                guard range.location>=0,NSMaxRange(range)<=(view.string as NSString).length else{return nil}
                return (view.string as NSString).substring(with:range)
            },placeCaret:{view.setMarkedText("",selectedRange:NSRange(location:0,length:0),replacementRange:$0)})
        }
        func correctionAnchor(expectedSuffix:String)->MacInputAnchor? {
            MacInputAnchor.capture(document:String(describing:ObjectIdentifier(view)),selection:view.selectedRange(),marked:view.markedRange(),length:(view.string as NSString).length,expectedSuffix:expectedSuffix) {range in (view.string as NSString).substring(with:range)}
        }
    }
    override class func tearDown() {pi_finalize();try? FileManager.default.removeItem(at:storage);super.tearDown()}
    private func engine()throws->NativeEngine {
        let e=NativeEngine(sharedResources:try XCTUnwrap(Bundle(for:Self.self).url(forResource:"rime",withExtension:nil)),storageBase:Self.storage,useSemantic:false)
        XCTAssertTrue(e.ready);_ = e.privacy(true);return e
    }
    private func client()->Client {
        let view=NSTextView(frame:NSRect(x:0,y:0,width:600,height:200));view.string="前：";view.setSelectedRange(NSRange(location:2,length:0));return Client(view:view)
    }
    private func seed(_ raw:String,engine:NativeEngine,client:Client) {
        engine.clear();engine.resetPredictionContext()
        for c in raw.utf8 {_ = engine.key(Int32(c))}
        client.mark(engine.displayedPreedit(reading:""),cursor:engine.compositionCursorUTF16)
    }
    private func choose(_ row:InputCandidate,route:String,input:MacInputSession,client:Client)throws {
        input.highlightCandidate(row)
        if route=="click" {input.chooseCandidate(row,client:client)}
        else if route=="number" {
            let shown=input.candidateRows,index=try XCTUnwrap(shown.firstIndex{$0.index==row.index && $0.text==row.text})
            XCTAssertTrue(input.input(String(index+1),keyCode:-1,flags:0,client:client))
        } else {
            let payload:String? = route=="nil" ? nil:(route=="empty" ? "":" ")
            XCTAssertTrue(input.input(payload,keyCode:49,flags:0,client:client))
        }
    }
    func testPhysicalSpaceNilEmptyAndNormalPayloadCommitLongNativeCandidate()throws {
        let e=try engine();defer{e.clear();e.finish()}
        for raw in ["womingtianxianggennimenyiqiqugongyuansanburanhuohuijiachifan",String(repeating:"nihao",count:35)] {
            for route in ["nil","empty","space","number","click"] {
                let c=client(),input=MacInputSession(engine:e)
                seed(raw,engine:e,client:c)
                let row=try XCTUnwrap(input.allCandidateRows.first)
                XCTAssertNil(row.pinyinRepair);XCTAssertNil(row.initialsInput)
                try choose(row,route:route,input:input,client:c)
                XCTAssertEqual(c.view.string,"前："+row.text,"\(raw.count) keys / \(route)")
                XCTAssertFalse(c.view.hasMarkedText());XCTAssertTrue(e.rawInput.isEmpty)
            }
        }
        let c=client(),input=MacInputSession(engine:e);seed("nihao",engine:e,client:c)
        let draft=e.rawInput
        XCTAssertFalse(input.input(nil,keyCode:49,flags:Int(NSEvent.ModifierFlags.command.rawValue),client:c))
        XCTAssertEqual(e.rawInput,draft,"Command-Space remains a host shortcut")
    }
    func testCanonicalReplayBeyond128BytesCommitsAndRemainsBounded()throws {
        let e=try engine();e.finish()
        let canonical=Array(repeating:["ni","hao"],count:35).flatMap{$0}.joined(separator:"'")
        XCTAssertEqual(canonical.utf8.count,244)
        for nine in [false,true] {
            let s=pi_create_session();XCTAssertNotEqual(s,0);defer{pi_destroy_session(s)}
            _ = pi_set_private(s,1);_ = pi_set_nine_key(s,nine ? 1:0)
            let oversized=String(repeating:"a",count:1025)
            XCTAssertEqual(nine ? pi_stage_nine_input(s,oversized):pi_stage_pinyin_input(s,oversized),0)
            XCTAssertTrue(String(cString:pi_raw_input(s)).isEmpty)
            XCTAssertEqual(nine ? pi_stage_nine_input(s,"ni hao"):pi_stage_pinyin_input(s,"ni hao"),0)
            XCTAssertNotEqual(nine ? pi_stage_nine_input(s,canonical):pi_stage_pinyin_input(s,canonical),0)
            let raw=String(cString:pi_raw_input(s))
            XCTAssertEqual(nine ? pi_stage_nine_input(s,"nihao"):pi_stage_pinyin_input(s,"nihao"),0)
            XCTAssertEqual(String(cString:pi_raw_input(s)),raw,"Failed replay must not replace an occupied session")
            XCTAssertGreaterThan(pi_load_candidate_batch(s,0,1),0)
            let text=String(cString:pi_batch_candidate_text(s,0)),index=pi_batch_candidate_index(s,0)
            XCTAssertNotEqual(pi_select_candidate_absolute(s,index),0)
            XCTAssertEqual(String(cString:pi_take_commit(s)),text);XCTAssertEqual(text,String(repeating:"你好",count:35))
        }
    }
    func testComposedCompletionRepairAndPartialChoicesShareAllCommitRoutes()throws {
        let e=try engine();defer{e.clear();e.finish()}
        for route in ["nil","number","click"] {
            for (raw,text,kind) in [("din","定","completion"),("shijei","世界","repair"),("hhhhhnihao","哈哈哈哈哈你好","composed")] {
                let c=client(),input=MacInputSession(engine:e)
                seed(raw,engine:e,client:c)
                let row=try XCTUnwrap(input.allCandidateRows.first{$0.text==text},"\(kind) \(route)")
                if kind=="completion" {XCTAssertTrue(row.prefixCompletion)}
                if kind=="repair" {XCTAssertNotNil(row.pinyinRepair)}
                if kind=="composed" {XCTAssertNotNil(row.initialsInput)}
                try choose(row,route:route,input:input,client:c)
                XCTAssertEqual(c.view.string,"前："+text);XCTAssertFalse(c.view.hasMarkedText());XCTAssertTrue(e.rawInput.isEmpty)
            }
            let c=client(),input=MacInputSession(engine:e);seed("nihaoshijie",engine:e,client:c)
            let prefix=try XCTUnwrap(input.allCandidateRows.first{$0.text=="你好"})
            try choose(prefix,route:route,input:input,client:c)
            XCTAssertTrue(c.view.hasMarkedText());XCTAssertFalse(e.rawInput.isEmpty)
            let suffix=try XCTUnwrap(input.allCandidateRows.first{$0.text=="世界"})
            try choose(suffix,route:route,input:input,client:c)
            XCTAssertEqual(c.view.string,"前：你好世界");XCTAssertFalse(c.view.hasMarkedText());XCTAssertTrue(e.rawInput.isEmpty)
        }
    }
    func testPreviousOwnedCommitDoesNotBlockFollowingLongSentence()throws {
        let e=try engine();defer{e.clear();e.finish()};_ = e.privacy(false)
        let c=client(),input=MacInputSession(engine:e,now:{100})
        for ch in "nihao" {XCTAssertTrue(input.input(String(ch),keyCode:-1,flags:0,client:c))}
        XCTAssertTrue(input.input(nil,keyCode:49,flags:0,client:c));XCTAssertEqual(c.view.string,"前：你好")
        let token=try XCTUnwrap(Mirror(reflecting:input).children.first{$0.label=="ownCommit"}?.value)
        XCTAssertFalse(Mirror(reflecting:token).children.isEmpty,"Exercise actual recent-commit tracking")
        for ch in "womingtianxianggennimenyiqiqugongyuansanburanhuohuijiachifan" {XCTAssertTrue(input.input(String(ch),keyCode:-1,flags:0,client:c))}
        let row=try XCTUnwrap(input.highlightedCandidate)
        XCTAssertTrue(input.input(nil,keyCode:49,flags:0,client:c))
        XCTAssertEqual(c.view.string,"前：你好"+row.text);XCTAssertFalse(c.view.hasMarkedText());XCTAssertTrue(e.rawInput.isEmpty)
    }
    func testManualExpandedStateSurvivesTypingAndEndsWithComposition()throws {
        let e=try engine();defer{e.clear();e.finish()}
        let c=client(),input=MacInputSession(engine:e);seed("nihao",engine:e,client:c)
        input.toggleExpanded();XCTAssertTrue(input.expanded)
        for ch in "shijie" {XCTAssertTrue(input.input(String(ch),keyCode:-1,flags:0,client:c));XCTAssertTrue(input.expanded)}
        input.toggleExpanded();XCTAssertFalse(input.expanded)
        XCTAssertTrue(input.input("n",keyCode:-1,flags:0,client:c));XCTAssertFalse(input.expanded)
        input.toggleExpanded();input.finishComposition(client:c);_ = input.allCandidateRows;XCTAssertFalse(input.expanded)
        XCTAssertTrue(input.input("n",keyCode:-1,flags:0,client:c));XCTAssertFalse(input.expanded)
    }
    func testPairSettingsAllCombinationsAndBothModesUseNativeCaretWithoutWritingPreferences()throws {
        let e=try engine();defer{e.clear();e.finish()}
        for english in [false,true] {for auto in [false,true] {for inside in [false,true] {
            e.clear();_ = e.switchToEnglish(false)
            let c=client(),input=MacInputSession(engine:e,symbolPairingSettings:{(auto,inside)})
            if english {input.toggleEnglish(client:c)}
            XCTAssertTrue(input.input("(",keyCode:-1,flags:0,client:c))
            XCTAssertEqual(c.view.string,auto ? "前：()":"前：(")
            XCTAssertEqual(c.view.selectedRange().location,auto && inside ? 3:(auto ? 4:3))
            XCTAssertFalse(c.view.hasMarkedText())
        }}}
    }
    private func prepareUserReportedPrefix(engine e:NativeEngine,input:MacInputSession,client c:Client,raw:String="wokankanzhegedaoshihounengyouduochang",arrow:Int=125,flags:Int=0)throws {
        seed(raw,engine:e,client:c)
        // The public dictionary exposes this as two unfinished choices; a
        // nonexistent single 我看看这个 row must not be invented by the test.
        for text in ["我看看","这个"] {
            let prefix=try XCTUnwrap(e.candidateBatch(offset:0,limit:128).first{$0.text==text},text)
            XCTAssertNil(prefix.pinyinRepair,"The visible native prefix must not be replaced by a same-text repair")
            input.chooseCandidate(prefix,client:c)
            XCTAssertEqual(e.rawInput,raw,"Selecting a prefix must retain every remaining typed key")
            XCTAssertTrue(c.view.hasMarkedText());XCTAssertFalse(e.rawInput.isEmpty)
        }
        XCTAssertTrue(input.input(nil,keyCode:arrow,flags:flags,client:c));XCTAssertTrue(input.expanded)
        XCTAssertEqual(e.compositionSelectionForAcceptance.prefix,"我看看这个")
        XCTAssertEqual(e.compositionSelectionForAcceptance.offset,13)
    }
    func testUserReportedSelectedPrefixExpandedAllCommitRoutes()throws {
        let e=try engine();defer{e.clear();e.finish()};_ = e.setMixedEnglishEnabled(true)
        for arrow in [125,126] {for flags in [0,Int(NSEvent.ModifierFlags([.function,.numericPad]).rawValue)] {for route in ["nil","empty","space","number","click"] {
            let c=client(),input=MacInputSession(engine:e)
            try prepareUserReportedPrefix(engine:e,input:input,client:c,arrow:arrow,flags:flags)
            XCTAssertEqual(e.preedit,"我看看这个dao shi hou neng you duo chang")
            XCTAssertEqual(e.rawInput,"wokankanzhegedaoshihounengyouduochang")
            let row=try XCTUnwrap(input.highlightedCandidate)
            XCTAssertEqual(row.text,"到时候能有多长","Natural active-tail decoding must precede correction hypotheses")
            XCTAssertNil(row.pinyinRepair)
            print("USER_PREFIX route=\(route) count=\(input.allCandidateRows.count) first=\(row.text) repair=\(row.pinyinRepair ?? "nil") index=\(row.index) gen=\(row.generation ?? -1)/\(e.revision)")
            try choose(row,route:route,input:input,client:c)
            XCTAssertEqual(c.view.string,"前：我看看这个"+row.text,route)
            XCTAssertTrue(e.rawInput.isEmpty,route);XCTAssertFalse(c.view.hasMarkedText(),route)
        }}}
    }
    func testUserReportedSelectedPrefixRemainsEditableWhileExpanded()throws {
        let e=try engine();defer{e.clear();e.finish()};_ = e.setMixedEnglishEnabled(true)
        let c=client(),input=MacInputSession(engine:e)
        try prepareUserReportedPrefix(engine:e,input:input,client:c,raw:"wokankanzheged")
        for ch in "aoshihounengyouduochang" {
            XCTAssertTrue(input.input(String(ch),keyCode:-1,flags:0,client:c))
            XCTAssertTrue(input.expanded);XCTAssertTrue(c.view.hasMarkedText())
        }
        XCTAssertEqual(e.rawInput,"wokankanzhegedaoshihounengyouduochang")
        XCTAssertEqual(e.preedit,"我看看这个dao shi hou neng you duo chang")
        XCTAssertTrue(input.input("d",keyCode:-1,flags:0,client:c))
        XCTAssertEqual(e.rawInput,"wokankanzhegedaoshihounengyouduochangd")
        XCTAssertTrue(input.input("e",keyCode:-1,flags:0,client:c))
        let row=try XCTUnwrap(input.highlightedCandidate)
        try choose(row,route:"nil",input:input,client:c)
        XCTAssertEqual(c.view.string,"前：我看看这个"+row.text)
        XCTAssertTrue(e.rawInput.isEmpty);XCTAssertFalse(c.view.hasMarkedText())
    }

    func testUserReportedEveryVisibleRepairRemainsSelectableWithConfirmedPrefix()throws {
        let e=try engine();defer{e.clear();e.finish()};_ = e.setMixedEnglishEnabled(true)
        let firstClient=client(),firstInput=MacInputSession(engine:e)
        try prepareUserReportedPrefix(engine:e,input:firstInput,client:firstClient)
        let repairs=firstInput.allCandidateRows.filter{$0.pinyinRepair != nil && $0.pinyinRemainder==nil}
        XCTAssertFalse(repairs.isEmpty,"The ranking fix must preserve correction alternatives")
        for (position,choice) in repairs.enumerated() {
            let c=client(),input=MacInputSession(engine:e)
            try prepareUserReportedPrefix(engine:e,input:input,client:c)
            let row=try XCTUnwrap(input.allCandidateRows.first{$0.text==choice.text && $0.comment==choice.comment && $0.pinyinRepair==choice.pinyinRepair})
            try choose(row,route:["nil","number","click"][position%3],input:input,client:c)
            XCTAssertEqual(c.view.string,"前：我看看这个"+row.text,"visible repair \(position): \(row.text)")
            XCTAssertTrue(e.rawInput.isEmpty);XCTAssertFalse(c.view.hasMarkedText())
        }
    }
    func testUserReportedCommittedPrefixThenTailIsDistinctAndWorks()throws {
        let e=try engine();defer{e.clear();e.finish()};_ = e.setMixedEnglishEnabled(true)
        let c=client(),input=MacInputSession(engine:e)
        seed("wokankanzhege",engine:e,client:c)
        for text in ["我看看","这个"] {
            let row=try XCTUnwrap(e.candidateBatch(offset:0,limit:128).first{$0.text==text})
            input.chooseCandidate(row,client:c)
        }
        XCTAssertEqual(c.view.string,"前：我看看这个");XCTAssertFalse(c.view.hasMarkedText())
        for (position,ch) in "daoshihounengyouduochang".enumerated() {
            XCTAssertTrue(input.input(String(ch),keyCode:-1,flags:0,client:c))
            if position==2 {XCTAssertTrue(input.input(nil,keyCode:125,flags:Int(NSEvent.ModifierFlags([.function,.numericPad]).rawValue),client:c))}
        }
        XCTAssertTrue(input.expanded)
        XCTAssertEqual(e.preedit,"dao shi hou neng you duo chang","The committed prefix is outside the marked range in this path")
        let row=try XCTUnwrap(input.highlightedCandidate)
        try choose(row,route:"nil",input:input,client:c)
        XCTAssertEqual(c.view.string,"前：我看看这个"+row.text);XCTAssertTrue(e.rawInput.isEmpty);XCTAssertFalse(c.view.hasMarkedText())
    }

    func testUserReportedArrowExpandedMultiplePartialChoicesKeepAsciiOffsetContract()throws {
        let e=try engine();defer{e.clear();e.finish()};_ = e.setMixedEnglishEnabled(true)
        let raw="wokankanzhegedaoshihounengyouduochang"
        for arrow in [125,126] {for flags in [0,Int(NSEvent.ModifierFlags([.function,.numericPad]).rawValue)] {for route in ["nil","number","click"] {
            let c=client(),input=MacInputSession(engine:e)
            try prepareUserReportedPrefix(engine:e,input:input,client:c,arrow:arrow,flags:flags)
            for (text,prefix,offset) in [("到时候","我看看这个到时候",22),("能","我看看这个到时候能",26),("有","我看看这个到时候能有",29),("多长","",-1)] {
                let row=try XCTUnwrap(e.candidateBatch(offset:0,limit:128).first{$0.text==text && $0.pinyinRepair==nil})
                XCTAssertEqual(row.generation,e.revision)
                try choose(row,route:route,input:input,client:c)
                if offset>=0 {
                    XCTAssertEqual(e.rawInput,raw)
                    XCTAssertEqual(e.compositionSelectionForAcceptance.prefix,prefix)
                    XCTAssertEqual(e.compositionSelectionForAcceptance.offset,offset)
                    XCTAssertTrue(input.expanded);XCTAssertTrue(c.view.hasMarkedText())
                }
                print("USER_PARTIAL arrow=\(arrow) flags=\(flags) route=\(route) text=\(text) raw=\(e.rawInput) prefix=\(e.compositionSelectionForAcceptance.prefix) offset=\(e.compositionSelectionForAcceptance.offset) revision=\(e.revision)")
            }
            XCTAssertEqual(c.view.string,"前：我看看这个到时候能有多长")
            XCTAssertTrue(e.rawInput.isEmpty);XCTAssertFalse(c.view.hasMarkedText());XCTAssertFalse(input.expanded)
        }}}
    }

    func testUserReportedNaturalWholeSentenceIsNotReplacedBySameTextRepair()throws {
        let e=try engine();defer{e.clear();e.finish()};_ = e.setMixedEnglishEnabled(true)
        let c=client(),input=MacInputSession(engine:e)
        seed("wokankanzhegedaoshihounengyouduochang",engine:e,client:c)
        let first=try XCTUnwrap(input.allCandidateRows.first)
        XCTAssertEqual(first.text,"我看看这个到时候能有多长")
        XCTAssertNil(first.pinyinRepair)
        try choose(first,route:"nil",input:input,client:c)
        XCTAssertEqual(c.view.string,"前：我看看这个到时候能有多长");XCTAssertTrue(e.rawInput.isEmpty)
    }

}
