# 云端增量学习模块：2026-10-21 本地交付

后续实际部署/Native组件迁移已推进，最新状态见
`docs/CLOUD-LEARNING-SERVICE-MIGRATION-20261021.md`；下文保留最初本地交付证据。

状态：**模块实现与隔离合成测试完成；未部署、未开启任何真实组、未接入日用客户端**。
不以本模块测试证明 iOS 卡顿/100MB 流量已经解决。没有访问真实服务器、NAS、
设备或用户输入正文；旧 activity/archive、Relay 学习和 recency 通道均未修改。

## 已实现

- 可选独立 `/v1/learning/capabilities`、`/v1/learning/rpc`，复用严格 JSON、
  Ed25519 与只读成员鉴权。独立签名域，旧归档委托 key 不能调用；无匿名降级。
- group 和 device 两级默认 off；每机同意绑定安装 ID、同意版本、当前签名 key、
  signed membership history 中的连续入组区间。相同设备 ID/key 离组再加入也不能
  隐式复活旧同意。普通其它成员新增、未中断当前成员区间时不使其同意失效。
- 只接收明确确认词和控制事件。按组、代际、设备、安装、同意版本连续序号；
  重试幂等、ID/内容冲突拒绝、序号缺口拒绝。stale term/removed 的事件持久拒绝
  并推进序号，不让旧条目卡住全队列。上屏归档和剪贴板均不被扫描自动训练。
- reset/remove/restore 增加词条代际，防迟到复活；pin/unpin 独立控制。
  接收时的 fence 与 worker 已应用投影分离，未来控制不会越过已消费水位提前呈现。
- 一次性 worker：每组增量最多1024事件、每 tick 最多16到期组，按最旧 tick 优先。
  默认10分钟增量，小时级14天半衰期衰减，分数有界；模型或 ACK 水位不变就不发版。
  无静默后台线程；CLI + systemd service/timer 仅作为部署材料，没有启用。
- 版本化 upserts/tombstones、每设备/安装/同意版本已消费水位、完整目标模型 SHA；
  增量重试/分页按模型版本合并，不把单页差量当完整模型校验。
- 同一 resources/rime/charset/standard-8105.txt 简体规范字表校验 SHA 后准入；
  字表外扩展字、繁体异体例、emoji 等不能作为中文学习词导入。混合汉字词支持
  ASCII 字母数字与有限间隔符。词库覆盖不代表排序优先，weight 不得越过26键精确层。
- SQLite 独立事务/WAL/0600、1GiB页预算、每组2048词/100000事件暂定上限、status
  容量与待聚合数量可观测；满后拒收且保留客户端待上传，不删除原归档/历史。

## 本轮验证

在 `.tools/python/bin/python` 现有环境、隔离临时 SQLite 上：

- cloud_learning：20项单元/集成测试通过，含 HTTP包裹、签名域/nonce、默认同意、
  重试/冲突/乱序、reset/remove/restore、pin、控制水位、跨设备合并/跨组隔离、
  成员撤权/密钥轮换、signed history 同 ID/key 重入、10min/hour 调度、未来/离线时钟、
  简体字表和剪贴板/按键事件拒绝、多版本合并与目标 SHA、全局组任务上限。
- 原 activity_archive：58项回归通过；没有修改原服务或数据。
- Python→Swift：generate_fixture.py 生成纯合成“好/淘宝”模型，根任务报告 Swift
  反序列化/模型摘要匹配；本模块不代替根任务保存的 Swift 测试证据。
- Swift→Python：真实 Swift 生成的 status 请求/公钥/签名固定向量由
  LearningApplication.dispatch 验证并接纳，无私钥或真实身份。

证据：`evidence/cloud-learning-v1-20261021/{server-tests.txt,archive-regression.txt,
wire-fixture.json,swift-request-vector.json}`。测试临时 SQLite 已随上下文清理，未开启
监听端口、定时任务、模拟器或测试 fixture 后台进程。

## 未完成/部署前必须核对

1. 客户端真实确认词/控制事件接线、显式 opt-in UI、与旧 learning/recency 的迁移
   防重复加权、会话安全边界启用模型，属于根任务/平台适配，不是服务器已上线。
2. worker 锁与 HTTP 共用同 SQLite；已限定批量，但没有进行2048词×16组或多租户
   并发/恢复负载测试。定时任务样例不等于大规模部署验证。
3. 当前 bootstrap 保留版本日志，从空模型分段拉增量；长期快照、日志压缩/恢复代际
   管理、容量上限策略需先审核，不能当无限训练仓库直接用于大量公开用户。
4. 没有 APNs/FCM/WebSocket 通知服务；当前只是小模型增量拉取协议，不应恢复原有
   高频空轮询。iOS 挂起唤醒限制保持如实说明。
5. 模型是可解释有界选词统计，不是语义大模型/全历史 NLP；专业上下文、公共热词
   库及云端 NAS 重算法未实现。未引入外部模型/API，未上传真实正文。
6. 生产进程、端口/反代、文件权限和既有成员协议必须先复核。原服务/NAS不动，
   不能为新模块覆盖旧数据库、清组或自动开启其它设备。
