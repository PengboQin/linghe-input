import SwiftUI
import PrivateInputKit
#if os(macOS)
import AppKit
#endif

struct InputSettingsView: View {
    @State private var layout = KeyboardPreferences.chineseLayout
    @State private var english = KeyboardPreferences.startInEnglish
    @State private var remember = KeyboardPreferences.rememberWords
    @State private var symbols = KeyboardPreferences.commonSymbols
    @State private var feedback = KeyboardPreferences.keyFeedback
    @State private var compositionPosition = KeyboardPreferences.compositionPosition
    @State private var mixedEnglish = KeyboardPreferences.mixedEnglish
    @State private var systemLexicon = KeyboardPreferences.systemLexicon
    @State private var autoPairSymbols = KeyboardPreferences.autoPairSymbols
    @State private var caretInsidePairs = KeyboardPreferences.caretInsidePairs
    #if os(iOS)
    @State private var appearanceTheme = KeyboardPreferences.appearanceTheme
    #endif
    #if os(macOS)
    @State private var candidateLayout=KeyboardPreferences.desktopCandidateLayout
    @State private var macSemantic=KeyboardPreferences.macSemanticEnabled
    @State private var capsLockSwitch=KeyboardPreferences.macCapsLockSwitchEnabled
    #endif
    var body: some View {
        Form {
            #if os(iOS)
            Section {

                Picker("中文布局", selection: Binding(get: { layout }, set: { layout = $0; KeyboardPreferences.chineseLayout = $0 })) {
                    Text("中文 · 九宫格").tag("nine")
                    Text("中文 · 26 键").tag("pinyin26")
                }
                Toggle("默认英文输入", isOn: Binding(get: { english }, set: { english = $0; KeyboardPreferences.startInEnglish = $0 }))
                Toggle("中英混输",isOn:Binding(get:{mixedEnglish},set:{mixedEnglish=$0;KeyboardPreferences.mixedEnglish=$0})).accessibilityIdentifier("mixed-english-setting")
                Toggle("系统补充词库",isOn:Binding(get:{systemLexicon},set:{systemLexicon=$0;KeyboardPreferences.systemLexicon=$0})).accessibilityIdentifier("system-lexicon-setting")
                Picker("拼音显示位置",selection:Binding(get:{compositionPosition},set:{compositionPosition=$0;KeyboardPreferences.compositionPosition=$0})) {
                    Text("键盘内").tag("keyboard")
                    Text("文本框内").tag("inline")
                }
                .accessibilityIdentifier("composition-position-setting")
                NavigationLink("键盘高度") { KeyboardHeightSettingsView() }.accessibilityIdentifier("open-keyboard-height")
                NavigationLink("常用符号") {
                    Form {
                        ForEach(0..<4, id: \.self) { index in
                            TextField("第 \(index + 1) 个符号", text: $symbols[index])
                                .onChange(of: symbols[index]) { _ in
                                    if symbols.allSatisfy({ !$0.isEmpty && $0.count <= 4 }) { KeyboardPreferences.commonSymbols = symbols }
                                }
                        }
                    }.navigationTitle("常用符号")
                }
            } header: { Text("键盘") } footer: {
                Text("允许完全访问后，键盘可使用主 App 的自定义设置。基础打字和本地记忆无需完全访问。")
            }
            #endif
            #if os(iOS)
            Section("外观") {
                Picker("明暗模式", selection: Binding(get: { appearanceTheme.mode }, set: { appearanceTheme.mode = $0; KeyboardPreferences.appearanceTheme = appearanceTheme })) {
                    ForEach(InputTheme.Mode.allCases) { Text($0.title).tag($0) }
                }.accessibilityIdentifier("ios-theme-mode").accessibilityValue(appearanceTheme.mode.title)
                Picker("主题色", selection: Binding(get: { appearanceTheme.accent }, set: { appearanceTheme.accent = $0; KeyboardPreferences.appearanceTheme = appearanceTheme })) {
                    ForEach(InputTheme.Accent.allCases) { accent in
                        Label { Text(accent.title) } icon: { Image(systemName: "circle.fill").foregroundStyle(Color(uiColor: accent.color.uiColor)) }.tag(accent)
                    }
                }.accessibilityIdentifier("ios-theme-accent").accessibilityValue(appearanceTheme.accent.title)
            }
            Section("按键反馈") {
                Picker("按键触感", selection: Binding(get: { feedback }, set: { feedback = $0; KeyboardPreferences.keyFeedback = $0 })) {
                    Text("关闭").tag("off")
                    Text("轻").tag("light")
                    Text("强").tag("strong")
                }
            }
            #endif
            #if os(macOS)
            Section("键盘") {
                Button("在系统设置中管理输入法") {
                    NSWorkspace.shared.open(URL(fileURLWithPath:"/System/Applications/System Settings.app"))
                }
                Toggle("默认英文输入",isOn:Binding(get:{english},set:{english=$0;KeyboardPreferences.startInEnglish=$0}))
                Toggle("Caps Lock 内部中英兼容",isOn:Binding(get:{capsLockSwitch},set:{capsLockSwitch=$0;KeyboardPreferences.macCapsLockSwitchEnabled=$0})).accessibilityIdentifier("mac-caps-lock-switch")
                Toggle("中英混输",isOn:Binding(get:{mixedEnglish},set:{mixedEnglish=$0;KeyboardPreferences.mixedEnglish=$0}))
            }
            MacAppearanceSettings()
            Section("候选显示") {
                Picker("收起时的候选数",selection:Binding(get:{candidateLayout.collapsedCount},set:{candidateLayout = .init(collapsedCount:$0,expandedColumns:candidateLayout.expandedColumns,expandedRows:candidateLayout.expandedRows);KeyboardPreferences.desktopCandidateLayout=candidateLayout})) {
                    ForEach(DesktopCandidateLayout.allowed,id:\.self) {Text("\($0) 个").tag($0)}
                }.accessibilityIdentifier("desktop-candidate-count")
                Picker("展开后的列数",selection:Binding(get:{candidateLayout.expandedColumns},set:{candidateLayout = .init(collapsedCount:candidateLayout.collapsedCount,expandedColumns:$0,expandedRows:candidateLayout.expandedRows);KeyboardPreferences.desktopCandidateLayout=candidateLayout})) {
                    ForEach(DesktopCandidateLayout.allowed,id:\.self) {Text("\($0) 列").tag($0)}
                }.accessibilityIdentifier("desktop-candidate-columns")
                Picker("展开后的行数",selection:Binding(get:{candidateLayout.expandedRows},set:{candidateLayout = .init(collapsedCount:candidateLayout.collapsedCount,expandedColumns:candidateLayout.expandedColumns,expandedRows:$0);KeyboardPreferences.desktopCandidateLayout=candidateLayout})) {
                    ForEach(DesktopCandidateLayout.allowed,id:\.self) {Text("\($0) 行").tag($0)}
                }.accessibilityIdentifier("desktop-candidate-rows")
            }
            Section("拼音纠错") {
                Toggle("本地 MacBERT 辅助排序",isOn:Binding(get:{macSemantic},set:{macSemantic=$0;KeyboardPreferences.macSemanticEnabled=$0}))
                Text("在本机结合附近文字辅助排序；上下文临时使用，不保存或上传。").font(.footnote).foregroundStyle(.secondary)
            }
            #endif
            Section("符号输入") {
                Toggle("自动补全成对符号", isOn: Binding(get: { autoPairSymbols }, set: { autoPairSymbols = $0; KeyboardPreferences.autoPairSymbols = $0 }))
                    .accessibilityIdentifier("symbol-auto-pair-setting")
                Toggle("配对后光标移入中间", isOn: Binding(get: { caretInsidePairs }, set: { caretInsidePairs = $0; KeyboardPreferences.caretInsidePairs = $0 }))
                    .accessibilityIdentifier("symbol-caret-inside-setting")
            }
            Section("输入记忆") {
                Toggle("学习常用词", isOn: Binding(get: { remember }, set: { remember = $0; KeyboardPreferences.rememberWords = $0 }))
                Text("离线记录选词习惯，常用词逐渐前移。关闭后暂停学习并使用基础词库，已有记忆保留。").font(.footnote).foregroundStyle(.secondary)
            }
            Section("词库") {
                #if os(iOS)
                NavigationLink("个人词库与快捷短语") { PersonalLexiconSettings() }.accessibilityIdentifier("open-personal-lexicon")
                #endif
                LabeledContent("拼音", value: "常用词 · 连续长句")
                LabeledContent("古诗文", value: "内置常见名句")
            }
        }
        #if os(iOS)
        .navigationTitle("输入设置")
        #else
        .formStyle(.grouped)
        #endif
    }
}

#if os(iOS)
private struct KeyboardHeightSettingsView: View {
    @State private var extra = KeyboardPreferences.keyboardHeightExtra
    private var binding: Binding<Double> {
        Binding(get: { extra }, set: { value in
            let next = KeyboardHeight.normalized(value)
            if next != extra { extra = next; KeyboardPreferences.keyboardHeightExtra = next }
        })
    }
    var body: some View {
        Form {
            Section {
                Picker("高度", selection: binding) {
                    ForEach(KeyboardHeight.presets, id: \.extra) { preset in Text(preset.title).tag(preset.extra) }
                    if !KeyboardHeight.presets.contains(where: { $0.extra == extra }) { Text("自定").tag(extra) }
                }.pickerStyle(.segmented).accessibilityIdentifier("keyboard-height-presets")
                HStack {
                    Text("微调")
                    Spacer()
                    Text("+\(Int(extra))").foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: binding, in: 0...96, step: 4)
                    .accessibilityLabel("键盘高度微调").accessibilityIdentifier("main-keyboard-height-slider")
            } footer: { Text("设置对所有键盘布局生效。") }
        }.navigationTitle("键盘高度")
    }
}
#endif

struct InputHelpView: View {
    var body: some View {
        Form {
            Section("键盘操作") {
                #if os(iOS)
                Text("中文九宫格：连续点击拼音对应的字母组，再点选候选。空格选首个候选；分词键可分隔拼音。")
                Text("中英文键切换输入语言；英文使用 26 键。中文九宫格或 26 键在设置中选择。数字和符号使用独立页面，清空键仅清除待选内容。")
                Text("开启中英混输后，中文模式可点选英文单词或常用缩写。26 键支持英文补全；九键支持部分常用英文的完整按键编码。")
                #else
                Text("直接输入拼音，左右键移动候选高亮，空格确认；数字键选择当前行对应候选。上下键在原位置展开网格并逐行移动，可滚动查看更多。")
                Text("Shift＋左右键移动拼音光标；Escape 先收起网格，再按清空待选。Page Up / Page Down 移动一屏，退格修改拼音。")
                #endif
            }
            Section("候选位置") {
                #if os(iOS)
                Text("拼音显示位置可在输入设置中选择键盘内或文本框内。候选词保留在键盘顶部，点下拉箭头可展开滚动列表；整轮选字完成后自动返回键盘。")
                Text("文本框内的拼音属于待选内容，选词后替换为文字；显示支持取决于当前 App，可随时切回键盘内。")
                #else
                Text("候选窗跟随文本光标，键盘输入使用系统 InputMethodKit。Escape 清除待选内容，保留已输入正文。")
                #endif
            }
            Section("隐私与权限") {
                #if os(iOS)
                Text("基础输入和本地记忆离线可用。主 App 自定义设置与设备共享需键盘完全访问；设备同步与共享文本分别开启。活动归档默认关闭，需另行明确启用；启用后将所选来源的完整原文上传到你选择的明文服务器，输入过程需另行开启。")
                #else
                Text("添加输入法：系统设置 → 键盘 → 文本输入 → 编辑 → ＋ → 中文（简体）→ 灵鹤输入法。")
                Text("正常打字和附近文字分析使用系统输入法接口，无需开启输入监控或辅助功能。设备同步与共享文本分别开启。")
                #endif
            }
        }
        #if os(iOS)
        .navigationTitle("使用帮助")
        #else
        .formStyle(.grouped)
        #endif
    }
}

#if os(iOS)
@available(iOSApplicationExtension,unavailable)
struct KeyboardPermissionHelpView:View {
    var body:some View {
        Form {
            Section("开启方法") {
                Text("设置 → 通用 → 键盘 → 键盘 → 灵鹤输入法 → 允许完全访问")
                Button("打开系统设置") {
                    if let url=URL(string:UIApplication.openSettingsURLString) {UIApplication.shared.open(url)}
                }.accessibilityIdentifier("permission-open-settings")
            }
            Section("开启后可用") {
                Label("主 App 与键盘共享设置和词库",systemImage:"keyboard")
                Label("在键盘插入已接收的共享文本",systemImage:"doc.on.clipboard")
                Text("同步和共享文本仍由你分别开启。权限不会自动发送输入内容。").font(.footnote).foregroundStyle(.secondary)
            }
            Section("基础输入") {
                Text("不开放完全访问也可使用拼音、英文和本地词库。附近文字由当前 App 提供，完全访问不会让输入法读取任意 App 或完整输入框。")
            }
            Section("检查当前状态") {
                Text("回到试打框，选择灵鹤输入法，长按“中/英”键打开设置菜单，即可查看当前的完全访问状态。")
                Text("允许完全访问需要你在系统设置中确认，App 无法代为开启。").font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("键盘权限")
    }
}
#endif
