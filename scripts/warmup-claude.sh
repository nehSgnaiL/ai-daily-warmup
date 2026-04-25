#!/usr/bin/env bash
# scripts/warmup-claude.sh
# ──────────────────────────────────────────────────────────────────────────────
# Wake up the Claude CLI by sending a minimal prompt.
# Intended to be called from the GitHub Actions workflow, but can also be run
# locally for testing after `claude auth login` has been completed.
#
# Usage (local):
#   bash scripts/warmup-claude.sh
#
# Environment variables (set automatically by the workflow):
#   CLAUDE_SESSION   JSON string from ~/.claude/.credentials.json
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

CREDENTIALS_DIR="${HOME}/.claude"
CREDENTIALS_FILE="${CREDENTIALS_DIR}/.credentials.json"

# Restore session from environment when running in CI
if [[ -n "${CLAUDE_SESSION:-}" ]]; then
  mkdir -p "${CREDENTIALS_DIR}"
  printf '%s' "${CLAUDE_SESSION}" > "${CREDENTIALS_FILE}"
  echo "[claude] Session restored from environment."
fi

if [[ ! -f "${CREDENTIALS_FILE}" ]]; then
  echo "[claude] No credentials found. Run 'claude auth login' first." >&2
  exit 1
fi

PROMPT="Daily warmup — $(date -u '+%Y-%m-%d %H:%M UTC'). Reply with one sentence."

echo "[claude] Sending warmup prompt…"
claude --print --no-interactive <<< "${PROMPT}" \
  && echo "[claude] ✓ Warmup complete." \
  || echo "[claude] ⚠ Warmup exited with non-zero status (session may still be active)."
