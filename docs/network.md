# 网络与子网路由

设备的定位是办公室局域网里的**一台普通主机**，不是网关。

## 网络拓扑与地址

这台设备**不是**办公室的主路由，只是插在交换机上的一台普通主机：

```text
Internet
   │
主路由（DHCP 服务器 + 网关，网段未知也没关系）
   │
办公室交换机 ── 同事电脑 / NAS / 打印机 …
   │
OrayBox X1（Tailscale 子网路由 + 打印服务，地址由 DHCP 下发）
```

因此固件**不能**沿用 OpenWrt 默认的 `192.168.1.1`：那会和主路由抢地址，
自带的 DHCP 服务器也会和主路由抢发地址。首启脚本
`/etc/uci-defaults/98-lan-ip` 默认把本机设成 **DHCP 客户端**：

| 项 | 值 |
| --- | --- |
| 本机地址 | **DHCP 自动获取**（不用管办公室是 `192.168.1.x` 还是 `10.x`） |
| 网关 / DNS | 由主路由通过 DHCP 下发 |
| LAN DHCP 服务器 | **关闭**（`dhcp.lan.ignore=1`） |
| 主机名 | `mt76x8` |

**怎么找到它的地址**：登录办公室主路由的管理页面，在 DHCP 客户端 / 已连接设备
列表里找主机名 **`mt76x8`**。设备启动后也可以看状态灯（固件默认把灯全关了，
所以看不到灯，这是预期行为）。

需要固定地址时（例如主路由不给 DHCP 保留），可以直接在控制台「网络 → 局域网」
里切到静态，或者构建时把 `lan_mode` 改成 `static` 并填好 `lan_ip` /
`lan_gateway`；也可以 SSH 手动改：

```sh
uci set network.lan.proto='static'
uci set network.lan.ipaddr='192.168.1.2'
uci set network.lan.gateway='192.168.1.1'
uci set network.lan.dns='192.168.1.1'
uci commit network
reload_config
```

### 在控制台里改地址（带自动回滚）

「网络 → 局域网」可以切 DHCP / 静态。因为设备在办公室、改错就联系不上，
应用走的是两阶段确认：

1. 保存后立刻生效，页面显示「180 秒内点确认无误，否则自动回滚」；
2. 回滚靠 `/etc/lan-pending` + `/usr/lib/lan-rollback.sh`：超时、或者应用后
   直接断电重启（`/etc/init.d/lan-guard` 在开机时检查），都会恢复
   `/etc/config/network.bak` 并 reload；
3. 点「确认无误」后删除 pending，配置才会真正留下；
4. Tailscale 会跟着短暂断开（br-lan 重建时默认路由也没了），这是预期。

### 救援地址 192.168.1.2

「网络 → 救援地址」开关会在 `br-lan` 上额外加 `192.168.1.2/24`（默认关闭）。
忘了设备地址、或者静态地址配错网段时：笔记本直连设备、手动配 `192.168.1.x`，
打开 `http://192.168.1.2:8080/` 即可。

它**只加地址，不启动 DHCP 服务**，不会和办公室主路由抢地址；`network reload`
会清掉手工地址，所以 `/etc/hotplug.d/iface/90-rescue-ip` 会在 br-lan 每次 up
时补回来，`/etc/init.d/lan-guard` 负责开机时补加。

子网路由要发布的网段由 `rc.local` 从 `br-lan` 的实际地址算出（`ipcalc.sh` 折算
成网络地址），DHCP 换地址后会自动跟着更新，不需要手工维护路由表。

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
> 内网设备回包时会发给主路由。Tailscale 的 `--snat-subnet-routes`（默认开启）
> 会把来自 Tailnet 的流量源地址伪装成本机的局域网地址，于是内网设备直接把
> 回包发给本机，不经过主路由的路由表。
>
> SNAT 依赖 `xt_MASQUERADE`。早期镜像只装了 `iptables-nft`，缺
> `kmod-ipt-nat`，tailscaled 会报
> `health(warnable=router): ... Extension MASQUERADE ... missing kernel module`，
> 表现是客户端能发包但收不到回包（网页打不开、ping 不通）。现在镜像里已经
> 带上 `kmod-ipt-nat`、`kmod-ipt-conntrack` 和 `iptables-mod-conntrack-extra`。
> 自查：
>
> ```sh
> nft list chain inet fw4 ts-postrouting   # 应该有 -j MASQUERADE
> logread | grep -i 'warnable=router'      # 应该没有 MASQUERADE 报错
> ```

### 和客户端同网段时：必须关掉客户端的 accept-routes

这是子网路由最容易踩的坑。假设办公室是 `192.168.110.0/24`：

- 设备发布了 `192.168.110.0/24`；
- 办公室里的某台电脑（自己就在这个网段）也接受了子网路由；
- Tailscale 会装一条 `192.168.110.0/24 via 100.100.100.100` 的路由，metric 往往
  比本地网卡更低；
- 结果：这台电脑访问**路由器、打印机、本机设备**的包全被塞进隧道，再发夹回
  LAN，回包路径对不上——整个网段都打不开，看起来像“设备把网络搞挂了”。

**判断方法**（在出问题的那台电脑上）：

```powershell
Get-NetRoute -AddressFamily IPv4 | Where-Object { $_.DestinationPrefix -eq '192.168.110.0/24' }
```

如果多出一条 `NextHop 100.100.100.100`、`InterfaceAlias Tailscale`，就是它。

**处理**：

1. 托盘图标右键 → 取消 **Use Tailscale subnets**（CLI 改完 GUI 可能又开回来）；
2. 复查路由表，确认只剩本地网卡那条；
3. 等 30 秒再复查一次，确认没被重新装上。

远程机器（不在这个网段里）保持接受即可，它们走隧道是正常的。

**还需要手动批准路由**：Tailscale 管理后台 → **Machines** → 找到
`mt76x8` → 右侧 `...` → **Edit route settings** → 勾选实际网段
（控制台首页会显示，例如 `192.168.1.0/24`）。不批准的话，其他 Tailnet
成员看不到这个网段。

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

## 默认访问地址

| 场景 | 地址 |
| --- | --- |
| 局域网控制台（uhttpd，8080） | **http://<设备 IP>:8080/** |
| 局域网控制台（uhttpd，80） | `http://<设备 IP>/` |
| Tailscale 登录后（Serve） | `https://mt76x8.<你的-tailnet>.ts.net/` |
| SSH | `ssh root@<设备 IP>`（或 Tailscale IP） |
| 打印（RAW 9100） | `socket://<设备 IP>:9100` |

设备 IP 用主路由 DHCP 列表里的地址，或登录后在控制台首页直接看到。
