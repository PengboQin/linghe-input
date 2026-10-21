import AppKit
import InputMethodKit
import Carbon
import CryptoKit

if CommandLine.arguments.contains("--register-own-input-source") {
    let identifier = "live.linghe.privateinput.inputmethod.PrivateInput"
    guard Bundle.main.bundleIdentifier == identifier,
          Bundle.main.bundleURL.path == NSHomeDirectory() + "/Library/Input Methods/PrivateInput.app" else { exit(2) }
    func sourceString(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let value = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }
    func currentHash() -> String {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        return SHA256.hash(data: Data((sourceString(source, kTISPropertyInputSourceID) ?? "unknown").utf8)).map { String(format: "%02x", $0) }.joined()
    }
    let before = currentHash(), status = TISRegisterInputSource(Bundle.main.bundleURL as CFURL)
    var rows: [[String: Any]] = []
    if let list = TISCreateInputSourceList([kTISPropertyBundleID: identifier] as CFDictionary, true)?.takeRetainedValue() {
        for index in 0..<CFArrayGetCount(list) {
            let source = unsafeBitCast(CFArrayGetValueAtIndex(list, index), to: TISInputSource.self)
            rows.append(["id": sourceString(source, kTISPropertyInputSourceID) ?? "unknown", "enableStatus": TISEnableInputSource(source)])
        }
    }
    RunLoop.current.run(until: Date().addingTimeInterval(2))
    let result: [String: Any] = ["registerStatus": status, "sources": rows, "defaultPreserved": before == currentHash()]
    print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
    exit(status == noErr ? 0 : 1)
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let connection = Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String ?? "PrivateInput_1_Connection"
// Settings are exposed by the system input-source menu. Reopening this app
// or launching it with --settings remains an entry when another source is active;
// background pairing is owned by the application, independently of any window.
// Register the input service after AppKit has finished launching. Keep it
// owned by the application delegate for the full application lifetime.
final class PrivateInputApplicationDelegate:NSObject,NSApplicationDelegate {
    private var server:IMKServer?
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool) -> Bool {
        DispatchQueue.main.async { DeviceSyncWindow.shared.show() };return true
    }
    func applicationDidFinishLaunching(_ notification:Notification) {
        let controllerName=NSStringFromClass(PrivateInputController.self)
        guard controllerName == Bundle.main.object(forInfoDictionaryKey:"InputMethodServerControllerClass") as? String,
              let value=IMKServer(name:connection,bundleIdentifier:Bundle.main.bundleIdentifier) else {
            fputs("PrivateInput: input server unavailable\n",stderr);NSApp.terminate(nil);return
        }
        server=value
        DeviceSyncModel.shared.startBackgroundPairing()
        ActivityArchiveCapture.shared.refresh(permitted: true)
        if CommandLine.arguments.contains("--imk-acceptance") { NSLog("PRIVATE_INPUT_IMK application-ready") }
        if CommandLine.arguments.contains("--settings") { DispatchQueue.main.async { DeviceSyncWindow.shared.show() } }
    }
}
let applicationDelegate=PrivateInputApplicationDelegate()
application.delegate=applicationDelegate
withExtendedLifetime(applicationDelegate) { application.run() }
