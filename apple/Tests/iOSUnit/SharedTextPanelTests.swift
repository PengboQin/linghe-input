import XCTest
import UIKit
import PrivateInputKit

@MainActor final class SharedTextPanelTests: XCTestCase {
    private var window: UIWindow!
    private var panel: SharedTextPanel!
    override func setUp() {
        super.setUp()
        let host=UIViewController()
        if let scene=UIApplication.shared.connectedScenes.compactMap({$0 as? UIWindowScene}).first { window=UIWindow(windowScene:scene) }
        else { window=UIWindow(frame:UIScreen.main.bounds) }
        window.rootViewController=host;window.makeKeyAndVisible()
        panel=SharedTextPanel();host.addChild(panel);host.view.addSubview(panel.view)
        panel.view.frame=CGRect(x:0,y:100,width:393,height:280);panel.didMove(toParent:host)
    }
    override func tearDown() {
        panel.dismissPanel();window.isHidden=true;window.rootViewController=nil;panel=nil;window=nil
        super.tearDown()
    }
    private func clip(_ text:String,expiry:UInt64) throws -> ReceivedClipboard {
        let object:[String:Any]=["id":UUID().uuidString,"sender":UUID().uuidString,"text":text,"expiresAt":expiry]
        return try JSONDecoder().decode(ReceivedClipboard.self,from:JSONSerialization.data(withJSONObject:object))
    }
    private func list() -> UITableViewController { panel.viewControllers[0] as! UITableViewController }
    private func layout() { window.layoutIfNeeded();panel.view.setNeedsLayout();panel.view.layoutIfNeeded();list().tableView.layoutIfNeeded() }
    private func openFirstDetail() {
        layout()
        let cell=list().tableView.cellForRow(at:IndexPath(row:0,section:0))
        XCTAssertNotNil(cell)
        (cell?.accessoryView as? UIButton)?.sendActions(for:.touchUpInside)
        panel.view.layoutIfNeeded();panel.topViewController?.loadViewIfNeeded()
    }
    private func textView(_ root:UIView) -> UITextView? {
        if let value=root as? UITextView { return value }
        return root.subviews.compactMap { textView($0) }.first
    }
    func testFullTextNeverInsertsUntilTheRowIsExplicitlySelected() throws {
        let value=try clip(String(repeating:"合成全文，不应在阅读时插入。",count:40)+"尾部",expiry:UInt64(Date().timeIntervalSince1970)+60)
        var received:UUID?
        panel.select={received=$0};panel.show([value]);openFirstDetail()
        XCTAssertEqual(panel.viewControllers.count,2)
        let text=textView(panel.topViewController!.view)
        XCTAssertEqual(text?.text,value.text);XCTAssertEqual(text?.isEditable,false);XCTAssertNil(received)
        panel.popViewController(animated:false);layout()
        let table=list().tableView!
        table.delegate?.tableView?(table,didSelectRowAt:IndexPath(row:0,section:0))
        XCTAssertEqual(received,value.id)
        panel.dismissPanel();XCTAssertFalse(panel.isShowing);XCTAssertEqual(list().tableView.numberOfRows(inSection:0),0)
    }
    func testRevocationPurgesTheVisibleListAndFullText() throws {
        let value=try clip("合成撤权文本",expiry:UInt64(Date().timeIntervalSince1970)+60)
        var issue:String?
        panel.availabilityIssue={issue};panel.show([value]);openFirstDetail()
        issue="共享已暂停"
        let cleared=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in
            self.textView(self.panel.topViewController!.view)?.text=="共享已暂停"
        },object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[cleared],timeout:3),.completed)
        XCTAssertEqual(list().tableView.numberOfRows(inSection:0),0)
        XCTAssertEqual(textView(panel.topViewController!.view)?.isSelectable,false)
        XCTAssertEqual(panel.topViewController?.navigationItem.rightBarButtonItem?.isEnabled,false)
    }
    func testExpiredRowsAreExcludedAndRefreshingInvalidatesAnOpenDetail() throws {
        let now=UInt64(Date().timeIntervalSince1970)
        let expired=try clip("已过期合成文本",expiry:now-1),valid=try clip("有效合成文本",expiry:now+60)
        panel.show([expired,valid]);layout();XCTAssertEqual(list().tableView.numberOfRows(inSection:0),1)
        openFirstDetail();panel.show([],status:"文本已过期")
        XCTAssertEqual(textView(panel.topViewController!.view)?.text,"文本已过期")
        XCTAssertEqual(panel.topViewController?.navigationItem.rightBarButtonItem?.isEnabled,false)
    }
}
