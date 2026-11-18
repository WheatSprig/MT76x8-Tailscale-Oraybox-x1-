# 常见问题

## 控制台一直转圈 / 状态读取失败

旧固件在 CGI 里同步执行 `tailscale status`，22 MB 的二进制在 580MHz 上要
十几秒才返回，几次点击就把 uhttpd 的请求槽位占满。

现在的做法见 `docs/console.md`：CGI 只读 `/tmp/ts.status`，后台循环不调用
tailscale。如果仍然转圈，先看：

```sh
cat /tmp/ts.status          # 缓存是否在更新（updated 时间戳）
ps w | grep -c uhttpd       # 是否堆积了 CGI 进程
logread | tail -20
```

## Tailscale 反复掉线（`panic: ipnlocal: watchdog timeout`）

症状：`tailscale0` 时有时无，`logread | grep -c panic` 不断增长，
`tailscaled` 的 PID 每隔一两分钟换一次。

原因是 **CPU 被 22 MB 的 CLI 抢走**：看门狗发现某个锁被持有超过 30 秒就
主动 panic，让 procd 重启。触发源通常是后台循环里的 `tailscale set` /
`tailscale serve`，或者是连续点击控制台按钮。

现在的固件已经不在后台调用 CLI；如果升级后仍然出现：

```sh
pkill -f '/usr/sbin/tailscale '   # 杀掉残留 CLI
/etc/init.d/tailscale restart
logread | grep -c panic           # 应该不再增长
```

## 找不到设备 IP

默认是 DHCP 客户端。到主路由的 DHCP 客户端列表里按主机名 `mt76x8` 找。
如果办公室没有 DHCP 服务器，设备会一直拿不到地址 —— 这时需要改成
`lan_mode=static` 重新构建，或者临时用 Breed 恢复。

## 打印机不工作

```sh
ls -l /dev/usb/lp0          # 没有就是 USB 没识别
dmesg | grep -i usblp
netstat -ltn | grep 9100    # 没有就是 p910nd 没起来
```

`/dev/usb/lp0` 不存在通常是：打印机是 GDI/主机型且没有走标准 USB 打印类，
或者线/口有问题。能看到 `usblp0: USB Bidirectional printer` 就说明识别正常，
剩下的是客户端驱动问题（见 `docs/printing.md`）。

## 固件刷完 192.168.1.1 打不开

那是旧的默认地址。新固件是 DHCP 客户端，地址由主路由分配；
`192.168.1.1` 现在很可能是办公室主路由自己。

## 接上设备后，同一网段的电脑打不开路由器 / 其他内网设备

现象：设备一插上，办公室某台电脑访问 `192.168.110.1`、打印机、甚至设备自己
都超时；把设备拔掉立刻恢复。

原因：那台电脑**自己就在被广播的网段里**，又开启了 Use Tailscale subnets，
Tailscale 装了一条 `192.168.110.0/24 via 100.100.100.100` 的低 metric 路由，
把本地流量劫进了隧道。

处理：

1. 在那台电脑上关掉 **Use Tailscale subnets**（托盘菜单），不要只用 CLI，
   GUI 可能会把它改回来；
2. 复查：

   ```powershell
   Get-NetRoute -AddressFamily IPv4 | Where-Object { $_.DestinationPrefix -eq '192.168.110.0/24' }
   ```

   只应该剩 `NextHop 0.0.0.0`、`InterfaceAlias` 是本地网卡的那条；
3. 等 30 秒再确认一次没有被重新装上。

远程机器不受影响，继续接受路由即可。

## 同一台路由器下，电脑是 direct、设备却是 relay

现象：办公室电脑和设备在同一台路由器下，`tailscale ping` 电脑是 direct，
设备却一直走 DERP；两边 `tailscale netcheck` 的 `MappingVariesByDestIP`
都是 `false`，看起来“环境完全一样”。

先确认出口到底有几层：

```powershell
tracert -d -h 4 223.5.5.5        # Windows
```

```sh
traceroute -n -m 4 223.5.5.5     # 设备上
```

办公室实测是三层：`192.168.110.1`（锐捷）→ `192.168.1.1` →
`100.64.0.1`（运营商 CGNAT）→ `182.136.154.168`。所谓“公网 IP”是运营商的
NAT 出口，设备通过 UPnP 拿到的映射只存在于**第一层**，外面两层没人转发：

```text
182.136.154.168:41642 (portmap)   ← UPnP 给的，公网根本打不进来
182.136.154.168:58894 (stun)      ← 真正能用的
```

验证方法：从异地机器往 41642 连发几个 UDP 包，设备上
`iptables -L INPUT -v -n` 的计数不会涨，说明端点已死。

Tailscale 会把 portmap 端点排在前面试，前十几秒全打在死端口上，所以
`tailscale ping -c 10` 看起来全是 DERP 并报 `direct connection not established`
——这是**超时**，不是结论。给足时间（十几秒到两分钟）后通常仍能打成 direct。

处理：

- 测的时候多给时间：`tailscale ping --until-direct=true -c 20 <设备>`；
- 想更稳就关掉主路由的 UPnP（三层 NAT 下它没有意义，只会广告一个死端口）；
- CGNAT 下**不可能**做静态端口转发，不要再折腾 `UDP 41641 → 设备`；
  自建 DERP（10ms）兜底已经够用。

## 控制台升级提示「内存不足」

旧版本用 `MemAvailable` 判断，这个内核上报偏低（实际空闲 29MB 时只报 18MB），
WiFi 开着时还会更低，于是被误判成“不够 24MB”。

现在升级前会停掉 `tailscaled` / `p910nd` / `wpad` 并 `wifi down`，再按
`MemFree ≥ 14MB` 判断（镜像 11.9MB，留 2MB 余量）。仍然不够就 SSH 刷，
或手动 `wifi down` 后再试。

## 重启后一直显示「启动中」

`tailscaled` 连上后会把 `/etc/resolv.conf` 改成 `100.100.100.100`。如果重启时
这份文件还在、而 tailscaled 自己又没起来，DNS 就是死的：它解析不了
`controlplane.tailscale.com`，会一直卡在 Starting（手动改回 DNS 才会恢复）。

`/etc/init.d/tailscale` 现在启动前会检查：如果 resolv.conf 里只有 100.100.100.100
这种地址，就写回一个真实 DNS（DHCP 下发的，或者默认网关），再拉起 tailscaled。

## 发布出去的网段变成了 `192.168.1.0/24`

救援地址 `192.168.1.2/24` 也是挂在 `br-lan` 上的。如果 `lan_cidr()` 直接取
`ip addr` 的第一行，就可能把救援网段当成 LAN 发布出去（真机踩过：控制面里
多了 `192.168.1.0/24`，和上游路由器的 WAN 网段撞车）。

现在 `lan_cidr()` 优先用 `ubus call network.interface.lan status` 里的
`ipv4-address`（netifd 配置的那一个），拿不到才退回 `ip addr`，并且跳过
`secondary` 的地址。

## 升级后 Tailscale 要重新登录

`/lib/upgrade/keep.d/mt76x8` 会把 `/etc/tailscale` 一起保留，所以正常
sysupgrade 不需要重新授权。用 Breed 刷（会清空配置）或手动 `factoryreset`
之后才需要重新登录。

## 刷机失败 / 变砖怎么办

- **Breed 不会被刷掉**：它在 u-boot 分区（`0x0 ~ 0x30000`），sysupgrade 只写
  firmware 分区（`0x50000 ~ 0xFE0000`）。写入过程中断电最多是"没有可启动
  固件"，Breed 仍在。
- 恢复步骤：断开办公室网线 → 断电 → 按住 Reset 上电 → 电脑直连 →
  浏览器开 `192.168.1.1` → 固件更新 → 选 sysupgrade.bin。
- 极少数情况 Breed 也进不去：需要 USB-TTL 接板上的 `ttyS0`（115200），
  在 u-boot 里重新刷 Breed。
- 所以升级前只需要保证一件事：**供电稳定**。不要用会掉电的插排或劣质线。

## 版本号显示 `x.y.z-ERR-BuildInfo`

Tailscale 的版本戳没有注入时，`tailscaled` 会退回
`<VERSION.txt>-ERR-BuildInfo`。这只影响显示，不影响功能。构建流程现在会注入
`x.y.z-t<commit>`（见 `.github/workflows/build-firmware.yml` 的 `-ldflags`），
并在构建后用 `grep -a` 校验。

如果设备上仍然显示这个后缀，说明刷的是修复前的镜像。
