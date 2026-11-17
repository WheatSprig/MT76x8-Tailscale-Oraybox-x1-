# 补丁目录（源码构建用）

这里存放需要打进 ImmortalWrt/OpenWrt 源码树的改动。**当前目录是空的**，
现有的 ImageBuilder 流水线不需要任何补丁。

## 目录约定

源码构建脚本（`docs/source-build.md`）按下面的规则应用补丁：

```text
patches/
├── 0000-<说明>.patch          # 直接 apply 到源码根目录（git apply -p1）
└── target/linux/ramips/...    # 按源码树相对路径自动放置
```

`apply-patches.sh` 的约定是：凡是路径里带 `/` 的补丁文件，按
`patches/<相对路径>` 拷进源码树对应位置；文件名以数字开头的 `.patch` 用
`git apply` 应用后删除。

## 已经确认不需要补丁的部分

| 需求 | 结论 | 依据 |
| --- | --- | --- |
| 设备树 | 上游自带 `target/linux/ramips/dts/mt7628an_oraybox_x1.dts` | 见 `dts/` 目录的副本，2089 字节，分区表与实测 `mtd3 = 0x00f00000` 一致 |
| USB Host | `mt7628an.dtsi` 中 `usbphy`/`ehci`/`ohci` 默认启用，本板 DTS 未禁用 | 官方支持提交写明 `1x USB Type-A 2.0 Host Port`；无需改 DTS 或重编内核 |
| USB 打印 | `kmod-usb-printer` + `p910nd` | 纯用户态 + 一个 8 KiB 内核模块，ImageBuilder 可直接装 |
| LED 熄灭 | 运行时 uci 配置（`99-tailscale-setup`） | 不改 DTS，避免重编内核 |
| Reset 键 | 上游 DTS + 默认 `/etc/rc.button/reset` | `KEY_RESTART`，短按重启/长按恢复 |

## 什么情况下才需要在这里加补丁

1. **要改分区表**（例如把 `reserve` 那 64 KiB 并进 firmware）→ 改
   `mt7628an_oraybox_x1.dts`，放 `patches/target/linux/ramips/dts/`。
2. **要关掉某个内核驱动/文件系统** → 优先用 `configs/kernel.fragment`
   （`CONFIG_...=n`），只有配置项不存在时才改源码。
3. **要给 `p910nd` 加双向/热插拔修复** → 放 `patches/package/...`。
4. **要改 busybox applet 列表** → 直接改 `.config` 里的
   `CONFIG_BUSYBOX_*`，不需要补丁。

## 补丁的验收标准

每个补丁必须满足：

- `git apply --check` 在对应的 ImmortalWrt 23.05.4 tag 上通过；
- 补丁文件名能说明改了什么，且正文带 `Signed-off-by`；
- 在 `docs/source-build.md` 的「变更记录」里写明动机和验证过的构建号。
