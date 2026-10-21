import AppKit
import Carbon

// Synthetic acceptance host only; never opens files or reads other apps.
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 360), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
window.title = "PrivateInput Synthetic Host"
window.isReleasedWhenClosed = false
let container = NSView()
window.contentView = container
let caption = NSTextField(labelWithString: "合成输入验收")
caption.font = .systemFont(ofSize: 15, weight: .semibold)
let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 580, height: 260))
text.isRichText = false; text.font = .systemFont(ofSize: 22)
text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticSpellingCorrectionEnabled = false
text.setAccessibilityIdentifier("synthetic-input-editor")
scroll.documentView = text
let initialSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
let originalSource: String? = {
    guard let property = TISGetInputSourceProperty(initialSource, kTISPropertyInputSourceID) else { return nil }
    return Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String
}()
let useOwn = NSButton(title: "选择灵鹤输入法", target: nil, action: nil)
let restore = NSButton(title: "恢复原输入源", target: nil, action: nil)
final class Actions: NSObject {
    let text: NSTextView; let original: NSTextInputSourceIdentifier?
    init(_ text: NSTextView, original: NSTextInputSourceIdentifier?) { self.text = text; self.original = original }
    @objc func selectOwn() {
        text.window?.makeFirstResponder(text)
        text.inputContext?.selectedKeyboardInputSource = "live.linghe.privateinput.inputmethod.PrivateInput.Hans"
        text.inputContext?.activate()
        let expected="live.linghe.privateinput.inputmethod.PrivateInput.Hans"
        var result:OSStatus = -1
        if let list=TISCreateInputSourceList(nil,true)?.takeRetainedValue() {
            for i in 0..<CFArrayGetCount(list) {
                let source=unsafeBitCast(CFArrayGetValueAtIndex(list,i),to:TISInputSource.self)
                guard let p=TISGetInputSourceProperty(source,kTISPropertyInputSourceID),Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String == expected else { continue }
                result=TISSelectInputSource(source);break
            }
        }
        let current=TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let p=TISGetInputSourceProperty(current,kTISPropertyInputSourceID)
        let selected=p.map{Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String} == expected
        caption.stringValue=selected ? "私享来源已选":"来源未选（\(result)）"
        NSLog("PRIVATE_INPUT_HOST_SELECT result=%d own=%d",result,selected ? 1:0)
    }
    @objc func restoreSource() {
        text.window?.makeFirstResponder(text)
        if let original { text.inputContext?.selectedKeyboardInputSource = original };_ = TISSelectInputSource(initialSource)
    }
}
let actions = Actions(text, original: originalSource)
final class HostDelegate:NSObject,NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification:Notification) { actions.restoreSource() }
}
let hostDelegate=HostDelegate();app.delegate=hostDelegate
useOwn.target = actions; useOwn.action = #selector(Actions.selectOwn)
restore.target = actions; restore.action = #selector(Actions.restoreSource)
let buttons = NSStackView(views: [useOwn, restore]); buttons.orientation = .horizontal; buttons.spacing = 12
for view in [caption, buttons, scroll] { view.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(view) }
NSLayoutConstraint.activate([
    caption.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
    caption.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
    buttons.leadingAnchor.constraint(equalTo: caption.trailingAnchor, constant: 24),
    buttons.centerYAnchor.constraint(equalTo: caption.centerYAnchor),
    scroll.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 16),
    scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
    scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
    scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16)
])
window.center(); window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(text)
app.activate(ignoringOtherApps: false)
app.run()
