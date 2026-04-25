# ai-daily-warmup

Auto-wakeups for AI CLI (e.g., Claude, Codex, Gemini) via GitHub Actions, since several AI CLI tools grant a *5-hour limit window* per session. 

If you want that window to **open right when you sit down to work in the morning, at lunch, and in the evening**, this repo schedules small "warmup" prompts at those three times every day using GitHub Actions.

- **Zero secrets in code**: credentials live exclusively in GitHub Actions Secrets.
- **Auth-login, not API keys**: uses the official OAuth `auth login` flow of each CLI.
- **Minimal setup**: fork → add secrets and variables → done.

---

## Quick Start

### 1. Fork this repo

Click **Fork** on the top-right of this page. All the workflow files come along automatically.

### 2. Authenticate locally and capture the session token

For each CLI tool you want to use, run `auth login` on your **local machine** and copy the resulting credential file.

#### Claude

```bash
# Install
npm install -g @anthropic-ai/claude-code

# Login (opens browser OAuth flow)
claude auth login

# Copy the session JSON (single line, no newline)
cat ~/.claude/.credentials.json
```

#### Codex

```bash
# Install
npm install -g @openai/codex

# Login (opens browser OAuth flow)
codex auth login

# Copy the session JSON
cat ~/.codex/auth.json
```

#### Gemini

```bash
# Install
npm install -g @google/gemini-cli

# Login (opens browser OAuth flow)
gemini auth login

# Copy the session JSON
cat ~/.gemini/oauth_creds.json
```

### 3. Add the session JSON as a GitHub Secret

Go to your forked repository on GitHub: **Settings → Secrets and variables → Actions → New repository secret**

| Secret Name | Value |
|-------------|-------|
| `CLAUDE_SESSION` | Full content of `~/.claude/.credentials.json` |
| `CODEX_SESSION` | Full content of `~/.codex/auth.json` |
| `GEMINI_SESSION` | Full content of `~/.gemini/oauth_creds.json` |

> Add only the secrets for the CLIs you use. Any job whose secret is absent is **automatically skipped**.


### 4. Set schedule (optional)

Timezone, hours, and wakeup prompt can be set via Repository Variables: Go to: **Settings → Secrets and variables → Actions → Variables**

| Variable | Default | Example | Purpose |
|---|---|---|---|
| `WARMUP_TIMEZONE` | `Asia/Shanghai` | `America/Los_Angeles` | Local timezone used for schedule gating |
| `WARMUP_HOURS` | `8,13,18` | `7,12,19` | Local hours (CSV) when warmup should run |
| `WARMUP_PROMPT` | `Warmup. Don't think. Just reply: OK` | Custom low-token warmup prompt |
| `CLAUDE_MODEL`<br>`CODEX_MODEL`<br>`GEMINI_MODEL` | CLI default model is used (unset) | Optional per-CLI model hint variables |

> Why hourly cron? GitHub `on.schedule.cron` cannot read variables directly. So workflow runs one tiny **schedule-gate** job hourly, and provider jobs only run when local hour matches `WARMUP_HOURS`.

## What this does

- Runs hourly in GitHub Actions with one lightweight gate job.
- Only launches provider jobs at matching local hours (default: `8,13,18`).
- Uses a very short default prompt to minimize token usage.
