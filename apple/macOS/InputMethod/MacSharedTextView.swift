import AppKit
import SwiftUI
import PrivateInputKit

/// Manual sending remains available in settings. Received copies are applied
/// silently to the system clipboard and have no frontmost history/list surface.
struct MacSharedTextView:View {
    @ObservedObject var model:DeviceSyncModel
    @Binding var draft:String
    let openDevices:()->Void
    @State private var composing=false
    var body:some View {
        VStack(spacing:16) {
            if !model.info.configured {Button("连接我的设备",action:openDevices)}
            else if !model.info.clipboard {Button("开启共享文本") {model.consent(learning:model.info.learning,clipboard:true)}.disabled(model.savingConsent)}
            else {Button("发送文本") {composing=true}.accessibilityIdentifier("mac-shared-compose")}
            Button("设备与同步",action:openDevices)
            if !model.status.isEmpty {Text(model.status).foregroundStyle(.secondary)}
        }
        .frame(maxWidth:.infinity,maxHeight:.infinity)
        .sheet(isPresented:$composing) {MacSharedTextComposer(model:model,draft:$draft)}
        .task {await model.reload()}
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
