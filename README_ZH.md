# ai-daily-warmup

[English](README.md) · 中文

我们都遇到过：正沉浸在工作中，进展飞快，突然——AI 的使用额度到顶了。思路被打断，偏偏在最需要工具的时候，被迫来一场“调整心态”的休息。

如果你希望额度窗口在早上坐下来工作、午间继续推进，以及晚上开工时开启，这个项目会每天定时发送简短的“预热”提示，触发调用。

## 开始使用

安装 Codex 并完成登录，然后下载项目：

```bash
git clone https://github.com/nehSgnaiL/ai-daily-warmup.git
cd ai-daily-warmup
```

创建 `local/local.env`，写入自己的时段：

```ini
WARMUP_TIMEZONE=Asia/Hong_Kong
WARMUP_HOURS=8,13,18
```

如果还没有 `local/` 目录，先创建它。这个目录存放个人设置，已被 Git 忽略。

在项目目录安装定时任务：

| 系统 | 命令 | 调度器 |
| --- | --- | --- |
| Linux | `bash ./bin/install-scheduler.sh` | systemd 用户定时器 |
| macOS | `bash ./bin/install-scheduler.sh` | LaunchAgent |
| Windows | `.\bin\install-scheduler.ps1` | 任务计划程序 |

任务默认每十分钟检查一次。符合预热条件时，程序发送提示，并把结果写入 `logs/warmup.log`。

## 配置如何生效

配置按以下顺序加载，后面的文件覆盖前面的同名设置：

```text
config/default.env → local/local.env → local/accounts/<account>.env
```

[config/default.env](config/default.env) 提供通用默认值。机器上的共享设置放在 `local/local.env`，各账号的时段放在各自的配置文件中。

运行脚本负责判断调用时间、执行命令和记录结果。本地命令负责选择账号和完成认证。

| 设置 | 用途 |
| --- | --- |
| `CODEX_PATH` | 可执行命令名或绝对路径，默认是 `codex` |
| `CODEX_ARGS` | 传给命令的 CLI 参数 |
| `CODEX_ENV_FILE` | 可选的命令环境变量文件 |
| `CODEX_CREDENTIAL_PATH` | 调用前检查的凭据文件；由命令管理时留空 |
| `CODEX_MODEL` | 可选的模型 |
| `CODEX_WORKDIR` | 工作目录；留空使用临时目录 |

## 错开两个账号的时段

Bash runner 支持多个账号配置，PowerShell runner 使用单份配置。

在 `local/local.env` 中启用账号：

```ini
WARMUP_ACCOUNTS=user-a,user-b
```

创建 `local/accounts/user-a.env`：

```ini
CODEX_PATH=/absolute/path/to/repo/local/user-a-command
CODEX_CREDENTIAL_PATH=
WARMUP_HOURS=8,13,18,23
```

创建 `local/accounts/user-b.env`：

```ini
CODEX_PATH=/absolute/path/to/repo/local/user-b-command
CODEX_CREDENTIAL_PATH=
WARMUP_HOURS=10,15,20
```

把示例路径换成自己的可执行命令。每个命令选择对应账号，并接受 Codex CLI 参数。运行脚本还会通过 `WARMUP_ACCOUNT` 环境变量传入当前配置的标签。

如果命令需要额外的环境变量，在账号配置中加入：

```ini
CODEX_ENV_FILE=/absolute/path/to/repo/local/accounts/user-a.vars
```

环境文件每行采用 `NAME=value` 格式。值两端的单引号或双引号会被去掉，其余内容按原文传递。注释放在独立行。含凭据的文件保存在 `local/`，权限设为 `600`。

账号按列表顺序执行，分别记录日志和调度状态：

```text
logs/warmup.log.user-a
logs/warmup.state.user-a
logs/warmup.log.user-b
logs/warmup.state.user-b
```

失败账号会在下次符合条件的检查中重试。成功账号等待自己的下一档。

## 理解实际调用时间

配置中的每个小时是一档的起点。默认允许在起点后的 60 分钟内补跑，并要求距上次成功调用完成至少间隔 302 分钟。

例如，13 点这一档允许在 13:00 至 13:59 调用。窗口结束后，程序等待下一档。

按每十分钟检查、调用迅速成功的条件模拟，上面的两份配置会得到：

| 账号 | 配置时段 | 调用时间 |
| --- | --- | --- |
| user-a | `8,13,18,23` | 08:00、13:10、18:20、23:30 |
| user-b | `10,15,20` | 10:00、15:10、20:20 |

后续调用会延后，是因为五小时不足 302 分钟。夜间间隔较长，次日可以重新从首档的起点开始。

在本地共享配置或账号配置中调整时间规则：

| 设置 | 默认值 | 用途 |
| --- | --- | --- |
| `WARMUP_TIMEZONE` | `Asia/Hong_Kong` | 调度使用的时区 |
| `WARMUP_HOURS` | `8,13,18` | 每档的起始小时，采用 24 小时制 |
| `WARMUP_MIN_WINDOW_MINUTES` | `302` | 成功调用后的最小间隔 |
| `WARMUP_SLOT_CATCHUP_MINUTES` | `60` | 允许延后补跑的时间 |

调用耗时或重试可能让下一次符合条件的检查超过档位结束时间。需要更多延迟余量时，可以延长补跑窗口，或拉开时段。跨午夜的补跑窗口仍归属原来的日期。

要调整系统调度器的检查频率，在 `local/local.env` 中设置 `WARMUP_SCHEDULER_INTERVAL_MINUTES`，然后重新运行安装命令。账号时段的修改会在下次定时检查时生效。

## 运行与查看结果

手动检查一次调度条件：

```bash
bash ./bin/daily-warmup.sh
```

查看某个账号最近的结果：

```bash
tail -n 20 logs/warmup.log.user-a
```

日志包含时间、事件、结果、退出码、耗时和说明。每份日志默认保留最近 200 行。

在 Linux 上查看定时器：

```bash
systemctl --user status ai-daily-warmup.timer
```

需要在前台持续运行时，使用：

```bash
bash ./bin/daily-warmup.sh config/default.env schedule
```

前台模式每 60 秒检查一次，每次重新读取账号配置。修改共享设置后重启前台进程。手动检查和前台检查都会遵守已配置的调度规则。

## 移除定时任务

```bash
bash ./bin/install-scheduler.sh --uninstall
```

Windows 使用：

```powershell
.\bin\install-scheduler.ps1 -Uninstall
```

本地设置和日志会继续保留。

## 开发验证

使用 Python 3 运行检查：

```bash
python3 tests/check_warmup.py
```

检查使用临时配置和模拟命令，覆盖配置加载、账号隔离、失败重试、连续两天调度、午夜边界和定时器安装。
