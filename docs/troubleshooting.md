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

## 升级后 Tailscale 要重新登录

`/lib/upgrade/keep.d/mt76x8` 会把 `/etc/tailscale` 一起保留，所以正常
sysupgrade 不需要重新授权。用 Breed 刷（会清空配置）或手动 `factoryreset`
之后才需要重新登录。
