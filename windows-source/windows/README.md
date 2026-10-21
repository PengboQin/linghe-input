**2026-10-17 暂停中**：等 Codex 只读复核，复核期间不动本端代码。复核包 `docs/review/WINDOWS-020-REVIEW-PACKET.md`。
后续 Windows 开发必须不影响共享源码（core/、shared/ 不改，或改动前单独过审）。

2026-10-17 批次：**0.2.0-win1 已交叉构建并打包，等实体机实测**。本批移植了 Apple 的拼写纠错（漏/多/换序）、
纠错候选排序、数字与标点不阻断，并修掉候选加载上限 512>128 导致一屏候选为空的缺陷；安装器版本升到 0.2.0-win1
以支持保数据覆盖安装，CMake 补上 Setup/Settings target。共享内核在 macOS 用真实 librime 资源验证通过；
TSF 层只做到编译通过，未在 Windows 上运行。见[本批对账](../docs/WINDOWS-020-20261017.md)。

2026-10-17 接续入口：用户后续准备测试DeepSeek开发本端；本轮仅整理本地文档，未启动模型/构建/注册/安装。现有Win11 x64实体机、不用VM、可手动装EXE；先复用当前TSF工程和真实编辑会话验收，再迁移Apple策略。见[手机待修与Windows接续](../docs/MOBILE-SYMBOLS-NUMERIC-WINDOWS-HANDOFF-20261017.md)。

# Windows TSF工程

2026-10-16最新：用户有Windows11 x64实体机；Apple36/46收尾后恢复本端，不启VM。只读环境脚本`tools/preflight.ps1`已准备，尚未在实体机执行；构建/传包与真实桌面验收分开。见[实体机路线](../docs/WINDOWS-PHYSICAL-AND-ANDROID-20261016.md)。下文均为历史原型状态，不能视为当前日用输入法。

第十四轮：已接actual current-user/session1执行通道，真实ACP宿主与双架构DLL构建通过；配置激活不代表组件实例化/实际打字，当前TSF输入仍未通过。下一批走真正自签名DLL的事务安装和架构注册；不以进程内ClassFactory证明发行DLL。身份层在实际用户下已复验八个动作。见[当前结果](../docs/stages/P5/ROUND14-20261011.md)。

P1状态：ARM64/x64原生TSF/COM DLL与同源Rime已用项目本地LLVM-MinGW交叉构建；在Windows11 ARM64客体分别原生/模拟通过内核输入和DLL/COM接口、身份、生命周期验证。未签名、未注册或在系统宿主中输入；这些试验不是完整IME验收。

共享`core/`适配固定Rime C API。需要提供当前架构Rime headers/import library及DLL：

```powershell
cmake -S windows -B build/windows-arm64 -A ARM64 -DPRIVATE_RIME_PREFIX=C:/PrivateInputBuild/rime-arm64
cmake --build build/windows-arm64 --config Release
```

同架构Rime DLL与依赖、`data/rime`资源置于本App安装目录。构建/签名后才能测试自身DLL注册；不修改系统默认输入法，不操作其他产品的目录或证书。

当前实际入口：`python3 scripts/build_windows_cross.py arm64|x64`。工具包、source digest和最小资源编译兼容补丁见[P1第二轮结果](../docs/stages/P1/ROUND2-20261010.md)。客体用独有`C:\PrivateInputDev`目录和stdin校验传输；未打开共享文件夹或GUI窗口。

当前仍需：候选/组合串界面、TSF受限输入/密码场景、EditSession失败恢复、x64/ARM64及32位宿主验证、自签名安装包和完整用户配置。目标模式继续推进这些内容，当前工程不能作为日常输入候选或发行包。
