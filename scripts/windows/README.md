# Windows 远程管理小工具

## `winrm-session.bat`

双击运行（会自己请求管理员权限）：

1. 启用 WinRM（第一次运行会配置监听器）；
2. 服务设为「手动」，只在本次运行期间启动；
3. 防火墙只放行 `100.64.0.0/10`（Tailscale）和本地子网到 5985/5986；
4. 窗口保持打开，**按任意键停止 WinRM** 并恢复为手动启动。

已有的 WinRM 在运行时再运行一次，会直接走「停止」流程。

### 从另一台电脑连接

```powershell
# 工作组机器需要先信任对方（一次性）
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "100.70.0.11" -Force

# 交互式会话
Enter-PSSession -ComputerName 100.70.0.11 -Credential (Get-Credential)

# 执行单条命令
Invoke-Command -ComputerName 100.70.0.11 -Credential (Get-Credential) `
  -ScriptBlock { Get-Process | Sort-Object CPU -Descending | Select-Object -First 5 }
```

### 注意

- 账户必须有密码，Windows 不允许空密码网络登录；
- 微软账户用 `MicrosoftAccount\you@example.com`，本地账户用 `.\用户名`；
- 点窗口右上角关闭可能来不及执行清理：服务是「手动」启动，重启后不会自启；
  再运行一次脚本即可停掉；
- 不要把 5985/5986 映射到公网，只走 Tailscale 或局域网。

### 为什么 `.bat` 用 GBK 而不是 UTF-8 + BOM

`.ps1` 适合 UTF-8（带 BOM），但 `.bat` 相反：**cmd.exe 按系统代码页解析批处理
文件**，中文 Windows 是 936（GBK）。

- UTF-8 带 BOM：BOM 的三个字节会被当成第一行的一部分，出现
  `'锘緻echo off' 不是内部或外部命令`；
- UTF-8 不带 BOM：中文被按 GBK 解码，命令会被拆成乱码片段；
- 文件内写 `chcp 65001` 也救不了：解析器已经按旧代码页读过前面的行了。

实测（本机 ACP/OEMCP 均为 936）：

```text
UTF-8 no BOM + chcp 65001 -> 首行乱码、部分命令被拆断
UTF-8 with BOM            -> '锘緻echo off' 不是内部或外部命令
GBK + CRLF                -> 中文与命令全部正常
```

所以这个 `.bat` 保存为 **GBK + CRLF、无 BOM**。用编辑器改它时记得选
「ANSI / GB18030」而不是 UTF-8。仓库里 `.gitattributes` 把 `*.bat` 钉成
CRLF，避免检出后换行符被改坏。

## 更喜欢 shell？

WinRM 适合跑 PowerShell 脚本；如果只是想要一个命令行，装 OpenSSH Server
更省事（管理员 PowerShell）：

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Set-Service sshd -StartupType Automatic
Start-Service sshd
New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server' `
  -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -Profile Any
```

然后 `ssh 用户名@100.70.0.11`。
