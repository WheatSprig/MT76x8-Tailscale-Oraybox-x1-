# USB 打印共享

USB-A 口接打印机，`p910nd` 把 `/dev/usb/lp0` 映射成 TCP 9100。

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
地址 `<设备 IP>`，端口 **9100**（RAW），驱动选打印机自带驱动。

**macOS / Linux**：

```sh
lpadmin -p office -E -v socket://<设备 IP>:9100 -m everywhere
```

### RAW 9100 到底是谁的能力

- **打印机不认识 9100**。USB 打印机没有网络协议栈，它只会通过 USB 收字节。
- **9100 端口是路由器上的 `p910nd` 提供的**：它监听 TCP 9100，把收到的字节
  原样写进 `/dev/usb/lp0`。
- **RAW 是客户端发送方式**：Windows 的「Standard TCP/IP Port」里可以选择
  `Raw` 或 `LPR`。选 `Raw` + 9100 就是「把驱动输出的字节直接塞进 TCP 连接」，
  不加任何 LPR 控制字符。`p910nd` 只支持 RAW，不支持 LPR（515）。
- Windows 10/11 **原生支持**这种端口，不需要装任何第三方软件，也不用在
  打印机上做任何设置。PowerShell 一行就能建：

  ```powershell
  Add-PrinterPort -Name "IP_<设备 IP>" -PrinterHostAddress "<设备 IP>" -PortNumber 9100
  ```

  注意：HP 某些驱动自带「HP Standard TCP/IP Port」端口监视器，会做 SNMP
  状态查询或双向握手，这类端口在 9100 上容易报「打印机无响应」；改用
  Microsoft 自带的 Standard TCP/IP Port 即可。

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

正常会看到类似 `usblp0: USB Bidirectional printer dev 3 if 0 alt 0`。

### HP P1008 这类「主机型」打印机

HP LaserJet P1005/P1006/P1007/**P1008**/P1505 属于 GDI/主机型打印机：
打印机本身只会解释 **ZJS（ZjStream）** 光栅数据，不支持 PCL/PostScript，
也没有板载字体。

`p910nd` 只是把 TCP 9100 收到的字节原样写到 `/dev/usb/lp0`，路由器不参与
解释，所以能不能打印取决于**客户端驱动**：

| 客户端 | 情况 |
| --- | --- |
| Windows | 装 HP 的 P1008 驱动，端口选 Standard TCP/IP + RAW 9100，一般可用；部分驱动要在端口属性里**关闭双向支持 / SNMP 状态**，否则会卡在「打印机无响应」 |
| Linux | 客户端需要 `foo2zjs`（自带 P1008 的 ZJS 驱动，可能还会在任务开头上传固件），路由器侧不用装任何驱动 |
| macOS | 新系统没有 P1008 官方驱动，基本用不了；老系统配合 foo2zjs 才有机会 |

判断依据很简单：**只要客户端能在这台打印机直连 USB 时打印，改成
`socket://<设备 IP>:9100` 后通常也能打印**，因为发出去的字节流完全一样。

不能打印的典型情况：

- 驱动在提交任务前要做双向状态握手，而 9100 端口是单向的；
- 打印机是纯 GDI 且客户端没有对应驱动（想发 PCL/PS 给它，它看不懂）。

排查时可以在电脑上直接灌一段原始数据测试链路（字节能到打印机就说明
USB 和 9100 都通，问题在驱动格式）：

```sh
# Linux / macOS
printf 'test\n' | nc <设备 IP> 9100
```

```powershell
# Windows PowerShell
$c = New-Object Net.Sockets.TcpClient('<设备 IP>', 9100)
$s = $c.GetStream(); $b = [Text.Encoding]::ASCII.GetBytes("test`r`n")
$s.Write($b, 0, $b.Length); $s.Flush(); $c.Close()
```

> 结论：**USB 硬件和固件层面支持 P1008**（标准 USB 打印类，`usblp` 能认），
> 路由器也搬得动；真正的限制在客户端驱动是否能生成 ZJS 数据。
