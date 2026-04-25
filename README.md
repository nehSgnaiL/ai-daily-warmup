## ai-daily-warmup

Small scheduled warmups for AI CLIs such as Codex, Claude, and Gemini, given the *5-hour limit window* from several AI CLIs. 

If you want that window to **open right when you sit down to work in the morning, at lunch, and during the night**, this repo schedules small "warmup" prompts to trigger calls daily.

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
WARMUP_PROMPT="Warmup. Don't think, just reply: OK"

CODEX_PATH=codex
CODEX_CREDENTIAL_PATH=~/.codex/auth.json
CODEX_ARGS=--quiet
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

Each provider run appends one row to `WARMUP_LOG_PATH`, the runners keep only the latest 100 rows.

```text
timestamp    provider    result    exit_code
```

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
