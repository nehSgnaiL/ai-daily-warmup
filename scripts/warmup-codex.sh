#!/usr/bin/env bash
# scripts/warmup-codex.sh
set -euo pipefail

AUTH_DIR="${HOME}/.codex"
AUTH_FILE="${AUTH_DIR}/auth.json"

if [[ -n "${CODEX_SESSION:-}" ]]; then
  mkdir -p "${AUTH_DIR}"
  (umask 077; printf '%s' "${CODEX_SESSION}" > "${AUTH_FILE}")
  echo "[codex] Session restored from environment."
fi

if [[ ! -f "${AUTH_FILE}" ]]; then
  echo "[codex] No credentials found. Run 'codex auth login' first." >&2
  exit 1
fi

PROMPT="${WARMUP_PROMPT:-Warmup. Use smallest available model. Reply: OK}"

CMD=(codex "${PROMPT}" --approval-mode full-auto --quiet)
if [[ -n "${CODEX_MODEL:-}" ]]; then
  CMD+=(--model "${CODEX_MODEL}")
fi

echo "[codex] Sending warmup prompt…"
"${CMD[@]}" \
  && echo "[codex] ✓ Warmup complete." \
  || echo "[codex] ⚠ Warmup exited with non-zero status (session may still be active)."
