import SwiftUI
import PrivateInputKit

struct LearnedVocabularySettings: View {
    @State private var entries: [LearningEntry] = []
    @State private var query = ""
    @State private var loading = false
    @State private var error: String?
    @State private var requestID = UUID()
    @State private var snapshotPublished = false
    @State private var resetObserver: UUID?

    private var visible: [LearningEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return entries }
        return entries.filter {
            $0.text.localizedCaseInsensitiveContains(needle)
                || $0.reading.localizedCaseInsensitiveContains(needle)
        }
    }

    var body: some View {
        List {
            Section {
                if loading { ProgressView("正在读取…").accessibilityIdentifier("learned-vocabulary-loading") }
                if let error {
                    Text(error).foregroundStyle(.secondary).accessibilityIdentifier("learned-vocabulary-error")
                }
                if !loading && error == nil && visible.isEmpty {
                    Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? (snapshotPublished ? "暂无已保存的学习记录。" : "共享区还没有学习记录。请确认键盘已允许完全访问，并在键盘保存后刷新。")
                         : "没有匹配的词汇。")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("learned-vocabulary-empty")
                }
                ForEach(visible) { entry in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.text).fixedSize(horizontal: false, vertical: true)
                            Text(entry.reading).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("\(entry.frequency) 次").font(.caption).foregroundStyle(.secondary)
                            if entry.pinned { Text("置顶").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("learned-vocabulary-row")
                }
            } header: {
                Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "已保存的学习记录 · \(entries.count) 条" : "匹配 · \(visible.count) 条")
            } footer: {
                Text("显示键盘已保存到共享区的学习记录；刚学到的词可先收起键盘再刷新。")
            }
        }
        .navigationTitle("已学习词汇")
        .searchable(text: $query, prompt: "词语或拼音")
        .toolbar { Button("刷新", action: reload).disabled(loading) }
        .onAppear {
            if resetObserver == nil {
                resetObserver = PersonalDataReset.observe {
                    entries = []
                    snapshotPublished = false
                    error = "个人资料已重置，请重新打开。"
                }
            }
            reload()
        }
        .onDisappear {
            if let resetObserver { PersonalDataReset.unobserve(resetObserver) }
            resetObserver = nil
            requestID = UUID()
            loading = false
        }
        .accessibilityIdentifier("learned-vocabulary-list")
    }

    private func reload() {
        guard !loading else { return }
        let request = UUID(); requestID = request
        loading = true; error = nil; entries = []
        let directory = LocalLearningCoordinator.sharedDirectory()
        DispatchQueue.global(qos: .utility).async {
            let result: Result<LearnedVocabularyReadResult, Error> = Result {
                guard let directory else { throw InputDataError.invalidRecord }
                return try LearnedVocabularyReader.read(directory: directory)
            }
            DispatchQueue.main.async {
                guard requestID == request else { return }
                loading = false
                switch result {
                case .success(let value):
                    do { try value.requireCurrent() }
                    catch {
                        entries = []
                        snapshotPublished = false
                        self.error = "个人资料已重置，请重新打开。"
                        return
                    }
                    entries = value.rows
                    snapshotPublished = value.published
                case .failure:
                    entries = []
                    snapshotPublished = false
                    self.error = "暂时无法读取学习记录，请稍后刷新。原资料未修改。"
                }
            }
        }
    }
}
