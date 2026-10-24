import SwiftUI
import PrivateInputKit

struct DeviceMemberSections:View {
    @ObservedObject var model:DeviceSyncModel
    @State private var removing:GroupDeviceStatus?
    @State private var idleDays="30"
    private var own:GroupDeviceStatus? {model.info.devices.first{$0.isSelf}}
    private func removable(_ device:GroupDeviceStatus) -> Bool {
        guard model.info.canManage,!device.isSelf,!device.inactive else {return false}
        #if os(iOS)
        return device.kind=="macos" || device.kind=="windows"
        #else
        return true
        #endif
    }
    var body:some View {
        Section("在组设备") {
            ForEach(model.info.devices) {device in
                HStack {
                    Image(systemName:device.mobile ? "iphone":"desktopcomputer").frame(width:24)
                    VStack(alignment:.leading,spacing:3) {
                        Text(device.displayName+(device.isSelf ? " · 本机":""))
                        if device.inactive {Text("已离线过期，等待清理").foregroundStyle(.secondary)}
                        else if device.lastSeen>0 {Text(Date(timeIntervalSince1970:Double(device.lastSeen)),style:.relative).font(.caption).foregroundStyle(.secondary)}
                        else {Text("等待设备更新连接信息").font(.caption).foregroundStyle(.secondary)}
                    }
                    Spacer()
                    if removable(device) {Button("移除",role:.destructive){removing=device}.disabled(model.busy)}
                }
            }
            if model.info.devices.isEmpty {Text("正在读取设备列表…").foregroundStyle(.secondary)}
        }
        #if os(iOS)
        if let own {
            Section("闲置自动离组") {
                HStack {Text("未连接天数");Spacer();TextField("1–90",text:$idleDays).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width:65);Text("天")}
                Button("保存期限") {if let days=Int(idleDays) {model.run {try await $0.setIdleDays(days)}}}.disabled(model.busy || !(1...90).contains(Int(idleDays) ?? 0))
                Text("默认 30 天，最长 90 天。离组后清除本机个人词库和共享资料。").font(.footnote).foregroundStyle(.secondary)
            }.onAppear {idleDays=String(own.idleDays)}
        }
        #endif
        EmptyView().confirmationDialog("移除此设备？",isPresented:Binding(get:{removing != nil},set:{if !$0 {removing=nil}}),titleVisibility:.visible) {
            if let device=removing {Button("移除并清除该设备的个人资料",role:.destructive){model.run {try await $0.removeDevice(device.device)};removing=nil}}
            Button("取消",role:.cancel){removing=nil}
        } message: {Text("设备联网获知离组后会清除本机词库、学习记录和共享资料。完全离线时不能立即执行远程清除。")}
    }
}

struct PairingWaitSection:View {
    @ObservedObject var model:DeviceSyncModel
    var body:some View {
        Section {
            if model.info.joiningExpired {
                Text("连接已超时").font(.headline)
                Text("请在发出邀请的设备重新生成接入码，再扫码或输入新码。").foregroundStyle(.secondary)
                Button("重新接入"){model.run {try await $0.cancelJoining()}}
            } else {
                Text("等待邀请设备完成连接").font(.headline)
                Text("只需发出邀请的设备在线，其他设备可以离线。").foregroundStyle(.secondary)
                Text("本次请求截止 "+Date(timeIntervalSince1970:Double(model.info.joiningExpiresAt)).formatted(date:.omitted,time:.shortened)).font(.caption).foregroundStyle(.secondary)
                Button("立即重试"){model.run {try await $0.pollPairing()}}
                Button("取消连接",role:.cancel){model.run {try await $0.cancelJoining()}}
            }
        }
    }
}
