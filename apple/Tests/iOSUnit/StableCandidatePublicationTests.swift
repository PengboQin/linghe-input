import Foundation
import XCTest

final class StableCandidatePublicationTests: XCTestCase {
    struct Row { let id: String; let action: String }
    let document=UUID(uuidString:"00000000-0000-0000-0000-000000000001")!
    private func row(_ id:String,_ action:String="original")->Row {Row(id:id,action:action)}
    func testSlowSemanticResultCannotReorderReadableChoices() {
        var state=StableCandidatePublication<Row,String>()
        let initial=state.publish([row("今天"),row("仅"),row("进")],revision:4,document:document,identity:{$0.id})
        let late=state.publish([row("进"),row("今天"),row("仅")],revision:4,document:document,identity:{$0.id})
        XCTAssertEqual(late.map(\.id),initial.map(\.id))
    }
    func testNewCorrectionsAppendAndDoNotReplaceAnExistingAction() {
        var state=StableCandidatePublication<Row,String>()
        _=state.publish([row("好","original-native-id")],revision:4,document:document,identity:{$0.id})
        let late=state.publish([row("号"),row("好","different-assembly-id")],revision:4,document:document,identity:{$0.id})
        XCTAssertEqual(late.map(\.id),["好","号"])
        XCTAssertEqual(late[0].action,"original-native-id")
    }
    func testEmptyFirstBatchDoesNotBlockFirstAvailableResults() {
        var state=StableCandidatePublication<Row,String>()
        XCTAssertTrue(state.publish([],revision:4,document:document,identity:{$0.id}).isEmpty)
        XCTAssertEqual(state.publish([row("哈哈好")],revision:4,document:document,identity:{$0.id}).map(\.id),["哈哈好"])
    }
    func testNewKeyAndPartialSelectionMayPublishNewOrder() {
        var state=StableCandidatePublication<Row,String>()
        _=state.publish([row("今天"),row("仅")],revision:4,document:document,identity:{$0.id})
        XCTAssertEqual(state.publish([row("仅"),row("今天")],revision:5,document:document,identity:{$0.id}).map(\.id),["仅","今天"])
    }
    func testNewDocumentAndExplicitResetDiscardOldChoices() {
        var state=StableCandidatePublication<Row,String>()
        _=state.publish([row("旧")],revision:4,document:document,identity:{$0.id})
        let other=UUID(uuidString:"00000000-0000-0000-0000-000000000002")!
        XCTAssertEqual(state.publish([row("新")],revision:4,document:other,identity:{$0.id}).map(\.id),["新"])
        state.reset()
        XCTAssertEqual(state.publish([row("重置")],revision:4,document:other,identity:{$0.id}).map(\.id),["重置"])
    }
    func testPaginationAfterLateCorrectionIsMonotonicAndDeduplicated() {
        var state=StableCandidatePublication<Row,String>()
        _=state.publish([row("a"),row("b")],revision:4,document:document,identity:{$0.id})
        _=state.publish([row("c"),row("a")],revision:4,document:document,identity:{$0.id})
        let page=state.publish([row("b"),row("d"),row("e"),row("d")],revision:4,document:document,identity:{$0.id})
        XCTAssertEqual(page.map(\.id),["a","b","c","d","e"])
    }
    func testRefreshReturningEmptyDoesNotRemovePendingTargets() {
        var state=StableCandidatePublication<Row,String>()
        _=state.publish([row("我想玩去了")],revision:4,document:nil,identity:{$0.id})
        XCTAssertEqual(state.publish([],revision:4,document:nil,identity:{$0.id}).map(\.id),["我想玩去了"])
        XCTAssertTrue(state.publish([],revision:5,document:nil,identity:{$0.id}).isEmpty)
    }
}
