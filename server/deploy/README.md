# 自建同步中继（Linux / systemd / Caddy）

输入法离线可用；同步是可选功能，不需要产品注册账号。本目录可随公开源码发布，示例使用 `sync.example.invalid`，请替换成自己的域名。自用运营地址、DNS记录、SSH资料、证据与私钥不属于公开发行内容。

## 需要准备什么

- 一台维护中的 Linux 主机，Python 3.10+、venv、systemd，以及 Caddy 2；SQLite由Python提供。
- 独立子域名的 A/AAAA 指向该主机。只新增同步子域，保留原网站记录；IPv6没有连通时不要发布AAAA。
- 80/443能从公网访问，以便Caddy签发和续期HTTPS证书；8028只绑定127.0.0.1，禁止公网放行。
- 以下命令需要管理员权限。已有Web服务时先备份并理解当前配置；不要用模板整体覆盖网站配置，不要同时抢占80/443。

IPv4是否固定只影响DNS维护；变化时需更新解析。裸IP不替代有效HTTPS证书。不要关闭客户端TLS校验。

## 安装独立目录

下载项目源码的固定发行版本并核对发行SHA256，**不要上传本机evidence、artifacts、私有配置或词库**。下方假设当前目录为源码根，主机已装好官方渠道的Python、venv和Caddy。依赖固定于 `server/requirements-production.txt`。

```sh
sudo useradd --system --home-dir /var/lib/private-input-relay --shell /usr/sbin/nologin private-input-relay
sudo install -d -o root -g root -m 755 /opt/private-input-relay/releases/release-1
sudo install -d -o private-input-relay -g private-input-relay -m 700 /var/lib/private-input-relay
sudo install -m 644 server/*.py server/requirements-production.txt /opt/private-input-relay/releases/release-1/
sudo python3 -m venv /opt/private-input-relay/venv
sudo /opt/private-input-relay/venv/bin/python -m pip install -r /opt/private-input-relay/releases/release-1/requirements-production.txt
sudo ln -s /opt/private-input-relay/releases/release-1 /opt/private-input-relay/current
```

用户或目录已存在时核对归属后复用，勿重复创建、覆盖现有状态或重新生成设备身份。正式服务目录只需运行源码；tests与fixture用于下方独立测试。

在独立临时目录保留完整 `server/` 和 `fixtures/protocol/` 相对结构，用该venv运行：

```sh
/opt/private-input-relay/venv/bin/python -m unittest discover -s server -p 'test_*.py'
```

测试创建临时SQLite，不应指向真实数据库。不要开启框架debug/body日志。

## 启动服务和HTTPS

```sh
sudo install -m 644 server/deploy/private-input-relay.service /etc/systemd/system/
sudo install -m 644 server/deploy/private-input-relay-expire.service /etc/systemd/system/
sudo install -m 644 server/deploy/private-input-relay-expire.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now private-input-relay.service private-input-relay-expire.timer
```

在**现有Caddy配置中追加** `relay.caddy.example` 对应的完整域块，替换为自己的子域名。先备份原配置，验证后用reload，不重启原网站：

```sh
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
curl --fail https://YOUR-SYNC-HOST/healthz
sudo systemctl is-active private-input-relay.service private-input-relay-expire.timer
```

期望healthz返回 `{"service":"private-input-relay","ready":true}`。同时核对原网站与原DNS，服务仅监听loopback。反向代理必须用真实TCP来源覆写 `X-PrivateInput-Peer`，不能信任客户端传入的X-Forwarded-For。若用Nginx，请等价配置真实来源、5MB代理请求上限和超时，保留loopback隔离；应用仍限制旧接口3MiB，仅近期词频接口允许5MiB。

## 可选近期词频通道

新版源包含 `recent_learning.py`，必须与relay和新版`expire_relay.py`一起复制，不能只更新主Python文件。`POST /v1/groups/{group}/recency`是独立签名／密文通道，旧学习／共享文本格式不变。每个learning成员在当前成员revision/epoch、公钥下声明新能力后才ready；未支持的旧服务器404时，新客户端仅回退原同步，不要求清库或重新配对。

服务端只保存角色能力、UTC参考日、nonce、有限事件摘要与每成员一份密文快照，不保存明文词条或组内容密钥。每组近期快照上限32MiB，明文单档上限2MiB，快照7天到期，39项本机relay回归含此通道与旧接口。服务时钟需正常；UTC日回拨时近期服务暂停，不能删除policy记录伪造时序。时间异常／客户端重启／锚过期时客户端只记累计量。

首次升级请先备份SQLite及WAL并在临时副本验证；新表为独立可选表，不改旧消息结构。定时expiry同时支持完整旧schema和完整新schema，未知／部分schema拒绝清理。回退旧relay时保留兼容新版表的expiry程序，不能用旧的严格表清单程序覆盖它。新功能的源码／隔离测试不等同于已部署，按自己的发行步骤更新服务后再升级全部写入组件。

字节契约、字段和加密格式见源码仓库 `docs/RECENCY-WIRE-V1-20261019.md`；不需要为本通道新增域名或改其他网站解析。

模板默认一个Gunicorn worker（四线程），CPU40%、内存192MiB、数据库页上限128MiB。若后续改多worker，应先将所有限流状态保持在共享数据库并做并发验证。负载/容量达到上限返回可重试错误，不应删库重来。SQLite逻辑删除、TTL和WAL截断不等于磁盘物理擦除。

## 接入客户端

所有发行版本统一默认不带中继地址，不再维护自用注入版。第一台在“设备与同步”填写自己的 `https://sync.example.invalid

1. 每个人用第一台设备“建立设备组”，各组完全独立，不共用词库或共享文本。
2. 已接入设备点击“接入新设备”，生成5分钟有效的二维码和六位接入码。
3. 新设备在App内扫码，自动取得服务器信息；手动输入六位码则必须额外填写相同服务器。认领绑定一台设备，重试须为同一签名请求。重生成、主动取消或过期使原码失效；仅关闭邀请展示页不取消。
4. 每台有完整组权限的已接入设备使用自己的签名独立发起并完成入组。原始设备不必在线，也不必继续在组；生成这次邀请的设备须能处理认领。成员变更以公开签名前序链验证，服务器原子提交成员、挑战与全部轮换密钥包，防并发半完成。冲突会自动重试，无需清库。
5. 连接后由用户分别启用“输入习惯与个人词库”和“共享文本”。基础输入不会因拒绝同步而失效。

手机相机只在用户点“扫描接入二维码”后使用，不自动读系统剪贴板。Mac可输入码或从用户选定的图片读取二维码。Mac 的配对处理随输入服务进程运行，不需要开设置窗口；iOS/Android 当前在主App活跃期间处理，不保证锁屏或后台无限在线。等待有120秒期限、重试和取消入口，离线/超时不会永久保持无解释的等待状态。

二维码 `privateinput://pair?data=v2:…` 使用 AES-GCM 封装服务器、信任锚和限时凭据，通用扫码器不会直接显示服务器明文；读取密钥由公开App规则导出，**仅防直接展示，不能防逆向或保密服务器地址**。二维码不含设备私钥、内容密钥或用户词库。旧v1二维码保留解码兼容。

手机可查看在组列表并移除电脑，不能移除另一台手机；可自行退出。手机默认30天无有效服务活动后离组，可设1–90天。每台手机独立计算；这不是按最后一次打字时间判断。离组会清除离组设备自己的个人词条、频次、置顶、短语、学习缓存、共享文本缓存和组密钥，升级不会清除。离线设备待下次运行或连接时执行，不能瞬时远程擦除，也不能追回独立系统备份、用户导出或别的设备已持有的数据。iOS未运行的键盘容器在扩展下次激活、处理输入前清理。

六位码适用于**信任的自建中继**：每IP每分钟5次、服务全局每分钟10次认领，票据总数256；二维码另有256位随机凭据。不得去掉限流或把码当成长期口令。此流程没有PAKE式抗恶意中继保证；在开放配对期间，中继运营者可能伪造认领。配对后的组密钥只在端上产生并以ECDH密钥包分发，正常中继无内容解密密钥，但仍可见公钥、组ID、时序与密文大小。自建服务要维护主机、TLS与访问安全。

## 更新、备份和回滚

- 服务源码在新的 `/opt/private-input-relay/releases/版本`，保持旧版本和数据库备份；勿在live目录直接改半套代码。
- 升级前运行测试、核对新增文件（包含 `quick_pairing.py` 和 `device_administration.py`）；用SQLite在线backup API生成**一致性**备份，不能只复制正在写入的sqlite主文件。
- 将current符号链接原子切到新版本，再只重启 `private-input-relay.service`；核对healthz、原网站、真实小额合成同步后收口。DNS和原网站配置不必随服务升级改变。
- 新表自动创建，旧成员和密文保持；旧设备类型先记为待更新，登录新版本后登记真实类型。启用新策略后旧v1成员变更被拒绝，使用该组的活跃客户端应升级到支持v2的版本；Windows也须单独迁移后才可承诺新组协议兼容。回滚旧代码需一起核对expiry脚本、数据库及端上已接受的签名链，不能以旧schema检查脚本配新库，也不能保证旧客户端接受v2。
- 数据目录仅服务账户可读；备份同样限权/加密并设保留期限。服务器备份**不包含端上内容密钥**，不能替代用户端的词库导出、设备身份与恢复设计。
- expiry定时器每分钟清理过期密文/票据和协议凭据。共享文本TTL10分钟，学习投递最长7天；无成员设备长期离线时需由仍持有数据的设备重发当前累积快照。日志不要记录请求体、码、二维码内容或明文输入。

在线备份例（输出位置必须预先建立、限权并可由服务账户写入）：

```sh
sudo -u private-input-relay /opt/private-input-relay/venv/bin/python - <<'PY'
import sqlite3
with sqlite3.connect('/var/lib/private-input-relay/relay.sqlite') as source:
    with sqlite3.connect('/var/lib/private-input-relay/backup-before-upgrade.sqlite') as target:
        source.backup(target)
PY
```

恢复时先停止自己的relay和expiry timer，在保留当前库副本后处理主库/WAL/SHM一致性，再验证SQLite完整性、权限和服务；不要覆盖其他站点目录。恢复过旧的组成员状态可能导致端上拒绝回退，因此备份恢复结果必须验证，不可承诺还原任意旧快照即可正常同步。

## 排障

- `404 / 410`：接入码过期、已认领、已取消或包未就绪；保持此次邀请设备的App活跃并重新生成，不依赖最初建组设备，不能用旧码无限重试。
- `429`：配对限流、协议/存储上限；等待窗口恢复，核对容量，不通过换IP、清库或关限流绕过。
- `403`：设备权限、来源代理或组成员不符；检查自己的代理来源覆写、端上组身份，勿清用户词库。
- `503`：先检查该relay的systemd状态、SQLite权限/空间和依赖。保留原库，修复后重试。
- DNS/证书失败：先核对新增子域、80/443公网连通及续期；不要修改原网站解析或跳过TLS校验。

发行者应把本文件、通用模板、依赖锁定、许可证、协议与测试fixtures随允许清单源码一起提供，发布包另说明签名与系统限制。单纯上传客户端不能算提供自建服务器支持。
