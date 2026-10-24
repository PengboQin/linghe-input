import SwiftUI
import CoreImage.CIFilterBuiltins

struct DeviceInvitationView:View {
    @ObservedObject var model:DeviceSyncModel
    @Environment(\.dismiss) private var dismiss
    private var qr:CGImage? {
        guard let link=model.info.quickInvitation else { return nil }
        let filter=CIFilter.qrCodeGenerator();filter.message=Data(link.absoluteString.utf8);filter.correctionLevel="M"
        guard let image=filter.outputImage else { return nil }
        return CIContext().createCGImage(image,from:image.extent)
    }
    var body:some View {
        VStack(spacing:18) {
            Text("接入新设备").font(.headline)
            if let ticket=model.info.ticket {
                TimelineView(.periodic(from:.now,by:1)) { context in
                    let remaining=max(0,Int(ticket.expiresAt)-Int(context.date.timeIntervalSince1970))
                    if remaining>0 {
                        if let qr { Image(decorative:qr,scale:1).interpolation(.none).resizable().scaledToFit().padding(18).background(.white).frame(width:270,height:270).accessibilityLabel("接入二维码") }
                        Text(ticket.code).font(.largeTitle.monospacedDigit()).textSelection(.enabled).accessibilityIdentifier("quick-pair-code")
                        Text("\(remaining/60):\(String(format:"%02d",remaining%60)) 后失效 · 仅限一台设备").font(.footnote).foregroundStyle(.secondary)
                    } else { Text("接入码已失效").foregroundStyle(.secondary) }
                }
                Text("在新设备的 App 内扫码，或输入六位接入码").font(.callout).foregroundStyle(.secondary)
            } else if model.busy {ProgressView("生成接入码…")} else {Text("尚无可用接入码").foregroundStyle(.secondary)}
            HStack {
                Button("重新生成") {model.run {try await $0.makeQuickInvitation()}}.disabled(model.busy || !model.info.canManage)
                Button("取消邀请",role:.cancel) {model.run {try await $0.closeQuickInvitation()};dismiss()}
                Button("完成") {dismiss()}
            }
            if !model.status.isEmpty {Text(model.status).font(.footnote).foregroundStyle(.secondary)}
        }.padding(24).frame(minHeight:440)
        #if os(macOS)
        .frame(minWidth:360)
        #endif
        // Closing a view/window does not revoke a still-live invitation.
        // The explicit cancel action, replacement, and deadline revoke it.
    }
}
