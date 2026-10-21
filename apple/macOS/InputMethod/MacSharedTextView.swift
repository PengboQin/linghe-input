import AppKit
import SwiftUI
import PrivateInputKit

struct MacSharedTextView: View {
    @ObservedObject var model: DeviceSyncModel
    @Binding var draft: String
    let openDevices: () -> Void
    @State private var selection: UUID?
    @State private var composing = false
    @State private var copied = false
    var body: some View {
        VStack(spacing: 0) {
            actions
            Divider()
            TimelineView(.periodic(from:.now,by:1)) { time in
                let now=UInt64(time.date.timeIntervalSince1970)
                let clips=model.info.clipboard ? Array(model.info.clips.filter{$0.expiresAt>now}.reversed()):[]
                Group {
                    if !model.info.configured {
                        empty("连接设备后接收和发送文本",action:"连接我的设备",perform:openDevices)
                    } else if !model.info.clipboard {
                        empty("共享文本已暂停",action:"开启共享文本") { model.consent(learning:model.info.learning,clipboard:true) }
                    } else if clips.isEmpty {
                        Text("尚未收到共享文本").foregroundStyle(.secondary).frame(maxWidth:.infinity,maxHeight:.infinity)
                    } else {
                        MacSettingsListDetail {
                            List(clips,selection:$selection) { clip in
                                VStack(alignment:.leading,spacing:4) {
                                    Text(verbatim:clip.text).lineLimit(2)
                                    Text(Date(timeIntervalSince1970:Double(clip.expiresAt)),format:.dateTime.hour().minute())
                                        .font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical,4).tag(clip.id)
                                    .accessibilityIdentifier("mac-shared-row-"+clip.id.uuidString)
                                    .contextMenu { Button("复制") { copy(clip.id) } }
                            }.listStyle(.inset)
                        } reader: {
                            ScrollView {
                                if let id=selection,let text=model.sharedText(id:id,now:now) {
                                    Text(verbatim:text).fixedSize(horizontal:false,vertical:true).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding()
                                        .accessibilityIdentifier("mac-shared-full-text")
                                } else { Text("选择一条文本").foregroundStyle(.secondary).padding() }
                            }.background(Color(nsColor:.textBackgroundColor))
                        }
                    }
                }
                .frame(maxWidth:.infinity,maxHeight:.infinity)
                .onAppear { reconcileSelection(with: clips.map(\.id)) }
                .onChange(of: clips.map(\.id)) { reconcileSelection(with: $0) }
                .onChange(of:selection) { _ in copied=false }
            }
        }
        .background(Color(nsColor:.windowBackgroundColor))
        .safeAreaInset(edge:.bottom,spacing:0) {
            if !model.status.isEmpty { Text(model.status).font(.callout).foregroundStyle(.secondary).padding(8).frame(maxWidth:.infinity,alignment:.leading) }
        }
        .sheet(isPresented:$composing) { MacSharedTextComposer(model:model,draft:$draft) }
        .task {
            await model.reload()
            while !Task.isCancelled {
                if NSApp.isActive { await model.synchronizeSharedText() }
                do { try await Task.sleep(nanoseconds:15_000_000_000) } catch { return }
            }
        }
    }
    private var actions: some View {
        HStack(spacing: 12) {
            Button { Task { await model.synchronizeSharedText() } } label: { Label("刷新",systemImage:"arrow.clockwise") }
                .disabled(model.busy || model.savingConsent || !model.info.configured).accessibilityIdentifier("mac-shared-refresh")
            Spacer()
            Button { if let id=selection { copy(id) } } label: { Label(copied ? "已复制":"复制",systemImage:copied ? "checkmark":"doc.on.doc") }
                .disabled(selection.flatMap{model.sharedText(id:$0)} == nil).accessibilityIdentifier("mac-shared-copy")
            Button { composing=true } label: { Label("发送文本",systemImage:"square.and.pencil") }
                .disabled(!model.info.configured || !model.info.clipboard || model.savingConsent).accessibilityIdentifier("mac-shared-compose")
        }.controlSize(.regular).padding(.horizontal,16).padding(.vertical,10)
    }
    private func reconcileSelection(with ids: [UUID]) {
        if selection.map({ !ids.contains($0) }) ?? true {
            selection = ids.first
        }
    }
    private func empty(_ title:String,action:String,perform:@escaping()->Void) -> some View {
        VStack(spacing:12) { Text(title).foregroundStyle(.secondary);Button(action,action:perform).disabled(model.savingConsent) }
            .frame(maxWidth:.infinity,maxHeight:.infinity)
    }
    private func copy(_ id:UUID) {
        copied=model.copySharedText(id:id)
    }
}

private struct MacSharedTextComposer: View {
    @ObservedObject var model: DeviceSyncModel
    @Binding var draft:String
    @Environment(\.dismiss) private var dismiss
    @State private var attempted=false
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("发送文本").font(.headline)
            TextEditor(text:$draft).font(.body).border(Color(nsColor:.separatorColor))
                .accessibilityIdentifier("mac-shared-draft")
            if draft.utf8.count>65536 { Text("文本超过64 KiB，请缩短后发送").foregroundStyle(.red) }
            if !model.info.clipboard { Text("共享文本已暂停").foregroundStyle(.secondary) }
            else if attempted && !model.status.isEmpty { Text(model.status).foregroundStyle(.secondary) }
            HStack {
                Button("粘贴文本") { draft=NSPasteboard.general.string(forType:.string) ?? "" }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("发送") {
                    let text=draft;attempted=true
                    Task { if await model.sendSharedText(text) { draft="";dismiss() } }
                }.keyboardShortcut(.defaultAction)
                    .disabled(draft.isEmpty || draft.utf8.count>65536 || model.busy || model.savingConsent || !model.info.clipboard)
                    .accessibilityIdentifier("mac-shared-send")
            }
        }.padding(20).frame(minWidth:450,minHeight:320)
    }
}
