# MT76x8 ImmortalWrt + Tailscale（OrayBox X1）

把 **OrayBox X1**（MT76x8 / 16MB Flash / 64MB RAM）变成一个
**办公室 Tailscale 子网路由器 + USB 打印共享盒子**。

- 内置单文件 `tailscaled`（21.0 MiB），首次开机自动启用 Tailscale；
- 登录后把办公室网段发布为子网路由，人在外面也能访问内网设备；
- 板载 USB-A 接打印机，`p910nd` 提供 TCP 9100（RAW）；
- 自带小型 Web 控制台（登录 / 状态 / 打印 / 诊断），**没有 LuCI**；
- 首次开机自动关闭所有 LED；LAN 用 DHCP 自动取地址，不和主路由抢 DHCP。

> 设备：**OrayBox X1**（`board_name = oraybox,x1`，ImageBuilder profile
> `oraybox_x1`），16MB NOR + 64MB RAM，带 Breed。

## 快速开始

| 步骤 | 做什么 |
| --- | --- |
| 1. 构建 | push 到 `main` 自动构建，或 Actions → Run workflow 手动触发 |
| 2. 下载 | run 页面 artifact，或打 `v*` 标签后从 Releases 下载 |
| 3. 刷机 | 断开办公室网线，按住 Reset 上电进 Breed（192.168.1.1）刷 `*sysupgrade.bin` |
| 4. 找地址 | 接回办公室，在主路由 DHCP 列表里按主机名 `mt76x8` 找 |
| 5. 登录 | `http://<设备 IP>/`，用户名 `root`，密码 **`mt76x8`**（登录后立刻改） |
| 6. 授权 | 控制台点「登录 / 重新授权」，授权链接出现后点开完成 |
| 7. 批准 | Tailscale 后台 Machines → mt76x8 → Edit route settings |

镜像大小 **11,928,349 字节**，分区上限 15,728,640 字节（余量 3.6 MiB）。

> 刷机请优先用 Breed：25.12.2 → 23.05.4 属于降级，OpenWrt 内置 sysupgrade
> 可能拒绝。Breed 的地址也是 `192.168.1.1`，和办公室主路由冲突，刷机时要
> 断开办公室网线、电脑直连。

## 默认地址

| 场景 | 地址 |
| --- | --- |
| 控制台 | `http://<设备 IP>/`（uhttpd 同时监听 80 和 8080） |
| Tailscale | `https://mt76x8.<tailnet>.ts.net/`（需开启 HTTPS Certificates） |
| SSH | `ssh root@<设备 IP>` |
| 打印 | `socket://<设备 IP>:9100`（RAW 9100） |

## 文档

| 文档 | 内容 |
| --- | --- |
| [docs/network.md](docs/network.md) | 拓扑、DHCP/静态地址、子网路由与 SNAT |
| [docs/printing.md](docs/printing.md) | USB 打印、RAW 9100、HP P1008 这类主机型打印机 |
| [docs/console.md](docs/console.md) | 控制台功能、统一 API、状态缓存机制 |
| [docs/troubleshooting.md](docs/troubleshooting.md) | 转圈、崩溃循环、找不到 IP、打印机不工作 |
| [docs/build.md](docs/build.md) | 构建流水线、触发方式、体积历史与取舍 |
| [docs/hardware.md](docs/hardware.md) | LED、Reset、Breed 与刷机恢复 |
| [docs/source-build.md](docs/source-build.md) | 可选的源码构建（改内核/设备树时） |

## 目录结构

```text
.
├── .github/workflows/build-firmware.yml   # push/tag/manual 触发构建
├── files/                                 # 打进 rootfs 的覆盖层
│   ├── etc/init.d/tailscale               # procd 服务（modprobe tun）
│   ├── etc/uci-defaults/96-web-auth       # 控制台密码
│   ├── etc/uci-defaults/97-root-password  # root 密码哈希
│   ├── etc/uci-defaults/98-lan-ip         # DHCP / 静态地址、关 DHCP 服务
│   ├── etc/uci-defaults/99-tailscale-setup# LED / 打印 / 路由 / uhttpd / rc.local
│   ├── lib/upgrade/keep.d/mt76x8          # 升级时保留 Tailscale 状态与密码
│   └── www/                               # 控制台 + api.sh + ts-login.sh
├── configs/                               # 源码构建用的包列表 / 目标种子
├── dts/mt7628an_oraybox_x1.dts            # 上游板级 DTS 副本
├── patches/README.md                      # 源码构建补丁约定
├── docs/                                  # 详细文档
└── README.md
```

## 已知限制

- **64MB 内存**：批量走 Tailscale 传输会把单核打满，隧道和控制台都会变慢；
  这台设备的定位是「控制面 + 打印 + 轻量内网访问」，不适合当下载机或 NAS 网关。
- **WiFi 默认关闭**：AP/客户端模式还在评估（见 docs/network.md 的后续计划）。
- **控制台密码**用 salted SHA-256（设备上没有 crypt 工具），够 LAN 用；
  默认 `mt76x8`，务必在「安全」里改掉。
- **空密码 SSH 不可用**：OpenWrt 的 dropbear 不接受空密码，所以镜像里预置了
  默认密码。

## 本地自检

```sh
sh -n files/www/cgi-bin/api.sh
sh -n files/www/cgi-bin/ts-login.sh
sh -n files/etc/uci-defaults/99-tailscale-setup
python3 -c "import yaml;yaml.safe_load(open('.github/workflows/build-firmware.yml'))"
```
