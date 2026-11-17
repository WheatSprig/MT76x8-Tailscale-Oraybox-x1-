# 控制台与统一 API

控制台不依赖 LuCI，只用一个 CGI 暴露全部读写操作。

## 控制台（极简 Web UI）

控制台是 `files/www/index.html` + 一个统一 CGI，纯静态 HTML + 内联 JS，
不依赖 CDN、Lua 或 LuCI：

| 路径 | 作用 |
| --- | --- |
| `/`、`/index.html` | 控制台页面（概览 / 网络 / Tailscale / 打印 / 系统） |
| `/cgi-bin/api.sh?op=status` | 状态 JSON（**需要登录**；未登录只返回 `auth:0`） |
| `/cgi-bin/api.sh?op=net` | 网络详情：DNS、MAC、监听端口（需要登录） |
| `/cgi-bin/api.sh?op=system` | 型号、固件、内核、负载、存储（需要登录） |
| `/cgi-bin/api.sh?op=logs` | 系统日志（需要登录） |
| `/cgi-bin/api.sh?op=diag` | 完整诊断：内存 / 进程 / 路由 / tailscale（需要登录） |
| `POST /cgi-bin/api.sh` | 所有写操作，`op=` 指定动作 |
| `POST /cgi-bin/upgrade.sh` | 上传 sysupgrade 镜像并升级（需要登录，见下） |
| `/cgi-bin/ts-login.sh` | 兼容入口：有授权链接就 302，没有就触发一次登录再跳回控制台 |

**登录**：用户名固定 `root`，密码与 SSH 相同。首次开机默认密码
**`mt76x8`**，控制台会一直显示红色提示直到你改掉。在「安全」里改密码会同时
写入 `/etc/tsui.passwd`（网页）和 `/etc/shadow`（SSH）。

> 想避免默认密码，给仓库配置 secret **`ROOT_PASSWORD_HASH`**（`openssl passwd -6`
> 生成的 SHA-512 crypt 哈希）。工作流会把它写进 `97-root-password`，
> 不设置则使用默认密码。

**能做的事情**：

- Tailscale：登录 / 退出、修改发布网段、开启 HTTPS、显示授权链接；
- 打印机：查看 `p910nd` 是否在监听、`/dev/usb/lp0` 是否存在、启用/停用/重启、
  改设备路径和端口；
- 网络：DHCP/静态地址、网关、DNS、MAC、监听端口、Tailscale 接口；
- 系统：型号、固件版本、内核、构建来源（提交 / 分支 / run 号 / Tailscale 版本）、
  内存与负载、日志与诊断、改主机名、改密码、固件升级；
- 安全：修改密码（网页 + SSH 同步）；
- 系统：重启设备。

> 构建来源来自镜像里的 `/etc/mt76x8-build`，由 CI 在打包前写入。
> 反馈问题时贴出「提交 + 构建号」就能定位到具体镜像。

### 未登录时看不到任何内部信息

和路由器后台一样：没登录只有一个登录页。`op=status` 也要求登录，未登录时只
返回 `{"ok":false,"auth":0}`，LAN/Tailscale IP、内存、打印机状态一律不下发。
`/cgi-bin/ts-login.sh`（会触发 `tailscale up`）同样要求登录后再访问。

### 子网路由：开关 + 多网段

Tailscale 页的「子网路由」：

- **广播本机 LAN 网段** 开关：按当前 `br-lan` 网段开/关；
- **+ 添加网段 / −**：除了本机 LAN，还可以发布别的内网（例如把两台不同网段
  的交换机接起来）；
- 输入格式很宽松：`192.168.1.0/24`、`192.168.1.0/255.255.255.0`，
  只写 `192.168.1.10` 时按 /24 归一化成 `192.168.1.0/24`；
- 保存后由后台调用一次 `tailscale set --advertise-routes=...`，新网段需要在
  Tailscale 后台批准（或由 ACL 的 `autoApprovers` 自动批准）。

### 主机名（系统与 Tailscale 共用一个）

只有一个名字来源：`uci system.@system[0].hostname`。在「系统 → 设备 → 主机名」
里改，保存后：

1. 立即写 `/proc/sys/kernel/hostname`（提示符、DHCP 上报马上变）；
2. `uci commit system` 持久化，重启、sysupgrade 都保留；
3. Tailscale 已连接时执行一次 `tailscale set --hostname=<名字>`，后台列表、
   MagicDNS、`tailscale status` 里一起更新；没连接就只落盘，连上后由 rc.local
   循环补同步（`/etc/tailscale/hostname.applied` 记上次成功值，落后时页面显示
   「（待应用）」）；
4. **不会新建节点**：节点密钥和 `100.x` 地址都不变，不会像重装那样多出
   `xxx-1`。

规则同 DNS label：小写字母、数字、`-`，最长 63，不能以 `-` 开头/结尾。

Tailscale 页只显示这个名字（只读），改名字统一在系统页，避免两个地方各存一份、
改了这边那边不生效。

> 从旧版本升级时，如果 `/etc/tailscale/hostname` 里存过单独的设备名，首次启动
> 会把它接管成系统主机名再删掉旧文件，不会把名字重置回 `mt76x8`。

> 名字在 tailnet 里已经被别的节点占用时，Tailscale 会自动加后缀（`mt76x8` →
> `mt76x8-1`）。想让名字严格等于输入值，先去管理后台删掉同名的离线节点。



`tailscale` CLI 是 22 MB 的 Go 程序，在 580MHz 单核上**启动一次就要十几秒**。
更糟的是它一旦和 tailscaled 抢 CPU，daemon 的看门狗（锁被持有 30 秒）就会
`panic: ipnlocal: watchdog timeout`，procd 重启、再次登录、再次被拖死 ——
表现为 Tailscale 反复掉线。

现在改成两件事：

```text
rc.local 后台循环（15 秒一次，一个 tailscale 命令都不跑）
        └──写──> /tmp/ts.status
浏览器 ──读取──> api.sh?op=status
```

- AuthURL 从 `logread` 里取（tailscaled 自己会打这行日志）；
- Running 与否看 `tailscale0` 有没有 IPv4 地址；
- 发布网段由登录时的 `tailscale up --advertise-routes` 写进 prefs 并持久化；
- `tailscale serve` 改成控制台里的「开启 HTTPS 访问」按钮，点一次即可。

CGI 只读文件，后台循环不碰 tailscale，所以无论 daemon 是否正常，
控制台都不会失去响应，也不会再把设备拖进崩溃循环。

> 另外 `tailscale` 需要 `/dev/net/tun`。`/etc/init.d/tailscale` 现在会先
> `modprobe tun` 并在缺失时手动 `mknod`，避免内核模块没加载导致 tailscaled
> 卡在启动阶段。

### 固件升级入口（防刷死）

「系统 → 固件升级」直接上传 `*sysupgrade.bin`，后端是
`/cgi-bin/upgrade.sh`。它比手动 SSH 多了几道闸门：

| 闸门 | 拒绝的情况 |
| --- | --- |
| 登录态 | 未登录直接 401 |
| 来源地址 | 来自 `100.*`（Tailscale）的上传会被拒绝 —— 升级前要停掉 tailscaled 腾内存，走隧道会把自己断在半路 |
| 大小 | < 4 MiB 或 > 15,728,640 字节 |
| 格式 | 前 4 字节不是 uImage 魔数 `27051956` |
| 设备 | 镜像里没有 `oraybox,x1` 元数据（不是这块板子的固件） |
| 校验 | 浏览器算了 sha256 时，与设备重新计算的结果比对 |
| 并发 | 已有升级任务时拒绝 |
| 内存 | 停掉 tailscaled 后可用内存仍 < 24 MB |

通过后镜像写到 `/tmp/fw.bin`（tmpfs），`sysupgrade -q` 负责真正的写入。
**sysupgrade 只写 firmware 分区（mtd3）**，u-boot / Breed 在 `0x0~0x30000`，
不会被碰 —— 写坏了断电按住 Reset 还能进 Breed 重刷。

唯一防不住的是**写入过程中断电**。所以升级前确认供电稳定，不要用会掉电的
插排；升级期间控制台会显示「升级中，设备即将重启」，约 2~3 分钟。
升级默认保留配置，Tailscale 登录态和 `/etc/tsui.passwd` 都在 keep.d 里。
