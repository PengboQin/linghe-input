import SwiftUI
import PrivateInputKit

struct SharedTextEntryView: View {
    @StateObject private var model = DeviceSyncModel.shared
    var body: some View { SharedTextInboxView(model:model) }
}

/// Explicit one-shot sending, without a received-copy/history browser.
struct SharedTextInboxView:View {
    @ObservedObject var model:DeviceSyncModel
    @State private var draft=""
    var body:some View {
        Form {
            if !model.info.configured {
                Section {NavigationLink("连接我的设备") {DeviceSyncView(model:model,showsSharedTextLink:false)}}
            } else if !model.info.clipboard {
                Section {Button("开启共享文本") {model.consent(learning:model.info.learning,clipboard:true)}.disabled(model.savingConsent)}
            } else {
                Section {NavigationLink("发送文本") {SharedTextComposeView(model:model,draft:$draft)}.accessibilityIdentifier("compose-shared-text")}
            }
            Section {NavigationLink("设备与同步") {DeviceSyncView(model:model,showsSharedTextLink:false)}}
            if !model.status.isEmpty {Section {Text(model.status).foregroundStyle(.secondary)}}
        }
        .navigationTitle("共享文本").navigationBarTitleDisplayMode(.inline)
        .task {await model.reload()}
    }
}

private struct SharedTextComposeView: View {
    @ObservedObject var model: DeviceSyncModel
    @Binding var draft: String
    @FocusState private var focused: Bool
    @State private var attempted=false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing:0) {
            TextEditor(text:$draft).focused($focused).font(.body)
                .scrollContentBackground(.hidden).padding(.horizontal,12)
                .accessibilityIdentifier("sync-outgoing")
            if draft.utf8.count > 65536 {
                Text("文本超过64 KiB，请缩短后发送").font(.footnote).foregroundStyle(.red).padding(.horizontal)
            }
            if !model.info.clipboard {
                Text("共享文本已暂停").foregroundStyle(.secondary).padding()
            } else if attempted && !model.status.isEmpty {
                Text(model.status).font(.footnote).foregroundStyle(.secondary).padding()
                    .accessibilityIdentifier("shared-send-status")
            }
        }
        .navigationTitle("发送文本").navigationBarTitleDisplayMode(.inline)
        .background(Color(uiColor:.systemBackground))
        .toolbar {
            ToolbarItem(placement:.topBarTrailing) {
                Button("发送") {
                    let text=draft;attempted=true;focused=false
                    Task {
                        if await model.sendSharedText(text) { draft="";dismiss() }
                    }
                }.disabled(draft.isEmpty || draft.utf8.count>65536 || model.busy || model.savingConsent || !model.info.clipboard)
                    .accessibilityIdentifier("sync-send")
            }
            ToolbarItem(placement:.bottomBar) {
                PasteButton(payloadType:String.self) { draft=$0.first ?? "" }
            }
        }
    }
}

private extension ToolbarContent {
    @ToolbarContentBuilder
    func sharedTextButtonSurface() -> some ToolbarContent {
        if #available(iOS 26.0, *) { self.sharedBackgroundVisibility(.hidden) }
        else { self }
    }
}
