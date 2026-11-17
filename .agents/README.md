# `.agents/` 工作区

这里放**在途任务**的计划、进度和临时产物。除本文件外全部不进版本库
（`.gitignore` 按白名单放行）。

## 目录

```text
.agents/
├── README.md           # 本文件（唯一纳版）
├── todo.md             # 在途任务列表
├── plans/              # 跨层切片 / 大目标的计划全文
├── scratch/<task>/     # 一条任务的临时产物（日志、抓包、草稿）
├── notes/              # 跨任务共享备忘，入口 INDEX.md
├── archive/            # 已收尾任务的计划
└── ARCHIVE.md          # 归档索引
```

## 在途任务块

`todo.md` 里一条任务固定六行，写完再动手：

```text
## <一句话任务名>
- 级别: 轻量切片 | 跨层切片 | 大目标
- 分支: fix/console-hang
- 计划: .agents/plans/20261117_console-hang.md（轻量切片可写「无」）
- 当前单元: 第 2 步：把状态采集改成读 logread
- Blocker: 无
```

## 对应关系

**一条在途任务 ⟷ 一个分支 ⟷ 一个 `scratch/<task>/`**。

- 开始任务、切分支、完成一个单元、准备合并时都要更新 `todo.md`；
- 合并完成后一次做完三件事：删掉这一块、删掉 `scratch/<task>/`、
  计划移进 `archive/` 并更新 `ARCHIVE.md`；
- 拆开做会留下孤儿目录——下一个人分不清哪条任务还在飞。

## 归档命名

`archive/YYYYMMDD_<task-slug>.md`，与 `scratch/` 的目录名一致，
这样从归档还能找回当初的临时产物（如果没删）。
