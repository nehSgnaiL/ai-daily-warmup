## ai-daily-warmup

> We've all been there: you're deep in the zone, making massive progress, and suddenly—bam. You hit your AI's usage cap. Your momentum is shattered, and you're forced into a mandatory "mindset break" right when you need your tools the most.

If you want that limit window to **open right when you sit down to work in the morning, at lunch, and during the night**, this repo schedules small "warmup" prompts to trigger calls daily.

---

### How to use?

#### 1. Clone this Repo

```bash
git clone https://github.com/nehSgnaiL/ai-daily-warmup.git
cd ai-daily-warmup
```

#### 2. Edit [config/default.env](config/default.env):

```bash
WARMUP_PROVIDERS=codex
WARMUP_TIMEZONE=Asia/Hong_Kong
WARMUP_HOURS=8,13,18
WARMUP_LOG_PATH=./logs/warmup.log
WARMUP_PROMPT="Warmup. Don't think, just reply: OK"

CODEX_PATH=codex
CODEX_CREDENTIAL_PATH=~/.codex/auth.json
CODEX_ARGS=exec --skip-git-repo-check --ephemeral --color never
CODEX_MODEL=
```

Use `WARMUP_PROVIDERS=claude,codex,gemini` to warm up more than one CLI.

#### 3. Install & Done!

- #### macOS or Linux:

```bash
bash ./bin/install-scheduler.sh
```

- #### Windows PowerShell:

```powershell
.\bin\install-scheduler.ps1
```

---

### Commands (Optional)
- To remove it later

```bash
bash ./bin/install-scheduler.sh --uninstall
```

```powershell
.\bin\install-scheduler.ps1 -Uninstall
```

- Check running log

Runs append tab-separated rows to `WARMUP_LOG_PATH` (`./logs/warmup.log` by default), and the runners keep only the latest 100 rows.

```text
timestamp    provider    event    result    exit_code    duration_seconds    message
```

With the
default `WARMUP_MIN_WINDOW_MINUTES=302`, a delayed warmup will make the next
slot wait until a fresh 5-hour window + 2 min delay is available. The runner will store the last trigger slot in `WARMUP_STATE_PATH`. `WARMUP_SLOT_CATCHUP_MINUTES=60`
keeps a scheduled 1-hour slot eligible for late catch-up runs (check in every `WARMUP_SCHEDULER_INTERVAL_MINUTES=10` minutes).

- Run Once

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

### Advanced Usage

> [!NOTE] 
> `local/local.env` can override any value from `config/default.env`. You can keep your own scripts, env files, etc. under `local/`.

Set `*_PATH` to a custom executable path when a provider should run through a
different command or script:

```bash
CODEX_PATH=~/bin/codex-shadow-home.sh
```

If `*_PATH` points to a custom script that normally prompts for a username and
password, keep that behavior inside the script. The warmup runner only needs to
load an env file and run the configured path.

Example config:

```bash
CODEX_ENV_FILE=~/.config/ai-daily-warmup/codex.env
```

Create the env file outside this repo:

```bash
mkdir -p ~/.config/ai-daily-warmup
chmod 700 ~/.config/ai-daily-warmup

cat > ~/.config/ai-daily-warmup/codex.env <<EOF
V_USER=alice
V_PASS=your_password
EOF

chmod 600 ~/.config/ai-daily-warmup/codex.env
```

Details please refer to the comments in [config/default.env](config/default.env).

## Layout

```text
bin/
  daily-warmup.sh          # macOS/Linux runner
  daily-warmup.ps1         # Windows runner
  install-scheduler.sh     # macOS/Linux scheduler installer
  install-scheduler.ps1    # Windows scheduler installer
config/
  default.env              # provider and schedule settings
```
