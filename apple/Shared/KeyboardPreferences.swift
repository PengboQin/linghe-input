import Foundation
import PrivateInputKit

struct KeyboardPreferences {
    static let updated = Notification.Name("PrivateInputKeyboardSettingsUpdated")
    private static let darwinName = "live.linghe.privateinput.keyboard-settings-changed"
    private static let observer: Void = {
        #if os(iOS)
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            NotificationCenter.default.post(name: KeyboardPreferences.updated, object: nil)
        }, darwinName as CFString, nil, .deliverImmediately)
        #endif
    }()
    static func observeUpdates() { _ = observer }

    private struct Snapshot: Codable {
        var rememberWords: Bool
        var defaultLayout: String
        var expandedCandidates: Bool
        var commonSymbols: [String]
        var chineseLayout: String?
        var startInEnglish: Bool?
        var keyPreview: Bool?
        var keyFeedback: String?
        var compositionPosition: String?
        var mixedEnglish: Bool?
        var systemLexicon: Bool?
        var keyboardHeightExtra: Double?
        var keyboardHeightRevision: String?
        var appearanceMode: String?
        var appearanceAccent: String?
        var autoPairSymbols: Bool?
        var caretInsidePairs: Bool?
    }
    private static var snapshotURL: URL? {
        #if os(iOS)
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: LocalLearningCoordinator.groupID)?.appendingPathComponent("keyboard-settings-v1.json")
        #else
        return nil
        #endif
    }
    private static func snapshot() -> Snapshot? {
        guard let url = snapshotURL, let data = try? Data(contentsOf: url), data.count <= 4096 else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
    // The containing app writes an atomic settings snapshot. The keyboard only
    // reads it, including without full access, as with the learning snapshot.
    private static func publish() {
        guard let url = snapshotURL else { return }
        let defaults = store
        let value = Snapshot(rememberWords: defaults.object(forKey: "remember-words") as? Bool ?? true,
            defaultLayout: defaults.string(forKey: "keyboard-layout") ?? "nine",
            expandedCandidates: defaults.bool(forKey: "expanded-candidates"),
            commonSymbols: defaults.stringArray(forKey: "common-symbols") ?? ["，", "。", "！", "？"],
            chineseLayout: defaults.string(forKey: "chinese-layout"),
            startInEnglish: defaults.object(forKey: "start-in-english") as? Bool,
            keyPreview: defaults.object(forKey: "key-preview") as? Bool,
            keyFeedback: defaults.string(forKey: "key-feedback"),
            compositionPosition: defaults.string(forKey: "composition-position"),
            mixedEnglish: defaults.object(forKey:"mixed-english") as? Bool,
            systemLexicon: defaults.object(forKey:"system-lexicon") as? Bool,
            keyboardHeightExtra: defaults.object(forKey:"keyboard-height-extra") as? Double,
            keyboardHeightRevision: defaults.string(forKey:"keyboard-height-revision"),
            appearanceMode: defaults.string(forKey:"appearance-mode"),
            appearanceAccent: defaults.string(forKey:"appearance-accent"),
            autoPairSymbols: defaults.object(forKey:"symbol-auto-pair") as? Bool,
            caretInsidePairs: defaults.object(forKey:"symbol-caret-inside") as? Bool)
        do {
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
            #if os(iOS)
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(rawValue: darwinName as CFString), nil, nil, true)
            #endif
        } catch { /* Retain the last complete snapshot. */ }
    }
    static var store: UserDefaults {
        #if os(iOS)
        return UserDefaults(suiteName: LocalLearningCoordinator.groupID) ?? .standard
        #else
        return .standard
        #endif
    }
    #if os(macOS)
    static var macCapsLockSwitchEnabled:Bool {
        get {store.object(forKey:"mac-caps-lock-language-switch") as? Bool ?? false}
        set {store.set(newValue,forKey:"mac-caps-lock-language-switch");NotificationCenter.default.post(name:updated,object:nil)}
    }
    static var desktopCandidateLayout:DesktopCandidateLayout {
        get {
            guard let data=store.data(forKey:"desktop-candidate-layout-v1"),data.count<=1024,
                  let value=try? JSONDecoder().decode(DesktopCandidateLayout.self,from:data) else{return .init()}
            return value
        }
        set {
            guard let data=try? JSONEncoder().encode(newValue) else{return}
            store.set(data,forKey:"desktop-candidate-layout-v1")
            NotificationCenter.default.post(name:updated,object:nil)
        }
    }
    static var macSemanticEnabled:Bool {
        get {store.object(forKey:"mac-semantic-enabled") as? Bool ?? true}
        set {store.set(newValue,forKey:"mac-semantic-enabled");NotificationCenter.default.post(name:updated,object:nil)}
    }
    #endif
    #if os(iOS)
    static var appearanceTheme: InputTheme {
        get {
            let value = snapshot()
            return InputTheme(mode: value?.appearanceMode ?? store.string(forKey: "appearance-mode"),
                              accent: value?.appearanceAccent ?? store.string(forKey: "appearance-accent"))
        }
        set {
            store.set(newValue.mode.rawValue, forKey: "appearance-mode")
            store.set(newValue.accent.rawValue, forKey: "appearance-accent")
            publish()
            NotificationCenter.default.post(name: updated, object: nil)
        }
    }
    #endif
    static var autoPairSymbols: Bool {
        get { snapshot()?.autoPairSymbols ?? (store.object(forKey: "symbol-auto-pair") as? Bool) ?? true }
        set { store.set(newValue, forKey: "symbol-auto-pair"); publish(); NotificationCenter.default.post(name: updated, object: nil) }
    }
    static var caretInsidePairs: Bool {
        get { snapshot()?.caretInsidePairs ?? (store.object(forKey: "symbol-caret-inside") as? Bool) ?? true }
        set { store.set(newValue, forKey: "symbol-caret-inside"); publish(); NotificationCenter.default.post(name: updated, object: nil) }
    }
    static var rememberWords: Bool {
        get { snapshot()?.rememberWords ?? (store.object(forKey: "remember-words") as? Bool ?? true) }
        set { store.set(newValue, forKey: "remember-words"); publish() }
    }
    static var chineseLayout: String {
        get {
            let value = snapshot()?.chineseLayout ?? store.string(forKey: "chinese-layout") ?? snapshot()?.defaultLayout ?? store.string(forKey: "keyboard-layout")
            return value == "pinyin26" ? "pinyin26" : "nine"
        }
        set { store.set(newValue == "pinyin26" ? "pinyin26" : "nine", forKey: "chinese-layout"); publish() }
    }
    static var startInEnglish: Bool {
        get { snapshot()?.startInEnglish ?? (store.object(forKey: "start-in-english") as? Bool) ?? ((snapshot()?.defaultLayout ?? store.string(forKey: "keyboard-layout")) == "english") }
        set { store.set(newValue, forKey: "start-in-english"); publish() }
    }
    static var defaultLayout: String {
        get { startInEnglish ? "english" : chineseLayout }
        set {
            store.set(newValue, forKey: "keyboard-layout")
            store.set(newValue == "english", forKey: "start-in-english")
            if newValue != "english" { store.set(newValue, forKey: "chinese-layout") }
            publish()
        }
    }
    static var expandedCandidates: Bool {
        get { snapshot()?.expandedCandidates ?? store.bool(forKey: "expanded-candidates") }
        set { store.set(newValue, forKey: "expanded-candidates"); publish() }
    }
    static var commonSymbols: [String] {
        get {
            let fallback = ["，", "。", "！", "？"]
            guard let values = snapshot()?.commonSymbols ?? store.stringArray(forKey: "common-symbols"), values.count == 4 else { return fallback }
            return values.enumerated().map { $0.element.isEmpty || $0.element.count > 4 ? fallback[$0.offset] : $0.element }
        }
        set { store.set(newValue, forKey: "common-symbols"); publish() }
    }
    static var keyPreview: Bool {
        get { snapshot()?.keyPreview ?? (store.object(forKey: "key-preview") as? Bool) ?? true }
        set { store.set(newValue, forKey: "key-preview"); publish() }
    }
    static var keyFeedback: String {
        get { snapshot()?.keyFeedback ?? store.string(forKey: "key-feedback") ?? "strong" }
        set { store.set(newValue, forKey: "key-feedback"); publish() }
    }
    static var compositionPosition: String {
        get { (snapshot()?.compositionPosition ?? store.string(forKey:"composition-position")) == "inline" ? "inline" : "keyboard" }
        set { store.set(newValue == "inline" ? "inline" : "keyboard",forKey:"composition-position");publish() }
    }
    static var systemLexicon:Bool {
        get { snapshot()?.systemLexicon ?? (store.object(forKey:"system-lexicon") as? Bool) ?? true }
        set { store.set(newValue,forKey:"system-lexicon");publish() }
    }
    static var mixedEnglish:Bool {
        get { snapshot()?.mixedEnglish ?? (store.object(forKey:"mixed-english") as? Bool) ?? true }
        set { store.set(newValue,forKey:"mixed-english");publish() }
    }
    static var keyboardHeightExtra: Double {
        get { KeyboardHeight.normalized(snapshot()?.keyboardHeightExtra ?? (store.object(forKey:"keyboard-height-extra") as? Double) ?? KeyboardHeight.defaultExtra) }
        set {
            store.set(KeyboardHeight.normalized(newValue), forKey:"keyboard-height-extra")
            store.set(UUID().uuidString, forKey:"keyboard-height-revision")
            publish()
        }
    }
    static var keyboardHeightRevision: String? { snapshot()?.keyboardHeightRevision ?? store.string(forKey:"keyboard-height-revision") }
}
