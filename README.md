# ai-daily-warmup

Small scheduled warmups for AI CLIs such as Codex, Claude, and Gemini, given the *5-hour limit window* from several AI CLIs. 

If you want that window to **open right when you sit down to work in the morning, at lunch, and during the night**, this repo schedules small "warmup" prompts to trigger calls daily.

## Layout

```text
bin/
  daily-warmup.sh          # macOS/Linux runner
  daily-warmup.ps1         # Windows runner
  install-scheduler.sh     # macOS/Linux scheduler installer
  install-scheduler.ps1    # Windows scheduler installer
config/
  default.env              # provider, schedule, and wrapper settings
```

## Configure

Edit [config/default.env](config/default.env):

```bash
WARMUP_PROVIDERS=codex
WARMUP_TIMEZONE=Asia/Hong_Kong
WARMUP_HOURS=8,13,18
WARMUP_PROMPT="Warmup. Don't think, just reply: OK"
```

Use `WARMUP_PROVIDERS=claude,codex,gemini` to warm up more than one CLI.

## Install The Schedule

macOS or Linux:

```bash
bash ./bin/install-scheduler.sh
```

Windows PowerShell:

```powershell
.\bin\install-scheduler.ps1
```

To remove it later:

```bash
bash ./bin/install-scheduler.sh --uninstall
```

```powershell
.\bin\install-scheduler.ps1 -Uninstall
```

## Run Once

```bash
bash ./bin/daily-warmup.sh
```

```powershell
.\bin\daily-warmup.ps1
```

For a foreground loop instead of an OS scheduler:

```bash
bash ./bin/daily-warmup.sh config/default.env schedule
```
