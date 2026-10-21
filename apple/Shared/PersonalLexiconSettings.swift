import SwiftUI
import UniformTypeIdentifiers
import PrivateInputKit


private struct PersonalLexiconDocument:FileDocument {
    static var readableContentTypes:[UTType] { [.json] }
    var data:Data
    init(data:Data) { self.data=data }
    init(configuration:ReadConfiguration) throws { data=configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration:WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents:data) }
}

struct PersonalLexiconSettings:View {
    @State private var lexicon=PersonalLexicon()
    @State private var loaded=false
    @State private var query=""
    @State private var editor:PersonalLexicon.Entry?
    @State private var message:String?
    @State private var importing=false
    @State private var exporting=false
    @State private var exportDocument:PersonalLexiconDocument?
    private var store:PersonalLexiconStore? { PersonalLexiconLocation.directory.map(PersonalLexiconStore.init) }
    private var visible:[PersonalLexicon.Entry] {
        lexicon.entries.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) || $0.trigger.localizedCaseInsensitiveContains(query) }
    }
    var body:some View {
        List {
            ForEach([PersonalLexicon.Kind.word,.phrase],id:\.rawValue) { kind in
                Section(kind == .word ? "个人词库":"快捷短语") {
                    let entries=visible.filter{$0.kind==kind}
                    if entries.isEmpty { Text(query.isEmpty ? "暂无内容":"没有匹配项").foregroundStyle(.secondary) }
                    ForEach(entries) { entry in
                        Button { editor=entry } label: {
                            VStack(alignment:.leading,spacing:4) {
                                Text(entry.text).foregroundStyle(.primary).lineLimit(2)
                                Text(entry.trigger).font(.caption).foregroundStyle(.secondary)
                            }
                        }.accessibilityIdentifier("personal-entry-"+entry.trigger)
                    #if os(macOS)
                        .contextMenu {
                            Button("删除",role:.destructive) { var next=lexicon;next.remove(id:entry.id);save(next) }
                        }
                    #endif
                    }.onDelete { offsets in
                        var next=lexicon
                        for i in offsets { next.remove(id:entries[i].id) }
                        save(next)
                    }
                    Button(kind == .word ? "添加词条":"添加短语") { editor = .init(kind:kind,text:"",trigger:"") }
                        .accessibilityIdentifier(kind == .word ? "add-personal-word":"add-personal-phrase").disabled(!loaded)
                }
            }
            Section {
                Button("导入…") { importing=true }.disabled(!loaded)
                Button("导出…") {
                    do {
                        var publicCopy=PersonalLexicon()
                        for entry in lexicon.entries { try publicCopy.upsert(entry) }
                        exportDocument = .init(data:try JSONEncoder().encode(publicCopy));exporting=true
                    }
                    catch { message="导出失败，请重试。" }
                }.disabled(!loaded || lexicon.entries.isEmpty)
            } footer: { Text("导入会合并，不覆盖已有内容。短语内容包含在导出文件中，请妥善保管。") }
        }
        #if os(iOS)
        .navigationTitle("个人词库与短语")
        #endif
        .searchable(text:$query,prompt:"搜索词条、拼音或缩写")
        .onAppear(perform:load)
        .onReceive(NotificationCenter.default.publisher(for:.init("PrivateInputPersonalLexiconChanged")).receive(on:RunLoop.main)) { _ in load() }
        .sheet(item:$editor) { entry in
            PersonalEntryEditor(entry:entry) { changed in
                var next=lexicon
                let syllables=PersonalLexiconLocation.syllables
                guard changed.kind != .word || !syllables.isEmpty else { throw InputDataError.invalidRecord }
                try next.upsert(changed,syllables:syllables)
                guard save(next) else { throw InputDataError.invalidRecord }
            }
        }
        .fileImporter(isPresented:$importing,allowedContentTypes:[.json]) { result in
            do {
                let url=try result.get(),access=url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard (try url.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? 0 <= PersonalLexicon.maximumBytes else { throw InputDataError.oversized }
                let incoming=try PersonalLexiconStore.decode(Data(contentsOf:url)),syllables=PersonalLexiconLocation.syllables
                guard !syllables.isEmpty else { throw InputDataError.invalidRecord }
                var next=lexicon;try next.merge(incoming,syllables:syllables);save(next)
            } catch CocoaError.userCancelled { }
            catch { message="无法导入。请使用本输入法导出的词库文件，并检查格式与容量。" }
        }
        .fileExporter(isPresented:$exporting,document:exportDocument,contentType:.json,defaultFilename:"个人词库与短语") { result in
            if case .failure(let error)=result,(error as NSError).code != NSUserCancelledError { message="导出失败，请重试。" }
        }
        .alert("个人词库",isPresented:Binding(get:{message != nil},set:{if !$0 { message=nil }})) { Button("好",role:.cancel) { message=nil } } message: { Text(message ?? "") }
    }
    private func load() {
        do { guard let store else { throw InputDataError.invalidRecord };lexicon=try store.load();loaded=true }
        catch { loaded=false;message="暂时无法读取词库，原文件已保留。请稍后重试。" }
    }
    @discardableResult private func save(_ value:PersonalLexicon) -> Bool {
        do { guard loaded,let store else { throw InputDataError.invalidRecord };lexicon=try store.applying(observed:lexicon,edited:value);return true }
        catch { message="保存失败，已有词库保留。";return false }
    }
}

private struct PersonalEntryEditor:View {
    @Environment(\.dismiss) private var dismiss
    @State var entry:PersonalLexicon.Entry
    let save:(PersonalLexicon.Entry)throws->Void
    @State private var error:String?
    private var title:String { entry.kind == .word ? "词条":"快捷短语" }
    private var empty:Bool { entry.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || entry.trigger.isEmpty }
    private func commit() {
        do { try save(entry);dismiss() }
        catch { self.error="请检查内容和拼音或缩写；相同内容无需重复添加。" }
    }
    var body:some View {
        #if os(macOS)
        VStack(alignment:.leading,spacing:16) {
            Text(title).font(.headline)
            Grid(alignment:.leading,horizontalSpacing:12,verticalSpacing:12) {
                GridRow {
                    Text(entry.kind == .word ? "词语":"内容").gridColumnAlignment(.trailing)
                    TextField("",text:$entry.text,axis:.vertical).lineLimit(2...6).textFieldStyle(.roundedBorder)
                        .accessibilityLabel(entry.kind == .word ? "词语":"短语内容").accessibilityIdentifier("personal-text")
                }
                GridRow {
                    Text(entry.kind == .word ? "拼音":"缩写")
                    TextField("",text:$entry.trigger,prompt:Text(entry.kind == .word ? "如 ming tian":"如 dz"))
                        .textFieldStyle(.roundedBorder).accessibilityLabel(entry.kind == .word ? "拼音":"缩写").accessibilityIdentifier("personal-trigger")
                }
            }
            Text(entry.kind == .word ? "每个音节用空格分隔，ü 用 v。输入完整拼音后选择词条。":"使用 2–16 个英文字母。输入缩写后用空格、数字或候选栏选择短语。")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存",action:commit).keyboardShortcut(.defaultAction).disabled(empty).accessibilityIdentifier("save-personal-entry")
            }
        }.padding(20).frame(width:460)
        #else
        NavigationStack {
            Form {
                Section {
                    TextField(entry.kind == .word ? "词语":"短语内容",text:$entry.text,axis:.vertical).lineLimit(2...6).accessibilityIdentifier("personal-text")
                    TextField(entry.kind == .word ? "拼音，如 ming tian":"字母缩写，如 dz",text:$entry.trigger).accessibilityIdentifier("personal-trigger")
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.asciiCapable)
                } footer: {
                    Text(entry.kind == .word ? "每个音节用空格分隔，ü 用 v。按完整拼音输入后点选词条。":"使用 2–16 个英文字母。中文 26 键输入缩写，九键输入对应数字后点选短语。")
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement:.confirmationAction) { Button("保存",action:commit).disabled(empty).accessibilityIdentifier("save-personal-entry") }
            }
        }
        #endif
    }
}
