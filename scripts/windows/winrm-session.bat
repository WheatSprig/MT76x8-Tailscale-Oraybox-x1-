@echo off
chcp 65001 >nul
setlocal EnableExtensions

rem ============================================================
rem  临时开启 WinRM（PowerShell Remoting）
rem  - 运行：启动 WinRM，只放行 Tailscale 网段与本地子网
rem  - 结束时：按任意键停止 WinRM，并恢复为“手动启动”
rem  - 已在运行时再次运行：直接走停止流程
rem ============================================================

net session >nul 2>&1
if errorlevel 1 (
    echo 需要管理员权限，正在提权...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

sc query WinRM | find /i "RUNNING" >nul
if not errorlevel 1 goto stop

echo == 启动 WinRM（仅 Tailscale 与本地子网可访问）
powershell -NoProfile -ExecutionPolicy Bypass -Command "Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null"
if errorlevel 1 (
    echo    Enable-PSRemoting 失败，请检查系统策略或安全软件
    pause
    exit /b 1
)

sc config WinRM start= demand >nul 2>&1
net start WinRM >nul 2>&1

rem 把 Tailscale 网卡设为“专用网络”，让系统自带规则也能生效
powershell -NoProfile -Command "$p=Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias -eq 'Tailscale' }; if ($p) { $p | Set-NetConnectionProfile -NetworkCategory Private }" >nul 2>&1

rem 自建一条语言无关的规则，限定来源网段
netsh advfirewall firewall delete rule name="WinRM-Tailscale" >nul 2>&1
netsh advfirewall firewall add rule name="WinRM-Tailscale" dir=in action=allow protocol=TCP localport=5985,5986 remoteip=100.64.0.0/10,localsubnet >nul
if errorlevel 1 (
    echo    防火墙规则创建失败
) else (
    echo    防火墙：仅 100.64.0.0/10 与本地子网可访问 5985/5986
)

for /f "usebackq delims=" %%i in (`powershell -NoProfile -Command "$ip=(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -like '100.*' } | Select-Object -First 1).IPAddress; if ($ip) { $ip }"`) do set "TSIP=%%i"
if defined TSIP (
    echo    连接：Enter-PSSession -ComputerName %TSIP% -Credential ^(Get-Credential^)
) else (
    echo    未找到 Tailscale 地址，请先启动 Tailscale
)

echo.
echo 保持此窗口打开。按任意键停止 WinRM。
echo （直接点窗口右上角关闭可能来不及清理；再运行一次本脚本会先停掉它）
echo.
pause >nul

:stop
echo == 停止 WinRM
net stop WinRM >nul 2>&1
sc config WinRM start= demand >nul 2>&1
netsh advfirewall firewall delete rule name="WinRM-Tailscale" >nul 2>&1
echo    已停止，开机不会自启
timeout /t 2 >nul
exit /b 0
