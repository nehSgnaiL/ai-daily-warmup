#!/usr/bin/env bash
# scripts/warmup-gemini.sh
set -euo pipefail

CREDS_DIR="${HOME}/.gemini"
CREDS_FILE="${CREDS_DIR}/oauth_creds.json"

if [[ -n "${GEMINI_SESSION:-}" ]]; then
  mkdir -p "${CREDS_DIR}"
  (umask 077; printf '%s' "${GEMINI_SESSION}" > "${CREDS_FILE}")
  echo "[gemini] Session restored from environment."
fi

if [[ ! -f "${CREDS_FILE}" ]]; then
  echo "[gemini] No credentials found. Run 'gemini auth login' first." >&2
  exit 1
fi

PROMPT="${WARMUP_PROMPT:-Warmup. Use smallest available model. Reply: OK}"

CMD=(gemini "${PROMPT}" --yolo)
if [[ -n "${GEMINI_MODEL:-}" ]]; then
  CMD+=(--model "${GEMINI_MODEL}")
fi

echo "[gemini] Sending warmup prompt…"
"${CMD[@]}" \
  && echo "[gemini] ✓ Warmup complete." \
  || echo "[gemini] ⚠ Warmup exited with non-zero status (session may still be active)."
