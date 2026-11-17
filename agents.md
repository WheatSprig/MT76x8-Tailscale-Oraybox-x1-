---
project: MT76x8 Tailscale Firmware（OrayBox X1）
description: 16MB Flash / 64MB RAM 的 ImmortalWrt 固件，把 OrayBox X1 做成办公室的 Tailscale 子网路由器 + USB 打印共享盒子。
stack: ImmortalWrt 23.05.4 ImageBuilder、Go 1.27 交叉编译的 tailscaled、BusyBox sh CGI
---

# 仓库规范

写给要改这个仓库的人和自动化助手：固件边界、脚本约束、提交与任务分层。
动某块之前先读对应章节；**本文与代码不符时以代码为准，并顺手改掉本文**。

<!--
English summary: engineering rules for this repo — 1 repo boundaries, 2 hard constraints
(15 MiB limit, LF scripts, no bash/jq/curl/timeout on device), 3 firmware code conventions,
4 commit rules (中文描述), 5 task levels, 6 branch names, 7 .agents workspace, 8 acceptance,
9 forbidden patterns.
-->

## 1. 仓库边界

| 目录 | 归属 | 说明 |
| --- | --- | --- |
| `files/` | **会进固件** | 覆盖到 rootfs 的文件，改这里就是改固件 |
| `.github/workflows/` | 构建 | push / tag / 手动触发，产物是 sysupgrade.bin |
| `configs/` `dts/` `patches/` | 材料 | 源码构建用，不打进镜像 |
| `docs/` | 文档 | 详细说明，README 只放入口 |
| `.agents/` | 本地工作区 | 计划与在途任务，**只有 README 纳版** |

判断"这个改动会不会进固件"只看一件事：**文件在不在 `files/` 下**。
所以不要为了"先放这儿"把临时脚本塞进 `files/`。

## 2. 硬约束

- **固件必须小于 15,728,640 字节**（`0x00f00000`）。CI 超限直接失败；
  加包前先看 `docs/build.md` 的体积账。
- **不要加回 LuCI**：`default-settings` 会把 luci 依赖拉回来，negate 列表见工作流。
- **不要回到 OpenSSL**：`libopenssl3` 一个就 1.5 MiB，用 mbedTLS 栈。
- **脚本只用 BusyBox sh**：设备上没有 bash、jq、curl、perl、python，
  **也没有 `timeout`**（限时要用「后台进程 + sleep kill」的看门狗）。
- **换行符**：`.sh`、`uci-defaults` 下无扩展名的脚本一律 UTF-8 无 BOM + LF；
  由 `.gitattributes` 里的 `files/** text eol=lf` 保证。
- **不要把密码、哈希、token 写进仓库**：root 密码哈希走 secret
  `ROOT_PASSWORD_HASH`，控制台密码在设备上生成。
- **CGI 请求路径里不许同步执行 `tailscale` CLI**：它是 22 MB 的 Go 程序，
  在 580MHz 上启动一次十几秒，会把 uhttpd 的请求槽位占死（这是真实事故）。
- 前端不引 CDN、不引外部字体。

## 3. 固件里的代码

- `files/etc/uci-defaults/` 按文件名顺序执行，**只执行一次**：
  `96-web-auth`（控制台密码）→ `97-root-password` → `98-lan-ip` → `99-tailscale-setup`。
  新增脚本要编号插队，不要改已有编号的含义。
- `files/lib/upgrade/keep.d/mt76x8` 决定 sysupgrade 时保留什么
  （现在是 `/etc/tailscale` 和 `/etc/tsui.passwd`）。改这里等于改升级语义。
- `files/www/cgi-bin/api.sh` 是**唯一**的读写接口：
  - 读：`?op=status|logs|diag`；写：POST `op=<动作>`；
  - 加功能 = 加一个 `case` 分支 + 页面加一张卡片，不要新建第二个 CGI；
  - 所有可能阻塞的命令都要过 `run_limited`；
  - 输入必须校验（网段、端口、设备路径），输出必须 `json_escape`。
- `files/etc/uci-defaults/99-tailscale-setup` 生成 `/etc/rc.local`：
  状态缓存（`/tmp/ts.status`）+ 发布网段 + `tailscale serve`。
  **状态采集不要走 CLI**：AuthURL 从 `logread` 读，Running 看 `tailscale0` 有没有地址。
- `files/etc/init.d/tailscale` 负责 `modprobe tun`、`/dev/net/tun` 和 Go 内存参数；
  改 GOGC/GOMEMLIMIT 前先想清楚 64MB 的账。

## 4. 提交规范

- 提交信息用**约定式提交**：`<类型>[(范围)][!]: <描述>`，空一行写正文。
- **描述用中文**，一句话说清改了什么，不以句号结尾。仓库历史里大部分是英文，
  新提交一律中文 —— 中文读起来快，也避免同一仓库两种语气。
- **类型只能用这些**：`feat` `fix` `refactor` `perf` `style` `docs` `test`
  `build` `ci` `chore` `revert`。不要自造（`update`、`wip`、`misc` 都不行）。
- **范围**可选，写落在哪一块：`fix(console)`、`feat(printing)`、`ci(build)`。
- **破坏性变更**用 `!`（`feat!:`）或脚注 `BREAKING CHANGE: 说明`，
  典型场景是改了 sysupgrade 保留项、分区布局、控制台密码存储格式。
- **正文写动机**：为什么改、不这么改会怎样；不要只复述 diff。
- **一次提交只做一件事**：脚本修复和 README 改写不要混在一起；
  一条提交里的每个文件都应服务于同一句描述。
- **不要写计划代号**（"阶段 3"、"任务 B"、"按计划第 2 步"）：计划不落仓库，
  这些编号在历史里是空指针。
- **不要署名类 trailer**（`Co-authored-by` 之类），提交信息只记录改动本身。
- 示例：

  ```text
  fix(console): 状态采集改为读日志和 tailscale0，避免 CLI 拖死 uhttpd

  tailscale 是 22MB 的 Go 程序，580MHz 上启动一次要十几秒。之前每次请求都同步
  执行 status，看门狗 8 秒就把它杀掉，AuthURL 永远读不到，几个并发请求就把
  uhttpd 的槽位占满。现在 AuthURL 从 logread 取，Running 看接口有没有地址。
  ```

## 5. 任务分层

接手任务后的**第一个动作**是定级，并把级别写进 `.agents/todo.md` 对应那一条。
**允许升级，禁止悄悄降级**：范围变大就显式改级并报备。

| 级别 | 判据 | 流程 |
| --- | --- | --- |
| **轻量切片** | 单点修复、单个脚本、文档；不碰 `files/` 的结构性改动 | 单闸门：定级 → 分支 → 提交 → 自检，一次回复内完成 |
| **跨层切片** | 一个功能跨 `files/` + 工作流/文档，或涉及控制台接口变更 | 双闸门：先报「任务/级别/分支/计划」并停下，等确认再动手 |
| **大目标** | 换内核、改分区、重做 UI、WiFi 模式、源码构建流水线 | 双闸门 + 汇聚分支；未整体闭环前不合入 `main` |

- **合并权在用户**：无论门禁是否全绿，合入 `main` 必须由用户明确说
  「可以合了 / 收尾」；在此之前停在分支上报备。
- **在途任务不落仓库**：计划、调研、待办一律写 `.agents/`，见第 7 节。

## 6. 分支命名

`<类型>/<语义>`，类型取自第 4 节，例如 `fix/console-hang`、`feat/printer-page`。
不要自造 `dev/`、`wip/`；跨两件不相干的事就先拆，再命名。
大目标的汇聚分支用 `feature/<语义>`，子分支合回汇聚分支，不直接进 `main`。

## 7. `.agents` 工作区

- `.agents/todo.md`：在途任务列表，一条任务一个六行块
  （任务 / 级别 / 分支 / 计划 / 当前单元 / Blocker）。
- `.agents/plans/`：跨层切片与大目标的计划全文。
- `.agents/scratch/<task-slug>/`：执行中的临时产物，一条任务一个目录。
- `.agents/notes/`：跨任务共享的备忘，入口 `INDEX.md`。
- `.agents/archive/` + `ARCHIVE.md`：收尾后归档。
- **除 `README.md` 外一律不进版本库**（`.gitignore` 已按白名单处理）。

## 8. 验收

每次改动至少跑：

```sh
# 1. 脚本语法（BusyBox sh 兼容）
sh -n files/www/cgi-bin/api.sh
sh -n files/www/cgi-bin/ts-login.sh
sh -n files/etc/uci-defaults/99-tailscale-setup

# 2. 工作流语法
python3 -c "import yaml;yaml.safe_load(open('.github/workflows/build-firmware.yml'))"
```

涉及 `files/` 的改动，还要：

- CI 构建成功，`sysupgrade.bin` ≤ 15,728,640 字节；
- 日志里 `FILES 校验通过` 且没有 `luci-base` / `libopenssl3`；
- 真机验证项（能刷就刷）：
  - `uci get network.lan.proto` 是 `dhcp`；
  - 控制台能登录、状态不转圈；
  - `ps w | grep tailscaled` 只有一个进程，`logread | grep -c panic` 不增长；
  - 打印机插上后 `/dev/usb/lp0` 存在、9100 在监听。

## 9. 不要做的事

- 不要为了省体积删 USB 内核模块（打印机要用）。
- 不要在 `files/` 里放超过几 MB 的二进制。
- 不要在 CGI 里 `eval` 用户输入。
- 不要给控制台加需要编译的前端（React/Vue/打包器）。
- 不要把 `tailscale up` 写成同步阻塞调用；永远后台 + 锁。
- 不要相信"设备上应该有 `timeout`/`jq`/`bash`"，先 `ls /bin /usr/bin` 确认。
- 不要把固件构建产物（`.bin`）提交进仓库。
