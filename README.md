# MT76x8 ImmortalWrt + Tailscale（OrayBox X1）

面向 **MT76x8 / 16MB ROM / 64MB RAM** 的极简 ImmortalWrt 固件工程。固件内置
单文件 `tailscaled`（内嵌 CLI），首次开机自动关闭所有 LED、启用 Tailscale，
并在 8080 端口提供节点授权页面。登录 Tailnet 后会自动执行 `tailscale serve`，
把本地 80 端口暴露到 Tailnet。

> 本仓库对应的实际设备：**OrayBox X1**（`board_name = oraybox,x1`，
> ImageBuilder profile = **`oraybox_x1`**）。设备当前运行 ImmortalWrt
> 25.12.2，16MB NOR + 64MB RAM，带 Breed。

## 目录结构

```text
.
├── .github/workflows/build-firmware.yml   # GitHub Actions 云端编译
├── files/
│   ├── etc/
│   │   ├── init.d/tailscale               # procd 服务（CI 也会重新生成）
│   │   └── uci-defaults/99-tailscale-setup# 首次开机：LED 关闭 / 服务 / rc.local
│   └── www/
│       ├── index.html                     # 移动端授权入口页
│       └── cgi-bin/ts-login.sh            # BusyBox sh CGI，获取 AuthURL
└── README.md
```

## 如何触发编译

1. 打开 GitHub 仓库的 **Actions** 页面。
2. 选择 **Build MT76x8 Tailscale Firmware**。
3. 点击 **Run workflow**。
4. 在 `profile` 输入框中填写：

   | 用途 | 值 |
   | --- | --- |
   | **OrayBox X1（本设备）** | **`oraybox_x1`** |
   | 查询所有可用 mt76x8 profile | `list` |
   | 其他 MT76x8 设备 | 对应 profile 名 |

   > 输入框默认值已经是 `oraybox_x1`，直接运行即可。
   >
   > 不确定型号时先运行一次 `list`，在 job 的 Summary 或日志中查看
   > `Available Profiles` 列表。

5. 编译成功后，在 run 页面底部下载
   `immortalwrt-mt76x8-<profile>-<run_number>` artifact，里面包含
   `*sysupgrade.bin` 和 `sha256sums`。

工作流使用 ImmortalWrt **23.05.4** 的 `ramips/mt76x8` ImageBuilder，剔除
LuCI/PPPoE/IPv6 相关包，并加入：

```text
ca-bundle kmod-tun iptables-nft uhttpd
-luci -luci-ssl -luci-app-firewall
-luci-app-opkg -luci-compat -luci-lib-base -luci-lib-ipkg
-default-settings -default-settings-chn -ipv6helper
-odhcpd-ipv6only -ppp -ppp-mod-pppoe -ip6tables -odhcp6c
```

保留 `uhttpd` 是为了让 `tailscale serve --bg http://127.0.0.1:80` 在本机 80
端口有可代理的页面；BusyBox httpd 继续在 8080 端口提供同一份 `/www` 页面。

> **为什么 negate 列表这么长**：只写 `-luci` 并不能移除 LuCI。默认包列表里
> `default-settings` 直接依赖 `luci`，`default-settings-chn` 依赖
> `luci-i18n-base-zh-cn`，`luci-app-opkg`/`luci-compat`/`luci-lib-ipkg` 依赖
> `luci-base`，`ipv6helper` 依赖 `odhcp6c`/`odhcpd-ipv6only`。opkg 会把它们
> 作为依赖重新装回来，所以必须把这些「入口包」也一起去掉。
> 去掉 `default-settings` 后主机名/时区会退回默认值，已由
> `99-tailscale-setup` 补回 `mt76x8` / `CST-8`。

## 已实测的构建结果

用 `profile=oraybox_x1` 跑通的真实构建（`run 44001845479`）：

| 项目 | 数值 |
| --- | --- |
| tailscaled（mipsle softfloat，静态链接） | 21,889,215 字节（20.9 MiB） |
| `*squashfs-sysupgrade.bin` | **12,976,925 字节（12.38 MiB）** |
| 15 MiB 分区余量 | 2,751,715 字节（2.62 MiB） |
| sha256 | `ffef677f701298002949ab1655e8286bb95a2b4479d1df6f9ce9bf91537bb54e` |
| LuCI | 已彻底移除（manifest 校验通过） |

作为对比：同样配置但 LuCI 被依赖回填的版本是 13,566,749 字节，裁掉后省下约
576 KiB。

工作流在打包后还会校验 `build_dir/*/root-ramips` 里的
`www/index.html`、`www/cgi-bin/ts-login.sh`、`etc/uci-defaults/99-tailscale-setup`、
`usr/sbin/tailscaled` 是否存在、脚本是否有执行权限、`tailscale` 软链接是否就位，
避免 FILES 覆盖层静默失效；同时检查 `.manifest`，一旦 `luci-base` 被回填就直接
构建失败。

## 默认访问地址

| 场景 | 地址 |
| --- | --- |
| 局域网（BusyBox httpd，8080） | **http://192.168.1.1:8080/** |
| Tailscale 登录后（Serve） | `https://mt76x8-web.<你的-tailnet>.ts.net/` |
| SSH | `ssh root@192.168.1.1`（或 Tailscale IP） |

如果设备 LAN 地址被改过，请把 `192.168.1.1` 换成实际地址。

## 首次开机流程

1. 刷入 `*sysupgrade.bin` 并重启。
2. `/etc/uci-defaults/99-tailscale-setup` 自动执行：
   - 关闭 `blue:status`、`red:status`、`white:status` 等所有 LED，并写入
     `/etc/config/system`，重启后仍保持熄灭；
   - 执行 `/etc/init.d/tailscale enable`；
   - 写入 `/etc/rc.local`：
     - `/usr/sbin/httpd -p 8080 -h /www`
     - 每 5 秒检查一次 `tailscale status --json`，检测到
       `"BackendState":"Running"` 后执行
       `tailscale serve --bg http://127.0.0.1:80`，随后退出循环。
3. 浏览器打开 `http://192.168.1.1:8080/`，点击 **连接 Tailscale**。
4. 首次点击会等待 1~3 秒生成官方授权链接，随后 302 跳转到
   `login.tailscale.com`。完成授权后节点即上线。
5. Tailscale 处于 `Running` 后，`tailscale serve` 会自动把 80 端口暴露到
   Tailnet，可通过 `https://mt76x8-web.<tailnet>.ts.net/` 访问。

> `tailscale serve` 的 HTTPS 证书要求 tailnet 已开启 HTTPS Certificates。
> 如未开启，可在设备上手动改为 HTTP：
> `tailscale serve --bg --http=80 http://127.0.0.1:80`。

## LED、Reset 按键与 Breed

- **LED**：初始化脚本会删除原有 LED 配置，为每个 `/sys/class/leds/*` 写入
  `trigger=none`、`default=0`，因此开机后所有指示灯保持关闭。
- **Reset 按键**：保留 OpenWrt 默认 `/etc/rc.button/reset` 行为——
  短按重启；长按约 5 秒执行 `factoryreset -y` 并重启。
- **Breed**：设备带 Breed 引导。建议刷机前在 Breed Web 控制台备份
  `factory`/`bdinfo`/`reserve` 等分区；变砖时可断电按住 Reset 再上电进入
  Breed 恢复。日常升级也可在 OpenWrt 内直接刷 sysupgrade。

## 重要说明

### 1. Go 版本不是 1.23

需求中的 Go 1.23 与 Tailscale 最新代码不兼容：当前 Tailscale
`go.mod` 要求 **Go 1.27.x**。工作流通过
`actions/setup-go` 的 `go-version-file: tailscale/go.mod` 自动安装匹配版本，
否则固定 1.23 会在编译阶段直接失败。

### 2. 16MB 空间非常紧张

Tailscale 官方的 `ts_omit_*` 精简标签并不够狠：按需求给出的 8 个标签编译，
mipsle 单文件二进制约 **38 MiB**（xz9 后约 7.5 MiB），几乎撑爆 15 MiB 分区。

工作流因此改用「保留必需功能、其余全部 omit」的标签集，由官方工具生成：

```sh
go run ./cmd/featuretags --min --add \
  serve,cli,osrouter,nattraversal,dns,useroutes,iptables,c2n,portmapper,tailnetlock,ipnbus,health,cliconndiag
```

结果约 **20.9 MiB**（xz9 后约 4.6 MiB），可在 15 MiB 分区内留出余量。
其中：

- `serve` / `netstack` 必须保留，否则 `tailscale serve` 不可用；
- `dns`、`iptables`、`useroutes` 保留，`--accept-routes` 与 DNS 才能工作；
- 丢弃 `aws`、`kube`、`ssh`、`webclient`、`drive`、`taildrop`、`systray`
  等与本设备无关的功能。

工作流仍会检查生成的 `sysupgrade.bin` 大小，超过 `15728640` 字节时
**直接失败并拒绝上传**，避免刷入半截固件。

如果构建因体积失败，可选方案：

- 继续追加 `ts_omit_*`（会牺牲部分路由/DNS 能力）；
- 使用外置 U 盘 + extroot 存放 `tailscaled`；
- 改用 32MB Flash 的硬件，或对现有设备扩容。

### 3. 从 25.12.2 降级到 23.05.4

设备当前是 25.12.2。通过 OpenWrt 内置 sysupgrade 跨大版本降级可能被拒绝，
建议优先通过 **Breed** 刷入 23.05.4 的 sysupgrade 镜像；刷机前务必备份
`factory` 分区与当前配置。

## 本地改动后自检

```sh
# 检查脚本语法（BusyBox sh 兼容）
sh -n files/www/cgi-bin/ts-login.sh
sh -n files/etc/uci-defaults/99-tailscale-setup
sh -n files/etc/init.d/tailscale

# 检查换行符（应全部为 LF）
file .github/workflows/build-firmware.yml files/www/cgi-bin/ts-login.sh
```
