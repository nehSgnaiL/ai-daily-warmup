#!/usr/bin/env bash
# scripts/warmup-codex.sh
# ──────────────────────────────────────────────────────────────────────────────
# Wake up the Codex CLI by sending a minimal prompt.
# Intended to be called from the GitHub Actions workflow, but can also be run
# locally for testing after `codex auth login` has been completed.
#
# Usage (local):
#   bash scripts/warmup-codex.sh
#
# Environment variables (set automatically by the workflow):
#   CODEX_SESSION   JSON string from ~/.codex/auth.json
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

AUTH_DIR="${HOME}/.codex"
AUTH_FILE="${AUTH_DIR}/auth.json"

# Restore session from environment when running in CI
if [[ -n "${CODEX_SESSION:-}" ]]; then
  mkdir -p "${AUTH_DIR}"
  printf '%s' "${CODEX_SESSION}" > "${AUTH_FILE}"
  echo "[codex] Session restored from environment."
fi

if [[ ! -f "${AUTH_FILE}" ]]; then
  echo "[codex] No credentials found. Run 'codex auth login' first." >&2
  exit 1
fi

PROMPT="Daily warmup — $(date -u '+%Y-%m-%d %H:%M UTC'). Reply with one sentence."

echo "[codex] Sending warmup prompt…"
codex "${PROMPT}" --approval-mode full-auto --quiet \
  && echo "[codex] ✓ Warmup complete." \
  || echo "[codex] ⚠ Warmup exited with non-zero status (session may still be active)."
