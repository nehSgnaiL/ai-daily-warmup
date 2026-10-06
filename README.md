# ai-daily-warmup

English · [中文](README_ZH.md)

Send a short Codex warmup request at the hours you choose. Give each account its own schedule, command, and log.

## Get started

Install Codex and sign in, then clone this project:

```bash
git clone https://github.com/nehSgnaiL/ai-daily-warmup.git
cd ai-daily-warmup
```

Create `local/local.env` with your preferred hours:

```ini
WARMUP_TIMEZONE=Asia/Hong_Kong
WARMUP_HOURS=8,13,18
```

Create the `local/` directory first if needed. It holds your personal settings and is ignored by Git.

Install the scheduled task from the project directory:

| System | Command | Scheduler |
| --- | --- | --- |
| Linux | `bash ./bin/install-scheduler.sh` | systemd user timer |
| macOS | `bash ./bin/install-scheduler.sh` | LaunchAgent |
| Windows | `.\bin\install-scheduler.ps1` | Task Scheduler |

The task checks every ten minutes. It sends the prompt when a scheduled slot is eligible and records the result in `logs/warmup.log`.

## How settings fit together

Settings load in this order; each file overrides values from the previous one:

```text
config/default.env → local/local.env → local/accounts/<account>.env
```

[config/default.env](config/default.env) contains the shared defaults. Use `local/local.env` for your machine and account profiles for individual schedules.

The runner decides when to call a command and records its result. Your local command handles account selection and authentication.

| Setting | Purpose |
| --- | --- |
| `CODEX_PATH` | Executable name or absolute path; defaults to `codex` |
| `CODEX_ARGS` | CLI flags passed to the command |
| `CODEX_ENV_FILE` | Optional file of environment variables for the command |
| `CODEX_CREDENTIAL_PATH` | Credential file to check before calling; leave empty when the command handles it |
| `CODEX_MODEL` | Optional model |
| `CODEX_WORKDIR` | Working directory; empty uses a temporary directory |

## Stagger two accounts

The Bash runner supports multiple account profiles. The PowerShell runner uses one configuration.

Add the accounts to `local/local.env`:

```ini
WARMUP_ACCOUNTS=user-a,user-b
```

Create `local/accounts/user-a.env`:

```ini
CODEX_PATH=/absolute/path/to/repo/local/user-a-command
CODEX_CREDENTIAL_PATH=
WARMUP_HOURS=8,13,18,23
```

Create `local/accounts/user-b.env`:

```ini
CODEX_PATH=/absolute/path/to/repo/local/user-b-command
CODEX_CREDENTIAL_PATH=
WARMUP_HOURS=10,15,20
```

Replace these paths with your executable commands. Each command selects its account and accepts Codex CLI arguments. The runner also passes the profile label as `WARMUP_ACCOUNT`.

To load environment variables for a command, add this to its profile:

```ini
CODEX_ENV_FILE=/absolute/path/to/repo/local/accounts/user-a.vars
```

Environment files use one `NAME=value` per line. Single or double quotes around a value are removed; the remaining value is passed literally. Put comments on their own lines. Keep credential files in `local/` with mode `600`.

Accounts run in list order with separate logs and state:

```text
logs/warmup.log.user-a
logs/warmup.state.user-a
logs/warmup.log.user-b
logs/warmup.state.user-b
```

A failed account is retried at the next eligible check. Successful accounts wait for their next slot.

## Understand the timing

Each configured hour starts a slot. By default, the runner allows 60 minutes for a late run and waits at least 302 minutes after the previous successful call finishes.

For example, the 13:00 slot runs between 13:00 and 13:59. Once that window ends, the runner waits for the next slot.

With ten-minute checks and quick successful calls, the two profiles above produce this simulated schedule:

| Account | Configured hours | Call times |
| --- | --- | --- |
| user-a | `8,13,18,23` | 08:00, 13:10, 18:20, 23:30 |
| user-b | `10,15,20` | 10:00, 15:10, 20:20 |

The later calls shift because five hours is shorter than the 302-minute minimum. The longer overnight gap lets the next day start at the first configured hour again.

Tune the timing in your local settings or account profile:

| Setting | Default | Purpose |
| --- | --- | --- |
| `WARMUP_TIMEZONE` | `Asia/Hong_Kong` | Time zone for the schedule |
| `WARMUP_HOURS` | `8,13,18` | Slot start hours, in 24-hour format |
| `WARMUP_MIN_WINDOW_MINUTES` | `302` | Minimum gap after a successful call |
| `WARMUP_SLOT_CATCHUP_MINUTES` | `60` | Time allowed for a late run |

Long calls or retries can push the next eligible check past a slot's end. Extend its catch-up window or space the hours farther apart if you want more room for delays. A window that crosses midnight stays associated with its original date.

To change how often the system scheduler checks, set `WARMUP_SCHEDULER_INTERVAL_MINUTES` in `local/local.env` and rerun the install command. Changes to account hours take effect at the next scheduled check.

## Run and inspect

Run one schedule check:

```bash
bash ./bin/daily-warmup.sh
```

View an account's recent results:

```bash
tail -n 20 logs/warmup.log.user-a
```

Logs contain the timestamp, event, result, exit code, duration, and explanation. Each log keeps the latest 200 rows by default.

On Linux, check the timer:

```bash
systemctl --user status ai-daily-warmup.timer
```

For a foreground process, run:

```bash
bash ./bin/daily-warmup.sh config/default.env schedule
```

It checks every 60 seconds and reloads account profiles each time. Restart it after changing shared settings. Both manual and foreground checks follow the configured schedule.

## Remove the scheduled task

```bash
bash ./bin/install-scheduler.sh --uninstall
```

On Windows:

```powershell
.\bin\install-scheduler.ps1 -Uninstall
```

Your local settings and logs stay in place.

## Development

Run the checks with Python 3:

```bash
python3 tests/check_warmup.py
```

The checks use temporary profiles and simulated commands. They cover configuration loading, account isolation, retries, two days of scheduling, midnight boundaries, and scheduler installation.
