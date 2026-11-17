# MT76x8 ImmortalWrt + Tailscale（OrayBox X1）

面向 **MT76x8 / 16MB ROM / 64MB RAM** 的极简 ImmortalWrt 固件工程。固件内置
单文件 `tailscaled`（内嵌 CLI），首次开机自动关闭所有 LED、启用 Tailscale，
并在 8080 端口提供节点授权页面。登录 Tailnet 后会自动执行 `tailscale serve`，
把本地 80 端口暴露到 Tailnet。

在这台设备上的实际用途：**办公室的 Tailscale 子网路由器 + USB 打印共享盒子**。

- 加入 Tailnet 后把 `192.168.1.0/24` 发布为子网路由，人在外面也能访问办公室
  局域网里的设备；
- 板载 USB-A 口接打印机，`p910nd` 把 `/dev/usb/lp0` 映射成 TCP **9100**，
  同事的电脑（Windows/macOS/Linux）都能像本地网络打印机一样添加。

> 本仓库对应的实际设备：**OrayBox X1**（`board_name = oraybox,x1`，
> ImageBuilder profile = **`oraybox_x1`**）。设备当前运行 ImmortalWrt
> 25.12.2，16MB NOR + 64MB RAM，带 Breed。

## 目录结构

```text
.
├── .github/workflows/build-firmware.yml   # GitHub Actions 云端编译（tailscale / image 两段）
├── files/
│   ├── etc/
│   │   ├── init.d/tailscale               # procd 服务
│   │   ├── uci-defaults/98-lan-ip         # 首次开机：静态 IP / 关 DHCP
│   │   └── uci-defaults/99-tailscale-setup# 首次开机：LED 关闭 / 打印 / 子网路由 / rc.local
│   └── www/
│       ├── index.html                     # 移动端授权入口页
│       └── cgi-bin/ts-login.sh            # BusyBox sh CGI，获取 AuthURL
├── configs/
│   ├── target.seed                        # 源码构建的目标种子配置
│   ├── packages.set                       # 要装的包
│   └── packages.unset                     # 要剔除的包
├── dts/mt7628an_oraybox_x1.dts            # 上游板级 DTS 副本（核对分区/LED/按键）
├── patches/README.md                      # 源码构建补丁目录约定（当前为空）
├── docs/source-build.md                   # 可选的源码构建流水线说明
└── README.md
```

## 如何触发编译

1. 打开 GitHub 仓库的 **Actions** 页面。
2. 选择 **Build MT76x8 Tailscale Firmware**。
3. 点击 **Run workflow**。
4. 填写输入参数：

   | 输入 | 默认值 | 说明 |
   | --- | --- | --- |
   | `profile` | `oraybox_x1` | 设备 profile；`list` 仅列出所有 mt76x8 profile |
   | `tailscale_tag` | 空 | 固定 Tailscale 版本（如 `v1.104.7`）；空 = 取最新稳定版 |
   | `lan_ip` | `192.168.1.2` | 本机在办公室局域网里的静态地址 |
   | `lan_gateway` | `192.168.1.1` | 办公室主路由（网关 + DNS） |

   > 不确定型号时先运行一次 `profile=list`，在 job 的 Summary 或日志中查看
   > `Available Profiles` 列表。
   >
   > `lan_ip` 不能和主路由相同，工作流会拒绝 `lan_ip == lan_gateway` 的组合。

5. 编译成功后，在 run 页面底部下载
   `immortalwrt-mt76x8-<profile>-<run_number>` artifact，里面包含
   `*sysupgrade.bin` 和 `sha256sums`。

流水线分成两个 job，可以分别重跑：

| job | 内容 | 耗时 |
| --- | --- | --- |
| `Build tailscaled (mipsle)` | 拉 Tailscale 源码，`GOARCH=mipsle GOMIPS=softfloat` 交叉编译，上传 `tailscaled-mipsle` artifact | 4~6 分钟 |
| `Build image (<profile>)` | 下载上面的 artifact，用 ImageBuilder 装包 + 塞 `files/` + 打包 | 3~6 分钟 |

只想换脚本/换包时，`tailscaled` job 的产物没有变化，但 GitHub Actions 的
写法是「job 依赖」，所以仍会重跑一次（Go 侧有 `setup-go` 缓存，通常 1 分钟
以内）。想固定 Tailscale 版本，可在 `tailscale_tag` 输入框填 `v1.104.7`
之类的 tag；留空则自动取最新稳定版。

工作流使用 ImmortalWrt **23.05.4** 的 `ramips/mt76x8` ImageBuilder，剔除
LuCI/PPP/IPv6 相关包，并把 TLS 栈从 OpenSSL 换成 mbedTLS：

```text
ca-bundle kmod-tun iptables-nft uhttpd
kmod-usb-printer p910nd
wpad-basic-mbedtls libustream-mbedtls20201210
-wpad-basic-openssl -libustream-openssl -libustream-openssl20201210
-luci -luci-ssl -luci-app-firewall
-luci-app-opkg -luci-compat -luci-lib-base -luci-lib-ipkg
-default-settings -default-settings-chn -ipv6helper
-odhcpd-ipv6only -ppp -ppp-mod-pppoe -ip6tables -odhcp6c
```

保留 `uhttpd` 是为了让 `tailscale serve --bg http://127.0.0.1:80` 在本机 80
端口有可代理的页面；BusyBox httpd 继续在 8080 端口提供同一份 `/www` 页面。

> **为什么 `libustream` 要写两个 negate**：默认包列表里出现的是选择器名
> `libustream-openssl`，真正的实现包叫 `libustream-openssl20201210`。只去掉
> 后者，选择器仍会把 openssl 实现装回来，并和 mbedtls 版争抢
> `/lib/libustream-ssl.so`，构建直接失败（run `44005400819`）。两个都去掉，
> 才会走 `libustream-mbedtls20201210`。

> **为什么 negate 列表这么长**：只写 `-luci` 并不能移除 LuCI。默认包列表里
> `default-settings` 直接依赖 `luci`，`default-settings-chn` 依赖
> `luci-i18n-base-zh-cn`，`luci-app-opkg`/`luci-compat`/`luci-lib-ipkg` 依赖
> `luci-base`，`ipv6helper` 依赖 `odhcp6c`/`odhcpd-ipv6only`。opkg 会把它们
> 作为依赖重新装回来，所以必须把这些「入口包」也一起去掉。
> 去掉 `default-settings` 后主机名/时区会退回默认值，已由
> `99-tailscale-setup` 补回 `mt76x8` / `CST-8`。

## 已实测的构建结果

用 `profile=oraybox_x1` 跑通的真实构建（`run 44006144529`，切换 mbedTLS + 加 USB 打印）：

| 项目 | 数值 |
| --- | --- |
| tailscaled（mipsle softfloat，静态链接） | 21,954,751 字节（20.9 MiB） |
| `*squashfs-sysupgrade.bin` | **11,862,813 字节（11.31 MiB）** |
| 15 MiB 分区余量 | 3,865,827 字节（3.69 MiB） |
| LuCI | 已彻底移除（manifest 校验通过） |
| OpenSSL | 已彻底移除（切到 mbedTLS，省约 1.5 MiB） |
| `p910nd` / `kmod-usb-printer` | 均已在 manifest 中 |

历史对比：

| 版本 | 大小 | 变化 |
| --- | --- | --- |
| 含 LuCI（run 43999090329） | 13,566,749 字节 | — |
| 裁掉 LuCI（run 44001845479） | 12,976,925 字节 | −576 KiB |
| 切 mbedTLS + USB 打印（run 44006144529） | 11,862,813 字节 | −1.09 MiB |

工作流在打包后还会校验 `build_dir/*/root-ramips` 里的
`www/index.html`、`www/cgi-bin/ts-login.sh`、`etc/uci-defaults/98-lan-ip`、
`etc/uci-defaults/99-tailscale-setup`、`usr/sbin/tailscaled` 是否存在、脚本是否
有执行权限、`tailscale` 软链接是否就位，避免 FILES 覆盖层静默失效；同时检查
`.manifest`，一旦 `luci-base` 或 `libopenssl3` 被依赖回填就直接构建失败。

## USB 打印共享

板载 USB-A 口在 SoC 的 `mt7628an.dtsi` 里默认启用（`usbphy`/`ehci`/`ohci`
都没有 `status = "disabled"`），官方支持提交也写明
`USB: 1x USB Type-A 2.0 Host Port`，所以**不需要改设备树、不需要重编内核**。

固件里只加了两个包：

| 包 | 作用 | 大小 |
| --- | --- | --- |
| `kmod-usb-printer` | 提供 `/dev/usb/lp0` | 8 KiB |
| `p910nd` | 把打印数据流转成 TCP 9100 | 11.6 KiB |

首次开机时 `99-tailscale-setup` 会写入：

```text
config p910nd 'printer'
    option device '/dev/usb/lp0'
    option port '0'          # 0 表示 TCP 9100
    option bidirectional '1'
    option enabled '1'
```

**添加打印机（Windows）**：设置 → 蓝牙和设备 → 打印机和扫描仪 → 添加设备
→ 我需要的打印机不在列表中 → 使用 TCP/IP 地址添加 → 设备类型选 **TCP/IP**，
地址 `192.168.1.2`，端口 **9100**（RAW），驱动选打印机自带驱动。

**macOS / Linux**：

```sh
lpadmin -p office -E -v socket://192.168.1.2:9100 -m everywhere
```

**验证**：

```sh
# 打印机插上后应出现设备节点
ls -l /dev/usb/lp0
# 服务应处于 running
/etc/init.d/p910nd status
netstat -ltn | grep 9100
```

如果 `lp0` 不存在，先确认打印机被识别：

```sh
dmesg | grep -i usblp
lsusb 2>/dev/null || cat /sys/kernel/debug/usb/devices
```

部分打印机（尤其是 GDI/WinPrinter 类）只支持厂商私有协议，USB 直通也打印
不了，这种机器需要换 PCL/PS 机型。

## 子网路由（办公室局域网访问）

固件把设备本身配置成 Tailscale 子网路由器：

1. 开机时从 `network.lan` 的地址/掩码算出网段（`ipcalc.sh`），写进
   `/etc/tailscale/lan-cidr`（例如 `192.168.1.0/24`）；
2. `tailscale up` 带上 `--advertise-routes=<CIDR>`（登录页跳转时也一样）；
3. 打开 `net.ipv4.ip_forward=1`，并把 `tailscale0` 加进防火墙的 `lan` zone；
4. 登录成功后再执行一次 `tailscale set --advertise-routes=<CIDR>`，保证改了
   LAN 网段也能生效。

> 编译 tailscaled 时必须保留 `AdvertiseRoutes` 这个 feature（不能带
> `ts_omit_advertiseroutes`），否则 `--advertise-routes` 虽然能写进 prefs，
> 本机不会把发布的网段当作本地网络处理，子网路由实际不生效。

> **为什么不需要在主路由上加静态路由**：本机不是办公室局域网的网关，
> 内网设备回包时会发给主路由 `192.168.1.1`。Tailscale 的
> `--snat-subnet-routes`（默认开启）会把来自 Tailnet 的流量源地址伪装成
> `192.168.1.2`，于是内网设备直接把回包发给本机，不经过主路由的路由表。

**还需要手动批准路由**：Tailscale 管理后台 → **Machines** → 找到
`mt76x8-web` → 右侧 `...` → **Edit route settings** → 勾选
`192.168.1.0/24`。不批准的话，其他 Tailnet 成员看不到这个网段。

客户端侧如果要用这个子网，需要接受路由：

```sh
# Linux
sudo tailscale up --accept-routes
# Windows / macOS 在托盘菜单里勾选 "Use Tailscale subnets"
```

验证：

```sh
tailscale status --json | grep -i advertisedroutes
ip route show table all | grep 192.168.1
```

## 网络拓扑与地址

这台设备**不是**办公室的主路由，只是插在交换机上的一台普通主机：

```text
Internet
   │
主路由 192.168.1.1/24（DHCP 服务器、网关）
   │
办公室交换机 ── 同事电脑 / 打印机共享 / NAS …
   │
OrayBox X1 192.168.1.2/24（Tailscale 子网路由 + 打印服务）
```

因此固件**不能**沿用 OpenWrt 默认的 `192.168.1.1`：那会和主路由抢地址，
自带的 DHCP 服务器也会和主路由抢发地址。首启脚本
`/etc/uci-defaults/98-lan-ip` 会改成：

| 项 | 值 |
| --- | --- |
| 本机地址 | `192.168.1.2/24`（静态） |
| 网关 / DNS | `192.168.1.1`（主路由） |
| LAN DHCP 服务器 | **关闭**（`dhcp.lan.ignore=1`） |
| 主机名 | `mt76x8` |

构建时可以改这两个值（工作流输入 `lan_ip` / `lan_gateway`），例如办公室网段
是 `10.0.0.0/24`：

```text
lan_ip      = 10.0.0.2
lan_gateway = 10.0.0.1
```

刷机后也可以手动改：

```sh
uci set network.lan.ipaddr='192.168.1.2'
uci set network.lan.gateway='192.168.1.1'
uci set network.lan.dns='192.168.1.1'
uci commit network
reload_config
```

子网路由要发布的网段由脚本自动计算（`ipcalc.sh` 从 `network.lan` 的地址和掩码
得出网络地址），所以改完 IP 不用另外维护路由表。

## 默认访问地址

| 场景 | 地址 |
| --- | --- |
| 局域网（BusyBox httpd，8080） | **http://192.168.1.2:8080/** |
| Tailscale 登录后（Serve） | `https://mt76x8-web.<你的-tailnet>.ts.net/` |
| SSH | `ssh root@192.168.1.2`（或 Tailscale IP） |
| 打印（RAW 9100） | `socket://192.168.1.2:9100` |

如果改了 `lan_ip`，把上面的 `192.168.1.2` 换成实际地址。

## 首次开机流程

1. 刷入 `*sysupgrade.bin` 并重启。
2. `/etc/uci-defaults/98-lan-ip` 先把本机改造成局域网主机：静态
   `192.168.1.2/24`、网关/DNS 指向 `192.168.1.1`、关闭 LAN 上的 DHCP 服务器。
3. `/etc/uci-defaults/99-tailscale-setup` 自动执行：
   - 关闭 `blue:status`、`red:status`、`white:status` 等所有 LED，并写入
     `/etc/config/system`，重启后仍保持熄灭；
   - 执行 `/etc/init.d/tailscale enable`；
   - 启用 `p910nd`（`/dev/usb/lp0` → TCP 9100）；
   - 计算 LAN 网段、打开 `ip_forward`、把 `tailscale0` 加进 `lan` 防火墙 zone；
   - 写入 `/etc/rc.local`：
     - `/usr/sbin/httpd -p 8080 -h /www`
     - 刷新 `/etc/tailscale/lan-cidr`
     - 每 5 秒检查一次 `tailscale status --json`，检测到
       `"BackendState":"Running"` 后执行
       `tailscale set --advertise-routes=<CIDR>` 和
       `tailscale serve --bg http://127.0.0.1:80`，随后退出循环。
4. 浏览器打开 `http://192.168.1.2:8080/`，点击 **连接 Tailscale**。
5. 首次点击会等待 1~3 秒生成官方授权链接，随后 302 跳转到
   `login.tailscale.com`。完成授权后节点即上线。
6. Tailscale 处于 `Running` 后，`tailscale serve` 会自动把 80 端口暴露到
   Tailnet，可通过 `https://mt76x8-web.<tailnet>.ts.net/` 访问。

> **刷机时建议保留配置**：`uci-defaults` 虽然在每次刷机后都会重新执行（它们
> 不在 sysupgrade 的保留列表里），但 `/etc/config` 里的 root 密码、SSH 主机
> 密钥、Tailscale 状态只有保留配置才能续用。全新刷入时 root 密码为空，
> 先通过 8080 页面完成 Tailscale 登录，再用 `passwd` 设置密码即可。

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

### 4. 为什么不做源码构建

ImageBuilder 不编内核，所以 3~6 分钟就出固件；源码构建要先把
tools/toolchain/内核全部交叉编译一遍，冷启动 40~90 分钟，GitHub 托管 runner
的 14 GB 磁盘也不够，得先删 SDK 腾出 25~30 GB。

更关键的是收益很小：`sysupgrade.bin` 里内核只占约 2.5 MiB，其中大部分还是
squashfs 元数据和基础配置，内核侧优化到极限也只能再省 100~300 KB。真正的大头
是 `tailscaled`（4.6 MiB）和 OpenSSL 栈（已通过换 mbedTLS 去掉 1.5 MiB）。

需要改内核/设备树/驱动时再走这条路，材料已经准备好：

- `dts/mt7628an_oraybox_x1.dts`：上游板级 DTS 副本（分区、LED、Reset）
- `configs/target.seed`、`configs/packages.set`、`configs/packages.unset`
- `patches/README.md`：补丁目录约定
- `docs/source-build.md`：三阶段流水线、缓存 key、磁盘约束

## 本地改动后自检

```sh
# 检查脚本语法（BusyBox sh 兼容）
sh -n files/www/cgi-bin/ts-login.sh
sh -n files/etc/uci-defaults/99-tailscale-setup
sh -n files/etc/init.d/tailscale

# 检查换行符（应全部为 LF）
file .github/workflows/build-firmware.yml files/www/cgi-bin/ts-login.sh
```
