# ai-daily-warmup

Auto-wakeups for AI CLIs (e.g., Claude, Codex, Gemini) via local run, given the *5-hour limit window* granted by several AI CLIs.

If you want that window to **open right when you sit down to work in the morning, after lunch, and during the night**, this repo schedules small "warmup" prompts at those three times every day.

---

## Setup

### 1. Edit [config/warmup.config](config/warmup.config):

```bash
# The OS scheduler wakes the runner hourly;
# the runner only sends prompts during `WARMUP_HOURS` in `WARMUP_TIMEZONE`.
WARMUP_PROVIDERS=codex
WARMUP_TIMEZONE=Asia/Hong_Kong
WARMUP_HOURS=8,13,18
WARMUP_PROMPT="Warmup. Don't think, just reply: OK"
```

Use `WARMUP_PROVIDERS=claude,codex,gemini` to warm up more than one CLI.

### 2. Install the daily schedule

macOS or Linux:

```bash
bash ./scripts/install-schedule.sh
```

Windows PowerShell:

```powershell
.\scripts\install-schedule.ps1
```

Done!

### 3. To remove it later (optional):

```bash
bash ./scripts/install-schedule.sh --uninstall
```

```powershell
.\scripts\install-schedule.ps1 -Uninstall
```

## Run once

```bash
bash ./scripts/warmup-local.sh
```

```powershell
.\scripts\warmup-local.ps1
```

## Advanced

All settings live in [config/warmup.config](config/warmup.config). Set `*_PATH` to use a wrapper (CLI with custom running path) instead of the default CLI, and leave `*_CREDENTIAL_PATH` empty if your wrapper manages its own auth:

```bash
CODEX_PATH=/home/user/bin/codex-shadow-home.sh
CODEX_ARGS=--quiet
CODEX_CREDENTIAL_PATH=
```

If you prefer a foreground scheduler instead of installing an OS task:

```bash
bash ./scripts/warmup-local.sh config/warmup.config schedule
```
