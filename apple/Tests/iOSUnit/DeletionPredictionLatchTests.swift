import Foundation
import XCTest

final class DeletionPredictionLatchTests:XCTestCase {
    let document=UUID(uuidString:"00000000-0000-0000-0000-000000000011")!
    func testClearCancelsLatePredictionAndStaysSuppressedThroughIdleAndDeletion() {
        var state=DeletionPredictionLatch();state.observeDocument(document);let pending=state.generation
        state.beginClear()
        XCTAssertFalse(state.acceptsPrediction(generation:pending))
        for _ in 0..<10 {state.observeDocument(document);XCTAssertEqual(state.source(hasComposition:false),.none)}
        state.beginDeletion();state.observeDocument(nil)
        XCTAssertTrue(state.suppressed);XCTAssertEqual(state.source(hasComposition:false),.none)
    }
    func testClearThenRealInputResumesWithoutAcceptingAnOldCompletion() {
        var state=DeletionPredictionLatch();state.beginClear();let clearGeneration=state.generation
        state.beginUserInput()
        XCTAssertEqual(state.source(hasComposition:true),.primary)
        XCTAssertEqual(state.source(hasComposition:false),.continuation)
        XCTAssertFalse(state.acceptsPrediction(generation:clearGeneration))
        XCTAssertTrue(state.acceptsPrediction(generation:state.generation))
    }
    func testClearDoesNotReviveDismissedClipboardWhenTypingResumes() {
        var state=DeletionPredictionLatch(),clipboard=ClipboardCandidateState()
        clipboard.observe(version:4);clipboard.dismiss();state.beginClear();state.beginUserInput()
        XCTAssertFalse(clipboard.available(version:4,allowed:true,hasPrimary:false,deleting:state.suppressed))
        clipboard.observe(version:5)
        XCTAssertTrue(clipboard.available(version:5,allowed:true,hasPrimary:false,deleting:state.suppressed))
    }
    func testDeletingContinuesAcrossHostAndEngineRevisionChanges() {
        var state=DeletionPredictionLatch();state.observeDocument(document)
        state.beginDeletion()
        for _ in 0..<20 {state.observeDocument(document);XCTAssertEqual(state.source(hasComposition:false),.none);XCTAssertFalse(state.acceptsPrediction(generation:state.generation))}
    }
    func testRepeatedAndHeldDeletionNeverReenablesPredictions() {
        var state=DeletionPredictionLatch()
        for _ in 0..<30 {state.beginDeletion();XCTAssertTrue(state.suppressed);XCTAssertEqual(state.source(hasComposition:false),.none)}
    }
    func testPrimaryCompositionCandidatesRemainDuringDeletion() {
        var state=DeletionPredictionLatch();state.beginDeletion()
        XCTAssertEqual(state.source(hasComposition:true),.primary)
        XCTAssertEqual(state.source(hasComposition:false),.none)
        XCTAssertEqual(state.source(hasComposition:true),.primary)
    }
    func testNewUserInputResumesButCannotApplyAnOldRankingCallback() {
        var state=DeletionPredictionLatch();let before=state.generation
        state.beginDeletion();XCTAssertFalse(state.acceptsPrediction(generation:before))
        let deleting=state.generation;state.beginUserInput()
        XCTAssertEqual(state.source(hasComposition:false),.continuation)
        XCTAssertTrue(state.acceptsPrediction(generation:state.generation))
        XCTAssertFalse(state.acceptsPrediction(generation:before));XCTAssertFalse(state.acceptsPrediction(generation:deleting))
    }
    func testSameDocumentRevealAndUnknownDocumentCannotClearDeletion() {
        var state=DeletionPredictionLatch();state.observeDocument(document);state.beginDeletion();let generation=state.generation
        state.observeDocument(nil);state.observeDocument(document);state.observeDocument(nil)
        XCTAssertTrue(state.suppressed);XCTAssertEqual(state.generation,generation)
    }
    func testFirstKnownDocumentDoesNotInventAChangeFromUnknown() {
        var state=DeletionPredictionLatch();state.beginDeletion();state.observeDocument(nil);state.observeDocument(document)
        XCTAssertTrue(state.suppressed)
    }
    func testConfirmedNewDocumentResetsOnlyThisEditingSession() {
        var state=DeletionPredictionLatch();state.observeDocument(document);state.beginDeletion();let prior=state.generation
        state.observeDocument(UUID(uuidString:"00000000-0000-0000-0000-000000000012")!)
        XCTAssertFalse(state.suppressed);XCTAssertEqual(state.source(hasComposition:false),.continuation)
        XCTAssertFalse(state.acceptsPrediction(generation:prior))
    }
}
