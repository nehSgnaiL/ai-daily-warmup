#!/usr/bin/env bash
# scripts/warmup-gemini.sh
# ──────────────────────────────────────────────────────────────────────────────
# Wake up the Gemini CLI by sending a minimal prompt.
# Intended to be called from the GitHub Actions workflow, but can also be run
# locally for testing after `gemini auth login` has been completed.
#
# Usage (local):
#   bash scripts/warmup-gemini.sh
#
# Environment variables (set automatically by the workflow):
#   GEMINI_SESSION   JSON string from ~/.gemini/oauth_creds.json
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

CREDS_DIR="${HOME}/.gemini"
CREDS_FILE="${CREDS_DIR}/oauth_creds.json"

# Restore session from environment when running in CI
if [[ -n "${GEMINI_SESSION:-}" ]]; then
  mkdir -p "${CREDS_DIR}"
  printf '%s' "${GEMINI_SESSION}" > "${CREDS_FILE}"
  echo "[gemini] Session restored from environment."
fi

if [[ ! -f "${CREDS_FILE}" ]]; then
  echo "[gemini] No credentials found. Run 'gemini auth login' first." >&2
  exit 1
fi

PROMPT="Daily warmup — $(date -u '+%Y-%m-%d %H:%M UTC'). Reply with one sentence."

echo "[gemini] Sending warmup prompt…"
gemini "${PROMPT}" --yolo \
  && echo "[gemini] ✓ Warmup complete." \
  || echo "[gemini] ⚠ Warmup exited with non-zero status (session may still be active)."
