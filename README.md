# ai-daily-warmup

Auto-schedule AI CLI wakeups (Claude, Codex, Gemini) with GitHub Actions using official `auth login` sessions (no API keys in repo).

## What this does

- Runs hourly in GitHub Actions.
- Checks your configured local timezone/hour window.
- Only sends warmup prompts at matching local hours (default: `8,13,18`).
- Uses a very short default prompt to minimize token usage.

## Auth model (official way)

This repo relies on official CLI OAuth login flows:

- `claude auth login`
- `codex auth login`
- `gemini auth login`

Store session files as encrypted GitHub Actions secrets (never commit credentials):

- `CLAUDE_SESSION` ← `~/.claude/.credentials.json`
- `CODEX_SESSION` ← `~/.codex/auth.json`
- `GEMINI_SESSION` ← `~/.gemini/oauth_creds.json`

If a secret is missing, that CLI job is skipped.

## Timezone as variable

Yes — timezone and hours are variable-driven via **Repository Variables**:

Go to: **Settings → Secrets and variables → Actions → Variables**

| Variable | Default | Example | Purpose |
|---|---|---|---|
| `WARMUP_TIMEZONE` | `Asia/Shanghai` | `America/Los_Angeles` | Local timezone used for schedule gating |
| `WARMUP_HOURS` | `8,13,18` | `7,12,19` | Local hours (CSV) when warmup should run |

> Why hourly cron? GitHub `on.schedule.cron` cannot read variables directly. So workflow runs hourly and gates per `WARMUP_TIMEZONE` + `WARMUP_HOURS`.

## Smart prompt (minimal tokens)

Default prompt:

`Warmup. Use smallest available model. Reply: OK`

This is intentionally short and model-agnostic.

You can override with a repository variable:

| Variable | Default | Purpose |
|---|---|---|
| `WARMUP_PROMPT` | `Warmup. Use smallest available model. Reply: OK` | Custom low-token warmup prompt |

Optional per-CLI model hint variables (best effort):

- `CLAUDE_MODEL`
- `CODEX_MODEL`
- `GEMINI_MODEL`

If unset, CLI default model is used.

## Quick setup

1. Fork this repo.
2. Add your session secrets.
3. (Optional) Set `WARMUP_TIMEZONE`, `WARMUP_HOURS`, `WARMUP_PROMPT`.
4. Run manually once: **Actions → AI Daily Warmup → Run workflow**.

## Files

- `.github/workflows/daily-warmup.yml` — hourly scheduler + local-time gating
- `scripts/warmup-claude.sh`
- `scripts/warmup-codex.sh`
- `scripts/warmup-gemini.sh`

## Security

- No API keys in repo.
- No credentials committed.
- Uses encrypted GitHub secrets only.
- Workflow uses `permissions: {}`.

## License

MIT
