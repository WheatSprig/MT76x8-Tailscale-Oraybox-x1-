# 控制台与统一 API

控制台不依赖 LuCI，只用一个 CGI 暴露全部读写操作。

## 控制台（极简 Web UI）

控制台是 `files/www/index.html` + 一个统一 CGI，纯静态 HTML + 内联 JS，
不依赖 CDN、Lua 或 LuCI：

| 路径 | 作用 |
| --- | --- |
| `/`、`/index.html` | 控制台页面 |
| `/cgi-bin/api.sh?op=status` | 状态 JSON（只读，不需要登录） |
| `/cgi-bin/api.sh?op=logs` | 系统日志（需要登录） |
| `/cgi-bin/api.sh?op=diag` | 完整诊断：内存 / 进程 / 路由 / tailscale（需要登录） |
| `POST /cgi-bin/api.sh` | 所有写操作，`op=` 指定动作 |
| `/cgi-bin/ts-login.sh` | 兼容入口：有授权链接就 302，没有就触发一次登录再跳回控制台 |

**登录**：用户名固定 `root`，密码与 SSH 相同。首次开机默认密码
**`mt76x8`**，控制台会一直显示红色提示直到你改掉。在「安全」里改密码会同时
写入 `/etc/tsui.passwd`（网页）和 `/etc/shadow`（SSH）。

> 想避免默认密码，给仓库配置 secret **`ROOT_PASSWORD_HASH`**（`openssl passwd -6`
> 生成的 SHA-512 crypt 哈希）。工作流会把它写进 `97-root-password`，
> 不设置则使用默认密码。

**能做的事情**：

- Tailscale：登录 / 退出、修改发布网段、显示授权链接（生成后自动出现按钮）；
- 打印机：查看 `p910nd` 是否在监听、`/dev/usb/lp0` 是否存在、启用/停用/重启、
  改设备路径和端口；
- 诊断：看系统日志、内存、进程、路由、tailscaled 是否在跑；
- 安全：修改密码（网页 + SSH 同步）；
- 系统：重启设备。

### 为什么状态是「缓存」的

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
