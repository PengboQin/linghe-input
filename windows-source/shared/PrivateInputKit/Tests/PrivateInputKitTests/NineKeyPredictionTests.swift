import XCTest
@testable import PrivateInputKit

final class NineKeyPredictionTests:XCTestCase {
    func testBoundaryEditsCoverCrossSpanSwapsWithoutChangingOriginalSearch() {
        let source="6442664426744543",spans=[NineKeySpan(start:0,end:8),NineKeySpan(start:8,end:15)]
        let old=NineKeySentencePlanner.alternatives(code:source,spans:spans)
        var target=Array(source);target.swapAt(7,8)
        let corrected=String(target),extra=NineKeySentencePlanner.boundaryAlternatives(code:source,spans:spans)
        XCTAssertFalse(old.contains{$0.input==corrected})
        XCTAssertTrue(extra.contains{$0.input==corrected})
        XCTAssertTrue(extra.allSatisfy{NineKeySpelling.editCost(source,$0.input) != nil})
        XCTAssertEqual(extra.map(\.input),NineKeySentencePlanner.boundaryAlternatives(code:source,spans:spans).map(\.input))
        XCTAssertEqual(Set(extra.map(\.input)).count,extra.count);XCTAssertLessThanOrEqual(extra.count,12)
        XCTAssertTrue(NineKeySentencePlanner.boundaryAlternatives(code:"64426",spans:spans).isEmpty)
        XCTAssertTrue(NineKeySentencePlanner.boundaryAlternatives(code:source,spans:spans,limit:0).isEmpty)
        let long=String(repeating:"64426",count:19),ranges=stride(from:0,to:95,by:8).map{NineKeySpan(start:$0,end:min($0+8,95))}
        XCTAssertLessThanOrEqual(NineKeySentencePlanner.boundaryAlternatives(code:long,spans:ranges).count,12)
    }
    func testMaximumTailPlanningIsBoundedAndKeepsIndependentValidation() {
        let code=String(repeating:"64426442",count:12),chars=Array(code)
        var hypotheses:[NineKeyLocalHypothesis]=[]
        for start in stride(from:0,to:96,by:8) {
            let span=NineKeySpan(start:start,end:start+8)
            for (index,h) in NineKeySpelling.alternatives(String(chars[start..<start+8]),limit:16).enumerated() {
                hypotheses.append(.init(span:span,input:h.input,cost:h.cost,score:-Double(index)))
            }
        }
        let start=Date.timeIntervalSinceReferenceDate
        let result=NineKeySentencePlanner.jointAlternatives(code:code,hypotheses:hypotheses)
        print("SYNTHETIC_MAX_PLAN elapsed_ms=\((Date.timeIntervalSinceReferenceDate-start)*1000) queries=\(result.count)")
        XCTAssertEqual(result.count,32);XCTAssertEqual(Set(result.map(\.input)).count,32)
        // Validate outputs independently, outside the interactive planner.
        XCTAssertTrue(result.allSatisfy{NineKeySpelling.jointEditCost(code,$0.input) != nil})
    }
    func testNeighborContextRequiresExactSyllableAlignment() {
        let code=NineKeySpelling.encode("jin tian xia wu wo men")!
        let neighbors=NineKeySentencePlanner.neighbors(code:code,reading:"jin tian xia wu wo men",text:"今天下午我们",span:.init(start:0,end:7))
        XCTAssertEqual(neighbors?.before,"");XCTAssertEqual(neighbors?.after,"下午我")
        XCTAssertNil(NineKeySentencePlanner.neighbors(code:code,reading:"jin tian",text:"今天下午我们",span:.init(start:0,end:7)))
        XCTAssertNil(NineKeySentencePlanner.neighbors(code:code,reading:"jin tian xia wu wo men",text:"今天下午我们",span:.init(start:1,end:7)))
    }
    func testTwoEditsAreBoundedIndependentAndLegacyValidationStaysStrict() throws {
        XCTAssertNotNil(NineKeySpelling.jointEditCost("6444266426","6442664426"))
        XCTAssertNotNil(NineKeySpelling.jointEditCost("6446264462","6442664426"))
        XCTAssertNil(NineKeySpelling.jointEditCost("2222","9999"))
        XCTAssertNil(NineKeySpelling.jointEditCost("64426","64422226"))
        var memory=NineKeyChoiceMemory()
        try memory.record(code:"6444266426",reading:"ni hao ni hao",text:"你好你好",context:"说完。今天，我说",strength:2)
        XCTAssertEqual(memory.entries[0].context,"今天我说")
        var legacy=memory;legacy.version=2;XCTAssertThrowsError(try legacy.validate())
        try memory.validate()
        XCTAssertGreaterThan(memory.boost(code:memory.entries[0].code,reading:"ni hao ni hao",text:"你好你好",context:"今天我说"),memory.boost(code:memory.entries[0].code,reading:"ni hao ni hao",text:"你好你好",context:"别的句子"))
        XCTAssertEqual(SentenceContextWindow.preferenceContext("上一句。新的句子，"),"新的句子")
    }
    func testJointPairingUsesOriginalCoordinatesAndRejectsOverlaps() {
        let code="6444266426"
        let first=NineKeyLocalHypothesis(span:.init(start:0,end:6),input:"64426",cost:1.5,score:10)
        let second=NineKeyLocalHypothesis(span:.init(start:6,end:10),input:"64426",cost:1.5,score:10)
        let pairs=NineKeySentencePlanner.jointAlternatives(code:code,hypotheses:[first,second])
        XCTAssertEqual(pairs.map(\.input),["6442664426"])
        XCTAssertEqual(pairs.first?.cost,3)
        XCTAssertEqual(NineKeySentencePlanner.jointAlternatives(code:code,hypotheses:[first,first]).count,0)
        XCTAssertTrue(NineKeySentencePlanner.jointAlternatives(code:code,hypotheses:[first,second],limit:0).isEmpty)
        XCTAssertEqual(pairs.map(\.input),NineKeySentencePlanner.jointAlternatives(code:code,hypotheses:[first,second]).map(\.input))
    }
    func testLegacyMigrationPreservesCountsAndNewContextPreferences() throws {
        let legacy=Data(#"{"version":1,"entries":[{"code":"64425","reading":"nihao","text":"你好","context":"我说","count":5}]}"#.utf8)
        let old=try JSONDecoder().decode(NineKeyChoiceMemory.self,from:legacy);let migrated=try old.migrated()
        XCTAssertEqual(migrated.version,3);XCTAssertEqual(migrated.entries,old.entries)
        var model=migrated
        try model.record(code:"64425",reading:"ni hao",text:"你好",context:"今天这个时候我说",strength:2)
        XCTAssertGreaterThan(model.boost(code:"64425",reading:"nihao",text:"你好",context:"今天这个时候我说"),model.boost(code:"64425",reading:"nihao",text:"你好",context:"完全不同"))
        model.reset(text:"你好",reading:"ni hao");XCTAssertTrue(model.entries.isEmpty)
        XCTAssertEqual(old.entries.count,1)
    }
    func testLongSentenceSpansAreAlignedAndShareOneBudget() {
        let reading="ni hao wo xiang he shui",code=NineKeySpelling.encode(reading)!
        let spans=NineKeySentencePlanner.spans(code:code,reading:reading,wordLengths:[2,1,1,2])
        XCTAssertEqual(spans.first?.start,0);XCTAssertEqual(spans.last?.end,code.count)
        XCTAssertTrue(spans.allSatisfy{$0.end-$0.start<=12})
        let variants=NineKeySentencePlanner.alternatives(code:code,spans:spans)
        XCTAssertFalse(variants.isEmpty);XCTAssertLessThanOrEqual(variants.count,64)
        XCTAssertTrue(variants.allSatisfy{NineKeySpelling.isRelated(code,$0.input)})
        let context=SentenceContextWindow.append("今天下午开完会之后，",to:"")
        XCTAssertEqual(SentenceContextWindow.scoringContext(context).text,"今天下午开完会之后")
        XCTAssertEqual(SentenceContextWindow.scoringContext(context+"。 ".trimmingCharacters(in:.whitespaces)).weight,0.3)
        XCTAssertEqual(SentenceContextWindow.append(String(repeating:"甲",count:200),to:context).count,128)
    }
    func testMissingExtraAndTransposedKeysShareBudgetWithoutDroppingOriginal() throws {
        XCTAssertTrue(NineKeySpelling.alternatives("644426").contains{$0.input=="64426"})
        XCTAssertTrue(NineKeySpelling.alternatives("6426").contains{$0.input=="64426"})
        XCTAssertTrue(NineKeySpelling.alternatives("64462").contains{$0.input=="64426"})
        XCTAssertEqual(NineKeySpelling.editCost("644426","64426"),1.5)
        XCTAssertNotNil(NineKeySpelling.editCost("6426","64426"))
        XCTAssertNil(NineKeySpelling.editCost("2222","9999"))
        var model=NineKeyChoiceMemory()
        try model.record(code:"6426",reading:"ni hao",text:"你好",context:"")
        try model.record(code:"644426",reading:"ni hao",text:"你好",context:"")
        XCTAssertEqual(model.entries.count,2)
        XCTAssertFalse(NineKeySpelling.alternatives("64426").contains{$0.input=="64426"})
    }
    func testGridAdjacencyIncludesUpDownAndKeepsBudget() {
        let variants=NineKeySpelling.alternatives("64425")
        XCTAssertTrue(variants.contains{$0.input=="64426" && $0.cost==1})
        XCTAssertTrue(variants.contains{$0.input=="64428" && $0.cost==1})
        XCTAssertFalse(variants.contains{$0.input=="64421"})
        XCTAssertLessThanOrEqual(variants.count,32)
        XCTAssertEqual(Set(variants.map(\.input)).count,variants.count)
        XCTAssertTrue(NineKeySpelling.alternatives("ni4425").isEmpty)
        XCTAssertEqual(NineKeySpelling.encode("ni hao"),"64426")
    }
    func testConfirmedChoicesAreContextSpecificBoundedAndResettable() throws {
        var memory=NineKeyChoiceMemory()
        try memory.record(code:"64425",reading:"ni hao",text:"你好",context:"")
        let first=memory.boost(code:"64425",reading:"ni hao",text:"你好",context:"")
        try memory.record(code:"64425",reading:"ni hao",text:"你好",context:"")
        XCTAssertGreaterThan(memory.boost(code:"64425",reading:"ni hao",text:"你好",context:""),first)
        XCTAssertGreaterThan(memory.boost(code:"64425",reading:"ni hao",text:"你好",context:"别的上下文"),0)
        let original=memory
        XCTAssertThrowsError(try memory.record(code:"99999",reading:"ni hao",text:"你好",context:""))
        XCTAssertEqual(memory,original)
        memory.reset(text:"你好",reading:"ni'hao");XCTAssertTrue(memory.entries.isEmpty)
    }
    func testConfirmedCorrectionOvertakesOlderHomophoneWithoutErasingIt() throws {
        var memory=NineKeyChoiceMemory()
        for _ in 0..<8 { try memory.record(code:"64426",reading:"ni hao",text:"拟好",context:"我说",strength:3) }
        try memory.recordCorrection(code:"64426",reading:"ni hao",text:"你好",context:"我说")
        let old=try XCTUnwrap(memory.entries.first{$0.text=="拟好"}),new=try XCTUnwrap(memory.entries.first{$0.text=="你好"})
        XCTAssertEqual(old.count,24);XCTAssertGreaterThan(new.count,old.count)
        XCTAssertEqual(memory.version,3);try memory.validate()
        XCTAssertEqual(try JSONDecoder().decode(NineKeyChoiceMemory.self,from:JSONEncoder().encode(memory)),memory)
    }
    func testPartialOwnSuffixNeedsExactReadingAlignmentAndAnchor() {
        var tracker=OwnCommitCorrectionTracker()
        tracker.stage(document:"field",anchor:"a",text:"你号",code:"64426",context:"我说",time:100,reading:"ni hao")
        XCTAssertNil(tracker.deleted(document:"field",anchor:"a",time:101))
        let signal=tracker.partiallyDeleted(document:"field",anchor:"a",time:102)
        XCTAssertEqual(signal?.code,"426");XCTAssertEqual(signal?.rejectedText,"号");XCTAssertEqual(signal?.reading,"hao");XCTAssertEqual(signal?.context,"我说你")
        XCTAssertNil(tracker.partiallyDeleted(document:"field",anchor:"other",time:102))
        XCTAssertNil(tracker.partiallyDeleted(document:"other",anchor:"a",time:102))
        tracker.stage(document:"field",anchor:"a",text:"你号",code:"64425",context:"",time:100,reading:"ni hao")
        XCTAssertNil(tracker.deleted(document:"field",anchor:"a",time:101));XCTAssertNil(tracker.partiallyDeleted(document:"field",anchor:"a",time:102))
    }
    func testOnlyFullRemovalOfRecentOwnCommitCreatesCorrectionSignal() {
        var tracker=OwnCommitCorrectionTracker()
        tracker.stage(document:"field",anchor:"opaque-anchor",text:"你好",code:"64425",context:"我说",time:100)
        XCTAssertEqual(tracker.expectedText(document:"field",time:101),"你好")
        XCTAssertNil(tracker.deleted(document:"field",anchor:"opaque-anchor",time:101))
        XCTAssertEqual(tracker.expectedText(document:"field",time:101),"你")
        let replacement=tracker.deleted(document:"field",anchor:"opaque-anchor",time:102)
        XCTAssertEqual(replacement?.code,"64425");XCTAssertEqual(replacement?.context,"我说")
        tracker.stage(document:"field",anchor:"a",text:"你好",code:"64425",context:"",time:100)
        XCTAssertNil(tracker.deleted(document:"other-field",anchor:"a",time:101))
        tracker.stage(document:"field",anchor:"a",text:"你好",code:"64425",context:"",time:100)
        XCTAssertNil(tracker.deleted(document:"field",anchor:"moved-cursor",time:101))
        tracker.stage(document:"field",anchor:"a",text:"你好",code:"64425",context:"",time:100)
        XCTAssertNil(tracker.expectedText(document:"field",time:221))
    }
}
