# ai-daily-warmup

> **Auto-schedule AI CLI wake-ups via GitHub Actions** — keep Claude, Codex, and Gemini sessions fresh at comfortable local times without storing any API keys in the repository.

---

## Why This Exists

Several AI CLI tools (Claude, OpenAI Codex, Google Gemini) grant a **5-hour free-usage window** per session. If you want that window to open right when you sit down to work in the morning, at lunch, and in the evening, this repo schedules small "warmup" prompts at those three times every day using GitHub Actions.

- 🔐 **Zero secrets in code** — credentials live exclusively in GitHub Actions Secrets.
- 🔑 **Auth-login, not API keys** — uses the official OAuth `auth login` flow of each CLI.
- ⚙️ **Minimal setup** — fork → add secrets → done.
- 🧩 **Pick your tools** — only configure the CLIs you actually use; the rest are skipped automatically.

---

## Supported CLI Tools

| CLI | Official Package | Auth Command |
|-----|-----------------|--------------|
| [Claude](https://claude.ai/code) | `@anthropic-ai/claude-code` | `claude auth login` |
| [OpenAI Codex](https://github.com/openai/codex) | `@openai/codex` | `codex auth login` |
| [Google Gemini](https://github.com/google-gemini/gemini-cli) | `@google/gemini-cli` | `gemini auth login` |

---

## Quick Start

### 1. Fork this repository

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

Go to your forked repository on GitHub:

**Settings → Secrets and variables → Actions → New repository secret**

| Secret Name | Value |
|-------------|-------|
| `CLAUDE_SESSION` | Full content of `~/.claude/.credentials.json` |
| `CODEX_SESSION` | Full content of `~/.codex/auth.json` |
| `GEMINI_SESSION` | Full content of `~/.gemini/oauth_creds.json` |

> Add only the secrets for the CLIs you use. Any job whose secret is absent is **automatically skipped**.

### 4. (Optional) Adjust the schedule timezone

The default schedule targets **UTC+8 (CST)** — 08:00, 13:00, 18:00. Open `.github/workflows/daily-warmup.yml` and change the three cron expressions to match your local offset:

```yaml
on:
  schedule:
    - cron: '0 0 * * *'   # Change UTC hour = local hour − offset
    - cron: '0 5 * * *'
    - cron: '0 10 * * *'
```

**Common offsets:**

| Timezone | Offset | 08:00 cron | 13:00 cron | 18:00 cron |
|----------|--------|-----------|-----------|-----------|
| UTC | +0 | `0 8 * * *` | `0 13 * * *` | `0 18 * * *` |
| CET | +1 | `0 7 * * *` | `0 12 * * *` | `0 17 * * *` |
| IST | +5:30 | `30 2 * * *` | `30 7 * * *` | `30 12 * * *` |
| CST | +8 | `0 0 * * *` | `0 5 * * *` | `0 10 * * *` |
| JST | +9 | `0 23 * * *` | `0 4 * * *` | `0 9 * * *` |
| PDT | −7 | `0 15 * * *` | `0 20 * * *` | `0 1 * * *` |
| EDT | −4 | `0 12 * * *` | `0 17 * * *` | `0 22 * * *` |

### 5. Trigger manually to verify

In your forked repo go to **Actions → AI Daily Warmup → Run workflow** to confirm everything is working before the first scheduled run.

---

## Repository Layout

```
.
├── .github/
│   └── workflows/
│       └── daily-warmup.yml   # Scheduled GitHub Actions workflow
├── scripts/
│   ├── warmup-claude.sh       # Claude warmup helper (also usable locally)
│   ├── warmup-codex.sh        # Codex warmup helper
│   └── warmup-gemini.sh       # Gemini warmup helper
└── README.md
```

---

## How It Works

```
GitHub Actions (cron)
        │
        ▼
┌───────────────────┐    ┌───────────────────┐    ┌───────────────────┐
│  warmup-claude    │    │  warmup-codex     │    │  warmup-gemini    │
│  (parallel job)   │    │  (parallel job)   │    │  (parallel job)   │
│                   │    │                   │    │                   │
│ 1. npm install    │    │ 1. npm install    │    │ 1. npm install    │
│ 2. restore creds  │    │ 2. restore creds  │    │ 2. restore creds  │
│    from Secret    │    │    from Secret    │    │    from Secret    │
│ 3. send prompt    │    │ 3. send prompt    │    │ 3. send prompt    │
└───────────────────┘    └───────────────────┘    └───────────────────┘
```

Each job:
1. Installs the official CLI via `npm` from the vendor's public npm package.
2. Writes the stored OAuth session token (from GitHub Secrets) to the location the CLI expects on disk.
3. Sends a minimal one-line prompt to open a new 5-hour usage window.

---

## Running Scripts Locally

The helper scripts in `scripts/` work on your local machine after you have authenticated with `auth login`:

```bash
bash scripts/warmup-claude.sh
bash scripts/warmup-codex.sh
bash scripts/warmup-gemini.sh
```

---

## Security Notes

- **No API keys are stored or used.** Every CLI authenticates through its official OAuth flow (`auth login`), which issues short-lived tokens.
- **Tokens are stored as encrypted GitHub Secrets**, not in any file tracked by git. GitHub encrypts secrets at rest and injects them into jobs as environment variables only at runtime.
- **The repository itself contains no credentials.** A fresh fork has no secrets and all jobs are skipped until you add your own.
- Re-run `auth login` and update the corresponding GitHub Secret whenever a session token expires.

---

## Refreshing Expired Tokens

Session tokens expire periodically. When a workflow run fails with an authentication error:

1. Run `<cli> auth login` again on your local machine.
2. Copy the new credential file content.
3. Update the corresponding GitHub Secret.

---

## License

MIT
