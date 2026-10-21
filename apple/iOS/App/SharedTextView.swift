import SwiftUI
import PrivateInputKit

struct SharedTextEntryView: View {
    @StateObject private var model = DeviceSyncModel.shared
    var body: some View { SharedTextInboxView(model:model) }
}

struct SharedTextInboxView: View {
    @ObservedObject var model: DeviceSyncModel
    @State private var draft = ""
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        TimelineView(.periodic(from:.now,by:1)) { timeline in
            let clips = model.info.clips.filter { $0.expiresAt > UInt64(timeline.date.timeIntervalSince1970) }.reversed()
            List {
                if !model.info.configured {
                    Section {
                        Text("连接设备后接收和发送文本").foregroundStyle(.secondary)
                        NavigationLink("连接我的设备") { DeviceSyncView(model:model,showsSharedTextLink:false) }.accessibilityIdentifier("shared-text-connect-devices")
                    }
                } else if !model.info.clipboard {
                    Section {
                        Label("共享文本已暂停",systemImage:"pause.circle").foregroundStyle(.secondary)
                        Button("开启共享文本") { model.consent(learning:model.info.learning,clipboard:true) }
                            .disabled(model.savingConsent).accessibilityIdentifier("shared-text-enable")
                    }
                } else if clips.isEmpty {
                    Section { Text("尚未收到共享文本").foregroundStyle(.secondary).accessibilityIdentifier("shared-inbox-empty") }
                } else {
                    ForEach(Array(clips)) { clip in
                        NavigationLink {
                            SharedTextReadingView(clip:clip,model:model)
                        } label: {
                            VStack(alignment:.leading,spacing:4) {
                                Text(verbatim:clip.text).lineLimit(2).font(.body)
                                Text("有效至 \(Date(timeIntervalSince1970:Double(clip.expiresAt)),format:.dateTime.hour().minute())")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical,2)
                        }
                        .accessibilityIdentifier("shared-inbox-"+clip.id.uuidString)
                        .contextMenu {
                            Button { copy(clip) } label: { Label("复制",systemImage:"doc.on.doc") }
                        }
                        .swipeActions(edge:.trailing,allowsFullSwipe:false) {
                            Button { copy(clip) } label: { Label("复制",systemImage:"doc.on.doc") }.tint(.accentColor)
                        }
                    }
                }
                if !model.status.isEmpty {
                    Section {
                        Text(model.status).foregroundStyle(.secondary).accessibilityIdentifier("shared-inbox-status")
                        if model.info.configured && model.info.clipboard {
                            Button("重试") { Task { await model.synchronizeSharedText() } }.disabled(model.busy)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay { if model.busy && model.info.clips.isEmpty { ProgressView().accessibilityLabel("正在读取共享文本") } }
        }
        .navigationTitle("共享文本").navigationBarTitleDisplayMode(.inline)
        .background(Color(uiColor:.systemBackground))
        .toolbar {
            ToolbarItem(placement:.topBarTrailing) {
                if model.info.configured && model.info.clipboard {
                    NavigationLink {
                        SharedTextComposeView(model:model,draft:$draft)
                    } label: { Label("发送文本",systemImage:"square.and.pencil") }
                        .accessibilityIdentifier("compose-shared-text")
                }
            }.sharedTextButtonSurface()
            ToolbarItem(placement:.topBarTrailing) {
                if model.info.configured {
                    NavigationLink { DeviceSyncView(model:model,showsSharedTextLink:false) } label: {
                        Label("设备与同步",systemImage:"gearshape")
                    }.accessibilityIdentifier("shared-text-settings")
                }
            }.sharedTextButtonSurface()
        }
        .refreshable { await model.synchronizeSharedText() }
        .task(id:scenePhase) {
            guard scenePhase == .active else { return }
            await model.reload()
            if model.info.configured && model.info.clipboard { await model.synchronizeSharedText() }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds:15_000_000_000) } catch { return }
                if model.info.configured && model.info.clipboard { await model.synchronizeSharedText() }
                else { await model.reload() }
            }
        }
    }
    private func copy(_ clip:ReceivedClipboard) {
        if !model.copySharedText(id:clip.id) {model.refresh()}
    }
}

private struct SharedTextReadingView: View {
    let clip: ReceivedClipboard
    @ObservedObject var model: DeviceSyncModel
    @State private var copied=false
    var body: some View {
        TimelineView(.periodic(from:.now,by:1)) { timeline in
            let currentText=model.sharedText(id:clip.id,now:UInt64(timeline.date.timeIntervalSince1970))
            let valid=currentText != nil
            ScrollView {
                if let currentText {
                    Text(verbatim:currentText).fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled).padding()
                        .accessibilityIdentifier("shared-inbox-full-text")
                } else {
                    Text(model.info.clipboard ? "共享文本已过期":"共享文本已暂停").foregroundStyle(.secondary).padding()
                }
            }
            .toolbar {
                ToolbarItem(placement:.topBarTrailing) {
                    Button {
                        copied=model.copySharedText(id:clip.id)
                    } label: { Label(copied ? "已复制":"复制",systemImage:copied ? "checkmark":"doc.on.doc") }
                        .disabled(!valid).accessibilityIdentifier("copy-shared-text")
                }
            }
        }
        .navigationTitle("全文").navigationBarTitleDisplayMode(.inline)
        .background(Color(uiColor:.systemBackground))
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
