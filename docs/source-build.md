# 源码构建流水线（可选路线）

现在的主流水线（`.github/workflows/build-firmware.yml`）用的是 **ImageBuilder**：
内核、驱动、工具链都是 ImmortalWrt 官方预编译好的二进制，我们只做「挑包 +
塞文件 + 打包 squashfs」，所以 3~6 分钟就能出固件。

本文档描述另一条路线：**从源码编译**。只有在需要改内核配置、改设备树、改
驱动或裁 busybox 时才值得走这条路。

## 一、为什么源码构建慢、ImageBuilder 快

| | ImageBuilder | 源码构建 |
| --- | --- | --- |
| 内核 | 官方预编译的 `kernel` 包，直接解压 | `make target/linux/compile`，交叉编译整个内核 |
| 工具链 | 不用 | 先编 gcc/binutils/musl（`tools/` + `toolchain/`） |
| 包 | 下载官方 `.ipk` | 每个包现场交叉编译 |
| 冷启动 | 3~6 分钟 | 40~90 分钟（2 核 runner） |
| 热缓存 | — | 20~35 分钟 |
| 磁盘 | ~1.5 GB | 20~30 GB |

所谓「Wrt 几分钟就编译好」，指的就是 ImageBuilder 这条路：它压根不编内核。
真正从零编一个 OpenWrt，即使官方 buildbot 也要几十分钟到几小时。

## 二、三阶段拆分

```text
job 1  tailscale   ~5 min    Go 交叉编译 tailscaled → artifact: tailscaled-mipsle
job 2  kernel      ~35 min   make tools/compile toolchain/compile target/linux/compile
                             → 缓存 dl/ + staging_dir/ + build_dir/
job 3  image       ~10 min   用 job1 的 tailscaled + job2 的产物 make -j image
```

拆分的意义：

- **job 1 与镜像无关**。只在 Tailscale 版本或标签集变化时重编，日常改脚本
  不用等 Go。
- **job 2 是唯一昂贵的一步**。用 `actions/cache` 缓存 `dl/`、`staging_dir/`、
  `build_dir/`，缓存命中时降到 15~25 分钟。
- **job 3 才做打包**，失败重试很便宜。

GitHub 托管 runner 的约束（必须提前处理）：

- `ubuntu-24.04` runner 可用磁盘约 **14 GB**，源码构建需要 **20~30 GB**。
  必须先跑一段 free-disk-space（删 `/usr/share/dotnet`、`/opt/hostedtoolcache`
  里的多余 SDK、Android SDK 等），能腾出 25~30 GB。
- 单仓库 Actions 缓存上限 **10 GB**，`dl/` 约 1 GB、`staging_dir` 约 3 GB、
  `ccache` 1~2 GB，够用但要按 `kernel config 哈希` 分 key，避免互相覆盖。
- 缓存 key 里必须包含 ImmortalWrt tag、目标/子目标、`.config` 哈希，否则
  内核配置一改就用到过期对象，出现莫名其妙的链接错误。

## 三、仓库里已有的材料

```text
configs/target.seed        目标/子目标/设备 + squashfs + ccache 的种子配置
configs/packages.set       要装的包（一行一个）
configs/packages.unset     要剔除的包（一行一个，带 `-`）
dts/mt7628an_oraybox_x1.dts 上游板级 DTS 副本，用于比对/改分区表
patches/                   需要打进源码树的补丁（当前为空）
files/                     运行时覆盖层，和 ImageBuilder 共用同一份
```

`configs/target.seed` + `configs/packages.set` + `configs/packages.unset`
会被展开成完整 `.config`：

```sh
cat configs/target.seed >> .config
for p in $(grep -v '^#' configs/packages.set | grep -v '^$'); do
  echo "CONFIG_PACKAGE_$p=y" >> .config
done
for p in $(grep -v '^#' configs/packages.unset | grep -v '^$'); do
  echo "CONFIG_PACKAGE_${p#-}=n" >> .config
done
make defconfig
```

## 四、值得改的内核选项（收益有限，先量后改）

| 选项 | 作用 | 预期收益 |
| --- | --- | --- |
| `CONFIG_KERNEL_XZ=y` | 内核用 xz 压缩（23.05 默认已是 xz） | 无（已默认） |
| `CONFIG_KERNEL_INITRAMFS` 不用 | 不生成 initramfs | 几十 KB |
| 去掉 `CONFIG_DEBUG_INFO` / `CONFIG_KALLSYMS_ALL` | 去掉调试符号 | 100~200 KB（squashfs 内） |
| 裁 `CONFIG_BUSYBOX_*` applet | 只留用到的命令 | 50~100 KB |
| 去掉不用的文件系统（ext4/f2fs/nfs/cifs） | 少编模块 | 几十 KB |
| `CONFIG_TARGET_ROOTFS_EXT4FS=n` | 只出 squashfs | 打包时间 |

**注意**：squashfs 已经是 xz，内核里的字符串高度重复，重复压缩收益很低。
按经验，内核侧全部优化到位，`sysupgrade.bin` 也就再小 **100~300 KB**。
真正的大头一直是 `tailscaled`（4.6 MiB，占 35%）和 OpenSSL 栈（1.5 MiB），
后者已经在主流水线里通过切 mbedtls 解决。

## 五、什么情况下不要走源码构建

- 只是想「固件更小」→ 先用 ImageBuilder 裁包（已经做到 12 MiB 以下），
  收益/成本比高一个数量级。
- 想换 WiFi 固件/驱动版本 → 直接改 `PACKAGES` 里的 kmod 版本更简单。
- 设备 RAM 只有 64 MB → 源码构建不会改变运行时内存占用，改运行时配置
  （关 LuCI、关 odhcpd、限制 tailscaled 的 `GOMEMLIMIT`）才有用。

## 六、落地顺序（建议）

1. 先让 ImageBuilder 流水线稳定（当前阶段）。
2. 需要改内核时，再加 `kernel` job，只编 `target/linux/compile`，
   镜像仍用 ImageBuilder 产物里的 rootfs 组装 —— 这条路能省掉大半编译时间，
   但要求内核版本和 ImageBuilder 的 `kernel` 包完全一致。
3. 只有确实需要改工具链/包源码时，才做完整的三阶段源码构建。
