# 2026-11-03 开发预览：九键上屏稳定、词记忆提示条移除、标准安装器

本次：Android77 / macOS97 / Windows 0.7.6 标准安装器 / 源码（含 iOS115）。开发预览，不代表各端已完成日用验收。

| 平台 | 版本 | 内容 | 下载 |
| --- | --- | --- | --- |
| Android | 0.1.76 build77 | 8×4 同键首候选修复、长文本候选重绑定、词记忆提示条移除、emoji 不进入自动记忆 | arm64 APK |
| macOS | 0.38.0 build97 | 词记忆提示条移除、emoji 不进入自动记忆、九键/长文本候选修复 | ZIP，Developer ID 签名并公证 |
| Windows | 0.7.6-win1 标准安装器 | 标准 NSIS 向导与卸载入口；安装/卸载由标准 uninstaller 管理，保留事务内核 | x64 EXE，尚无可信 CA 签名、未实机验证 |
| iOS | 1.0.0 build115 | 长九键 marked range 候选上屏修复、词记忆提示条移除、emoji 过滤 | 仅源码 |

各包文件名、长度与 SHA256 见 `BASELINE-PACKAGES.json`。

## 已知问题

- Windows 标准安装器候选未在实体 Windows 上执行安装/升级/卸载；并且仍未 Authenticode 签名，SmartScreen/SAC 可能提示风险。不要为此关闭系统保护。
- Android 只更新了 vivo，Sony/平板未更新；iOS 只安装 iPhone16；Mac/iOS/Android 的真实宿主完整体验仍需分别验收。
- 跨设备同步/归档的真实生产闭环、P3/P4/P6 迁移和长文本性能没有在本批重新验收。
- 普通候选“上屏后立即删除”的降权目前只覆盖九键，全拼与云端权重后续补齐。

## 源码与安装包对应

本发布所有安装包均由当前源码构建，不保证逐字节重建；第三方依赖与可选模型按索引获取。标准安装器源码见 `windows-source/windows/installer/standard.nsi`。

## 数据边界

- 运营域名、密钥、设备身份和私人原文不包含在此发布中。
- 云词频与个人词条在所选自建服务器上以明文保存，区别于密文同步通道；原始归档同样为明文。自部署看 `SELF-HOSTING.md`。
