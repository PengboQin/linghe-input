2026-10-22 Windows 0.5.6-win1 预览：修复长组合候选框因宽度增长向屏幕左侧偏移，以及缺少光标坐标时错误跳到窗口左上方。实体机隔离定位专项已通过，安装后系统输入链路和日用体验仍待验证；完整卸载与系统语言设置列表集成继续完善。输入过程诊断仍独立授权、默认关闭。下载本轮 [Windows 定位修复预览](https://github.com/PengboQin/linghe-input/releases/tag/v0.2026.10.22-win056-preview.1)，或从下方发行列表选择需要的版本；各安装包只对应其标签和源码附件。此轮不更新其他平台的安装包。

# 灵鹤输入法 · Linghe Input

面向 iOS、macOS、Android 和 Windows 的拼音输入法源码存档。支持九键/全键拼音、个人词库、候选学习、可选自建同步、持续可见时的快速剪贴板与输入归档。英文、纠错和候选行为按各平台实现逐步对齐。

下载见 [预发布与源码附件](https://github.com/PengboQin/linghe-input/releases)。网页代码树用于浏览；构建请取对应发行的完整产品源码 ZIP，以及 `SOURCE-ATTACHMENTS-INDEX.json` 列出的依赖源码。大型公开数据和二进制图标未放入轻量代码树，逐项路径与散列见 `FULL-SOURCE-RESTORE.json`，完整产品源码 ZIP 保留这些文件。

**此处是经过明确允许清单导出的源码快照，不是原开发工作区，也不是已验证的完全可复现发行版。** 对应源码散列见 `PUBLIC-SOURCE-MANIFEST.json`。安装包与验证状态由具体发行说明分别列出；源码存在不代表该平台已安装、签名、公证或通过体验验收。

- Apple/Android 与主内核：`apple/`、`android/`、`core/`、`shared/`。
- Windows 原生前端与独立构建：`windows-source/`。四端唯一输入内核在根目录 `core/`；Windows 的 `core/` 仅为兼容转发文件，不维护第二份算法。协议的原生适配仍有平台差异，见 `windows-source/SHARED-VERSIONS.json`。
- 自建服务：`server/`，请先读 [SELF-HOSTING.md](SELF-HOSTING.md)。发行源码默认没有运营服务器地址；由用户设置或设备邀请取得。
- 构建与缺口：[BUILDING.md](BUILDING.md)；离线模型：[MODELS.md](MODELS.md)。

本项目原创代码采用 [GPL-3.0-only](LICENSE)。对外分发修改版时按许可证提供对应源码；第三方组件和数据保留各自许可证，详见 [LICENSE-NOTICE.md](LICENSE-NOTICE.md)。

本存档不含个人输入记录、剪贴板、设备身份、设备组、证书、开发签名文件或模型大权重。可选归档服务会按授权保存明文，不能将其称为端到端加密；词库/共享文本同步的密文通道与归档服务是不同功能。

输入过程诊断为独立、默认关闭的可选归档来源，开启后也会保存未选中、未发送的输入。仅观察本输入法处理的事件；不安装全局键盘钩子。服务器保存所选来源的明文，权限与事件格式见 [诊断与设备元数据](docs/INPUT-DIAGNOSTICS-V1-20261021.md)。
