import SwiftUI

struct AppLegalView: View {
    var body: some View {
        Form {
            Section("隐私") {
                Text("基础拼音、英文、候选排序和纠错在设备上处理。完全访问用于主 App 与键盘共享设置和词库；联网功能需要分别开启。")
                Link("隐私政策", destination: URL(string: "https://support.example.invalid/apps/linghe-input/privacy/")!)
                    .accessibilityIdentifier("privacy-policy-link")
            }
            Section("使用支持") {
                Link("帮助与联系开发者", destination: URL(string: "https://support.example.invalid/apps/linghe-input/support/")!)
                Text("设备同步与共享文本分别开启，需要你配置 HTTPS 同步服务。基础打字不需要联网或注册账号。")
            }
            Section("可选云词频") {
                Text("默认关闭。设备组和本机开启后，已选词条的拼音、累计计数及置顶、删除等管理记录会发送到所设服务器，由组内共享优化。服务器以明文处理这些词条，管理员能够读取；这与输入正文、剪贴板归档的开关分开。")
                Text("最终候选仍在本机匹配；云端只定期整理词频。离线时保留本地学习，关闭后立即停用云排序并在联网后撤销授权。")
            }
            Section("可选活动归档") {
                Text("默认关闭。设备组和本设备分别开启后，所选输入法输出、明确粘贴及系统实际允许读取的剪贴板文字，会完整上传到你设置的归档服务器，以明文保存，服务器管理员能够读取。归档可暂停，与加密词库和共享文本同步分开。")
                Text("上屏记录不代表消息已发送，剪贴板观察不代表已粘贴；系统权限和后台限制可能造成缺口。离组清理本机记录，服务器原有档案另按保留和删除规则处理。")
            }
            Section("开源组件") {
                NavigationLink("第三方许可与词库来源") { NoticesView() }
                    .accessibilityIdentifier("open-third-party-notices")
                Text("输入内核、词库与本地语义模型的来源及许可证随应用提供。")
            }
        }.navigationTitle("隐私与开源许可")
    }
}

private struct NoticesView: View {
    private let notices = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "许可文件暂时无法读取，请通过使用支持联系开发者。"
    var body: some View {
        ScrollView { Text(notices).font(.footnote).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
            .navigationTitle("开源许可").navigationBarTitleDisplayMode(.inline)
    }
}
