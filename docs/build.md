# 构建、发布与体积

GitHub Actions 上用 ImmortalWrt ImageBuilder 打包，`tailscaled` 单独编译。

## 如何触发编译

1. 打开 GitHub 仓库的 **Actions** 页面。
2. 选择 **Build MT76x8 Tailscale Firmware**。
3. 点击 **Run workflow**。
4. 填写输入参数：

   | 输入 | 默认值 | 说明 |
   | --- | --- | --- |
   | `profile` | `oraybox_x1` | 设备 profile；`list` 仅列出所有 mt76x8 profile |
   | `tailscale_tag` | 空 | 固定 Tailscale 版本（如 `v1.104.7`）；空 = 取最新稳定版 |
   | `lan_mode` | `auto` | `auto` = 从主路由 DHCP 自动取地址；`static` = 固定地址 |
   | `lan_ip` | `192.168.1.2` | 仅 `lan_mode=static` 时生效 |
   | `lan_gateway` | `192.168.1.1` | 仅 `lan_mode=static` 时生效 |

   > 不确定型号时先运行一次 `profile=list`，在 job 的 Summary 或日志中查看
   > `Available Profiles` 列表。
   >
   > **默认的 `lan_mode=auto` 不需要知道办公室网段**：设备会用 DHCP 自动拿
   > 地址、网关和 DNS，也不会和主路由抢地址。只有在需要固定地址时才切到
   > `static`，并且 `lan_ip` 不能等于 `lan_gateway`（工作流会直接拒绝）。

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

保留 `uhttpd` 有两个用途：托管控制台（`/www` + `/cgi-bin`），并让
`tailscale serve --bg http://127.0.0.1:80` 在本机 80 端口有可代理的目标。
uhttpd 同时监听 80 和 8080，所以局域网可以直接访问，也不再多起一个
BusyBox httpd 进程。

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

用 `profile=oraybox_x1` 跑通的真实构建（`run 44021981936`，分支
`feat/console-redesign`，Tailscale `1.104.7-tcbc74fe48e`）：

| 项目 | 数值 |
| --- | --- |
| tailscaled（mipsle softfloat，静态链接，v1.104.7） | 21,954,751 字节（20.9 MiB） |
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
| 启用 AdvertiseRoutes + 静态地址（run 44008677812） | 11,928,349 字节 | +64 KiB |
| 控制台 / 状态缓存（run 44015933949） | 11,928,349 字节 | — |
| 修正 Tailscale 版本 + 新控制台（run 44021981936） | 11,862,813 字节 | −64 KiB |

> 镜像大小会稳定在这个值附近：squashfs 按块压缩，几 KB 的脚本改动经常
> 落在同一批块里，所以不同提交的 sysupgrade.bin 长度可能一模一样，
> **sha256 才是判断是否同一镜像的依据**。

工作流在打包后还会校验 `build_dir/*/root-ramips` 里的
`www/index.html`、`www/cgi-bin/api.sh`、`www/cgi-bin/ts-login.sh`、
`etc/uci-defaults/96-web-auth`、`97-root-password`、`98-lan-ip`、
`99-tailscale-setup`、`usr/sbin/tailscaled` 是否存在、脚本是否有执行权限、
`tailscale` 软链接是否就位，避免 FILES 覆盖层静默失效；同时检查 `.manifest`，
一旦 `luci-base` 或 `libopenssl3` 被依赖回填就直接构建失败。

## 构建的触发方式

| 方式 | 用途 | 产物 |
| --- | --- | --- |
| **push 到 `main`** | 日常提交自动构建 | Actions artifact（保留 30 天） |
| **打 `v*` 标签** | 发布版本 | artifact + GitHub Release 附件 |
| **Actions → Run workflow** | 手动指定 profile / 版本 / 网段 | artifact |

```sh
# 日常：改完直接推，自动出固件
git push origin main

# 发布：打标签，自动建 Release 并附上 sysupgrade.bin
git tag v1.0.0
git push origin v1.0.0
```

push 触发很便宜（公开仓库不计费），所以不用省。几点注意：

- **只改文档/配置材料不触发**：`**.md`、`docs/`、`configs/`、`patches/`、
  `dts/` 都在 `paths-ignore` 里，避免改 README 也跑一次 5 分钟构建；
- **同分支并发只保留最新一次**：`concurrency` 会自动取消被打断的旧构建；
- **tag 构建一定触发**（path 过滤对 tag 不生效），适合做「可回滚的版本点」；
- push/tag 触发时没有手动输入，默认 `profile=oraybox_x1`、`lan_mode=auto`；
  要固定地址或指定 Tailscale 版本，仍然用 Run workflow。

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
