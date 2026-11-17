# 硬件：LED、Reset 与 Breed

## LED、Reset 按键与 Breed

- **LED**：初始化脚本会删除原有 LED 配置，为每个 `/sys/class/leds/*` 写入
  `trigger=none`、`default=0`，因此开机后所有指示灯保持关闭。
- **Reset 按键**：保留 OpenWrt 默认 `/etc/rc.button/reset` 行为——
  短按重启；长按约 5 秒执行 `factoryreset -y` 并重启。
- **Breed**：设备带 Breed 引导。建议刷机前在 Breed Web 控制台备份
  `factory`/`bdinfo`/`reserve` 等分区；变砖时可断电按住 Reset 再上电进入
  Breed 恢复。日常升级也可在 OpenWrt 内直接刷 sysupgrade。
