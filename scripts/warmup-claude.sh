#!/usr/bin/env bash
# scripts/warmup-claude.sh
set -euo pipefail

CREDENTIALS_DIR="${HOME}/.claude"
CREDENTIALS_FILE="${CREDENTIALS_DIR}/.credentials.json"

if [[ -n "${CLAUDE_SESSION:-}" ]]; then
  mkdir -p "${CREDENTIALS_DIR}"
  (umask 077; printf '%s' "${CLAUDE_SESSION}" > "${CREDENTIALS_FILE}")
  echo "[claude] Session restored from environment."
fi

if [[ ! -f "${CREDENTIALS_FILE}" ]]; then
  echo "[claude] No credentials found. Run 'claude auth login' first." >&2
  exit 1
fi

PROMPT="${WARMUP_PROMPT:-Warmup. Use smallest available model. Reply: OK}"

CMD=(claude --print --no-interactive)
if [[ -n "${CLAUDE_MODEL:-}" ]]; then
  CMD+=(--model "${CLAUDE_MODEL}")
fi

echo "[claude] Sending warmup prompt…"
printf '%s' "${PROMPT}" | "${CMD[@]}" \
  && echo "[claude] ✓ Warmup complete." \
  || echo "[claude] ⚠ Warmup exited with non-zero status (session may still be active)."
