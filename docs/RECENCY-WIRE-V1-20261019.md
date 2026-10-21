# 近期词频隔离同步协议 v1（实现契约）

仅新端使用 `POST /v1/groups/{GROUP}/recency`。旧 `.learning` 域、RPC 1–14 和 learning-v1.json 不变；服务器不支持时回退累计量，不关闭原同步。本批只实现／隔离测试，不部署现网。

## 请求与认证

JSON字段：`version=1, group, sender, nonce, issuedAt, operation, body, signature`。UUID为标准UUID，Data为标准base64，整数为无符号64位。`body`解码后最多3MiB，HTTP请求最多5MiB。

Ed25519签名正文为：`UTF8("PrivateInput/recency-request/v1\0") + UInt8(1) + group UUID16 + sender UUID16 + nonce UUID16 + issuedAt UInt64BE + operation UInt8 + SHA256(body)`。与旧RPC签名域严格分离。要求当前成员具有learning权限；issuedAt与服务端相差小于300秒；nonce独立保存600秒，重放拒绝。请求无cookie、缓存、重定向、证书绕过或正文日志。

操作：

1. hello：body=`{epoch,membershipRevision,roles}`。roles唯一、最多4项，取app/keyboard/desktop/ime，必须包含keyboard或ime。声明覆盖本设备所有写入组件。每个learning成员在当前epoch/revision、公钥下且7天声明租约未到期才ready；缺失即false。不能即时识别恢复旧binary，最长7天后旧声明失效。
2. push：body=`{epoch,membershipRevision,envelope,expectedEvent}`。只在ready时接收，保留每个sender/epoch的一份最新不可变快照，最多32MiB/组。expectedEvent是hello返回的publishedEvent（空表示没有槽）；服务端CAS比对当前槽，不符返回409且不覆盖。同秒乱序也不能靠UUID或墙钟决定先后。body内envelope是下述JSON对象，不二次字符串化。服务端只见密文。
3. pull：body=`{epoch,membershipRevision,after}`。after为上一项sender UUID字符串，首项空字符串；当前learning成员快照按sender升序，跳过请求者，每次最多一项。结果`envelope`可为null，`next`为该项sender或空串。调用者最多遍历64项；快照是MAX可合并状态，不是可加事件。

成功响应共同字段：`version=1, group, sender, nonce, epoch, membershipRevision, serverTime, referenceDay, ready, missing, publishedEvent`。UUID和nonce必须匹配请求；epoch/revision必须匹配已认证本地组，参考日由服务端UTC日维护，绝不由peer最大桶推进。publishedEvent为空或当前自己的槽event UUID。hello另有自己的`envelope`（无槽为null）；客户端先解密并MAX合并该快照，防旧本地状态重新覆盖服务端已有增量。push另有`accepted=true,event`，且成功标记摘要前publishedEvent也须匹配刚发事件；pull另有对端的`envelope,next`。错误为非200＋`{error: machine_code}`，只向UI展示固定有限状态。

参考日单调推进；服务端UTC日回退到已保存日之前时拒绝近期服务，保旧同步。客户端仅在HTTPS已认证origin（隔离测试可loopback HTTP）、匹配nonce、RTT≤10秒时接受时间锚；锚记录响应收到时的uptime和serverTime并保守计时（时间略滞后不早跨UTC日），7天过期/重启/异常按累计回退。ready=false时不得新分桶/发布；旧桶仍保留。

## 密文快照

字段：`version=1, group, sender, event, epoch, issuedAt, expiresAt, sealed, signature`。payload为RecentLearningArchive v2/algorithmVersion1，最多2MiB；有效期最多7天。

header=`UTF8("PrivateInput/recent-learning-envelope/v1\0") + UInt8(1) + group UUID16 + sender UUID16 + event UUID16 + epoch UInt64BE + issuedAt UInt64BE + expiresAt UInt64BE`。

HKDF-SHA256：IKM=当前32字节group master；salt=`group UUID16 + epoch UInt64BE`；info=`UTF8("PrivateInput/recent-learning-key/v1\0") + sender UUID16 + sender Ed25519公钥32`；输出32字节。ChaCha20-Poly1305使用每次新12字节随机nonce、header作为AAD；sealed=`nonce12+ciphertext+tag16`。签名=`Ed25519(header+sealed)`。随机nonce与新派生域不复用旧递增序列密钥。

接收者先检查组/epoch/当前签名成员/时间及长度，再验签解密和原子MAX合并。重复同一event／同快照不加词频；同event不同sealed拒绝。新成员／换钥后旧epoch快照不再返回，完整v2状态在新epoch重新封装发布。最新slot传输不提供事件顺序；代际、置顶版本和桶计数决定收敛，不用上传时间覆盖词频。

同一已接受event的重传只返回幂等回执，不重新覆盖槽；回执accepted不保证该事件仍是最新槽，客户端还须检查publishedEvent。旧请求延迟到达时expectedEvent不匹配，保留新槽；下轮hello合并当前快照再发布。空槽强制补发，每24小时续封未变档，避免7天到期后长期缺失。

## 各端桥接

Apple共享wire类型由根提供：`RecentLearningEnvelope`、`RecentLearningClient`；客户端hello/push/pull返回`RecentLearningServerStatus`，本地侧协调器接受已认证状态与时间样本，维护独立v2文件。Android/Windows按同字节契约独立实现，不写共享主线。

所有网络和v2解析/持久化在同步worker；输入线程只读已发布的有界内存分数。确认输出与checkpoint只能选一个近期增量所有者，避免双算。无时间证据的首次迁移或跨日checkpoint仅累计；不能把恢复后的旧量分成今天。
