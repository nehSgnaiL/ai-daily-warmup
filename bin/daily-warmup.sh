#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="${1:-config/default.env}"
MODE="${2:-once}"
DEFAULT_WARMUP_PROMPT="Warmup. Don't think, just reply: OK"
LOADED_LOCAL_CONFIG_PATH=""

prepend_path_dir() {
  local dir="$1"
  [[ -d "${dir}" ]] || return 0
  case ":${PATH:-}:" in
    *":${dir}:"*) ;;
    *) PATH="${dir}${PATH:+:${PATH}}" ;;
  esac
}

# Schedulers often start with a minimal PATH. Add common per-user CLI install
# locations so custom commands can still resolve the CLI.
prepend_path_dir "${HOME}/.npm-global/bin"
prepend_path_dir "${HOME}/.local/bin"
prepend_path_dir "${HOME}/bin"
export PATH

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

expand_path() {
  local value="$1"
  if [[ -z "${value}" ]]; then
    return 0
  fi

  case "${value}" in
    "~") printf '%s\n' "${HOME}" ;;
    "~/"*) printf '%s/%s\n' "${HOME}" "${value#"~/"}" ;;
    *) printf '%s\n' "${value}" ;;
  esac
}

positive_integer_or_default() {
  local value="$1"
  local default_value="$2"
  if [[ "${value}" =~ ^[0-9]+$ && "${value}" -gt 0 ]]; then
    printf '%s\n' "${value}"
  else
    printf '%s\n' "${default_value}"
  fi
}

current_epoch() {
  printf '%s\n' "${WARMUP_NOW_EPOCH:-$(date +%s)}"
}

format_epoch() {
  local epoch="$1"
  local format="$2"
  if date -d "@0" +%F >/dev/null 2>&1; then
    TZ="${WARMUP_TIMEZONE:-}" date -d "@${epoch}" "${format}"
  else
    TZ="${WARMUP_TIMEZONE:-}" date -r "${epoch}" "${format}"
  fi
}

date_for_minutes_ago() {
  local minutes_ago="$1"
  local now_epoch="$2"
  format_epoch "$((now_epoch - minutes_ago * 60))" +%F
}

schedule_hours() {
  local hours hour
  hours="${WARMUP_HOURS:-8,13,18}"
  hours="${hours//[[:space:]]/}"
  IFS=',' read -r -a schedule_hour_list <<< "${hours}"
  for hour in "${schedule_hour_list[@]}"; do
    [[ -z "${hour}" ]] && continue
    if [[ "${hour}" =~ ^[0-9]+$ ]] && (( 10#${hour} >= 0 && 10#${hour} <= 23 )); then
      printf '%d\n' "$((10#${hour}))"
    fi
  done
}

validate_schedule() {
  case "${WARMUP_SCHEDULE_ENABLED:-true}" in
    false) return 0 ;;
    true) ;;
    *) echo '[local] WARMUP_SCHEDULE_ENABLED must be true or false.' >&2; return 1 ;;
  esac
  local hours hour key value
  WARMUP_MIN_WINDOW_MINUTES="${WARMUP_MIN_WINDOW_MINUTES:-302}"
  WARMUP_SLOT_CATCHUP_MINUTES="${WARMUP_SLOT_CATCHUP_MINUTES:-60}"
  hours="${WARMUP_HOURS:-8,13,18}"
  hours="${hours//[[:space:]]/}"
  [[ "${hours}" =~ ^([0-9]{1,2},)*[0-9]{1,2}$ ]] || {
    echo '[local] WARMUP_HOURS must be comma-separated hours from 0 to 23.' >&2; return 1;
  }
  local -a hours_to_check
  IFS=',' read -r -a hours_to_check <<< "${hours}"
  for hour in "${hours_to_check[@]}"; do
    (( 10#${hour} <= 23 )) || { echo '[local] Hour must be from 0 to 23.' >&2; return 1; }
  done
  for key in WARMUP_MIN_WINDOW_MINUTES WARMUP_SLOT_CATCHUP_MINUTES; do
    value="${!key}"
    [[ "${value}" =~ ^[0-9]+$ ]] || { echo "[local] ${key} must be a nonnegative integer." >&2; return 1; }
    printf -v "${key}" '%d' "$((10#${value}))"
  done
}

current_schedule_slot() {
  if [[ "${WARMUP_SCHEDULE_ENABLED:-true}" != "true" ]]; then
    printf 'always\n'
    return 0
  fi

  local now_epoch raw_hour raw_minute now_minutes catchup_minutes hour target_minutes delta
  local best_delta=1441 best_hour=""

  now_epoch="$(current_epoch)"
  raw_hour="$(format_epoch "${now_epoch}" +%H)"
  raw_minute="$(format_epoch "${now_epoch}" +%M)"
  now_minutes="$((10#${raw_hour} * 60 + 10#${raw_minute}))"
  catchup_minutes="${WARMUP_SLOT_CATCHUP_MINUTES:-60}"
  if ! [[ "${catchup_minutes}" =~ ^[0-9]+$ ]]; then
    catchup_minutes=60
  fi

  while IFS= read -r hour; do
    target_minutes="$((hour * 60))"
    delta="$(((now_minutes - target_minutes + 1440) % 1440))"
    if (( (delta < catchup_minutes || (catchup_minutes == 0 && delta == 0)) && delta < best_delta )); then
      best_delta="${delta}"
      best_hour="${hour}"
    fi
  done < <(schedule_hours)

  [[ -n "${best_hour}" ]] || return 1
  printf '%s-%02d\n' "$(date_for_minutes_ago "${best_delta}" "${now_epoch}")" "${best_hour}"
}

warmup_state_path() {
  local configured log_path log_dir
  configured="${WARMUP_STATE_PATH:-}"
  if [[ -n "${configured}" ]]; then
    expand_path "${configured}"
    return 0
  fi

  log_path="$(warmup_log_path)"
  log_dir="$(dirname "${log_path}")"
  printf '%s/warmup.state\n' "${log_dir}"
}

state_value() {
  local key="$1"
  local state_path line
  state_path="$(warmup_state_path)"
  [[ -f "${state_path}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" == "${key}="* ]] || continue
    printf '%s\n' "${line#*=}"
    return 0
  done < "${state_path}"
}

record_schedule_trigger() {
  local slot="$1"
  local state_path state_dir temp_path now_epoch
  [[ "${WARMUP_SCHEDULE_ENABLED:-true}" == "true" ]] || return 0
  [[ -n "${slot}" && "${slot}" != "always" ]] || return 0

  state_path="$(warmup_state_path)"
  state_dir="$(dirname "${state_path}")"
  mkdir -p "${state_dir}" || return 1
  temp_path="${state_path}.$$"
  now_epoch="$(current_epoch)"
  {
    printf 'LAST_TRIGGER_SLOT=%s\n' "${slot}"
    printf 'LAST_TRIGGER_EPOCH=%s\n' "${now_epoch}"
  } > "${temp_path}" || return 1
  mv "${temp_path}" "${state_path}" || return 1
}

schedule_matches() {
  CURRENT_SCHEDULE_SLOT=""
  SCHEDULE_SKIP_REASON=""

  local slot last_slot last_epoch now_epoch min_minutes min_seconds earliest_epoch
  if ! slot="$(current_schedule_slot)"; then
    SCHEDULE_SKIP_REASON="outside_schedule"
    return 1
  fi

  if [[ "${slot}" == "always" ]]; then
    CURRENT_SCHEDULE_SLOT="${slot}"
    return 0
  fi

  last_slot="$(state_value LAST_TRIGGER_SLOT)"
  if [[ "${slot}" == "${last_slot}" ]]; then
    SCHEDULE_SKIP_REASON="already_triggered"
    return 1
  fi

  min_minutes="${WARMUP_MIN_WINDOW_MINUTES:-302}"

  last_epoch="$(state_value LAST_TRIGGER_EPOCH)"
  if [[ "${last_epoch}" =~ ^[0-9]+$ && "${min_minutes}" -gt 0 ]]; then
    now_epoch="$(current_epoch)"
    min_seconds="$((min_minutes * 60))"
    earliest_epoch="$((last_epoch + min_seconds))"
    if (( now_epoch < earliest_epoch )); then
      SCHEDULE_SKIP_REASON="previous_window"
      return 1
    fi
  fi

  CURRENT_SCHEDULE_SLOT="${slot}"
  return 0
}

warmup_log_path() {
  expand_path "${WARMUP_LOG_PATH:-./logs/warmup.log}"
}

append_warmup_log() {
  local provider="$1"
  local event="$2"
  local result="$3"
  local status="$4"
  local duration_seconds="${5:-0}"
  local message="${6:-}"
  local log_path log_dir temp_path timestamp

  log_path="$(warmup_log_path)"
  [[ -z "${log_path}" ]] && return 0

  log_dir="$(dirname "${log_path}")"
  if ! mkdir -p "${log_dir}" 2>/dev/null; then
    echo "[local] Could not create log directory: ${log_dir}" >&2
    return 0
  fi
  timestamp="$(TZ="${WARMUP_TIMEZONE:-}" date '+%Y-%m-%dT%H:%M:%S%z')"
  message="${message//$'\t'/ }"
  message="${message//$'\n'/ }"
  if ! printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${timestamp}" "${provider}" "${event}" "${result}" "${status}" "${duration_seconds}" "${message}" >> "${log_path}"; then
    echo "[local] Could not write log file: ${log_path}" >&2
    return 0
  fi

  temp_path="${log_path}.$$"
  tail -n "$(positive_integer_or_default "${WARMUP_LOG_MAX_ROWS:-200}" 200)" "${log_path}" > "${temp_path}" && mv "${temp_path}" "${log_path}" || true
}

prepare_codex_command() {
  local model="$1"
  local prompt="$2"

  # Split simple flags without expanding filesystem wildcards.
  read -r -a arg_list <<< "${args}"
  if [[ "${arg_list[0]:-}" != "exec" && "${arg_list[0]:-}" != "e" ]]; then
    arg_list=(exec --skip-git-repo-check --ephemeral "${arg_list[@]}")
  fi
  [[ -z "${model}" ]] || arg_list+=(--model "${model}")
  arg_list+=("${prompt}")
}

run_codex() {
  local path args model credential_path env_file prompt run_dir configured_workdir status
  local remove_run_dir start_seconds duration_seconds output_path failure_detail failure_log_lines
  local pair
  local -a arg_list env_pairs

  path="$(expand_path "${CODEX_PATH:-codex}")"
  args="${CODEX_ARGS:-}"
  model="${CODEX_MODEL:-}"
  credential_path="$(expand_path "${CODEX_CREDENTIAL_PATH:-}")"
  env_file="$(expand_path "${CODEX_ENV_FILE:-}")"
  configured_workdir="$(expand_path "${CODEX_WORKDIR:-}")"
  prompt="${WARMUP_PROMPT:-${DEFAULT_WARMUP_PROMPT}}"

  if [[ -n "${credential_path}" && ! -f "${credential_path}" ]]; then
    echo "[codex] No credentials found at ${credential_path}. Run the CLI login first." >&2
    append_warmup_log "codex" "skip" "missing_credentials" "1" "0" "No credentials found at ${credential_path}."
    return 1
  fi

  env_pairs=()
  if [[ -n "${env_file}" ]]; then
    if [[ ! -f "${env_file}" || ! -r "${env_file}" ]]; then
      echo "[codex] Env file not found: ${env_file}" >&2
      append_warmup_log "codex" "skip" "missing_env_file" "1" "0" "Env file not found: ${env_file}."
      return 1
    fi

    while IFS= read -r -d '' pair; do
      env_pairs+=("${pair}")
    done < <(read_env_file "${env_file}")
  fi

  if ! command -v "${path}" >/dev/null 2>&1 && [[ ! -x "${path}" ]]; then
    echo "[codex] Command not found: ${path}" >&2
    append_warmup_log "codex" "skip" "command_not_found" "1" "0" "Command not found: ${path}."
    return 1
  fi

  prepare_codex_command "${model}" "${prompt}"

  remove_run_dir=false
  if [[ -n "${configured_workdir}" ]]; then
    mkdir -p "${configured_workdir}" || return 1
    run_dir="${configured_workdir}"
  else
    run_dir="$(mktemp -d)" || return 1
    remove_run_dir=true
  fi

  echo "[codex] Sending warmup prompt..."
  append_warmup_log "codex" "start" "running" "0" "0" "Starting warmup command."
  start_seconds="$(date +%s)"
  output_path="$(mktemp)"
  set +e
  (cd "${run_dir}" && env -u GITHUB_TOKEN "${env_pairs[@]}" "${path}" "${arg_list[@]}") 2>&1 | tee "${output_path}"
  status=${PIPESTATUS[0]}
  duration_seconds="$(( $(date +%s) - start_seconds ))"
  set -e
  if [[ "${remove_run_dir}" == "true" ]]; then
    rm -rf "${run_dir}"
  fi

  if [[ ${status} -eq 0 ]]; then
    echo "[codex] Warmup complete."
    append_warmup_log "codex" "finish" "success" "${status}" "${duration_seconds}" "Warmup complete."
  else
    failure_log_lines="$(positive_integer_or_default "${WARMUP_FAILURE_LOG_LINES:-20}" 20)"
    failure_detail="$(tail -n "${failure_log_lines}" "${output_path}" | tr '\r\n\t' '   ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
    if [[ -z "${failure_detail}" ]]; then
      failure_detail="No provider output captured."
    fi
    echo "[codex] Warmup exited with status ${status}."
    append_warmup_log "codex" "finish" "failed" "${status}" "${duration_seconds}" "Warmup exited with status ${status}. Output tail: ${failure_detail}"
  fi
  rm -f "${output_path}"
  return "${status}"
}

run_once() {
  validate_schedule || return 1
  if [[ -n "${LOADED_LOCAL_CONFIG_PATH}" ]]; then
    append_warmup_log "local" "init" "started" "0" "0" "Warmup run started. Config: ${CONFIG_PATH}; local override: ${LOADED_LOCAL_CONFIG_PATH}."
  else
    append_warmup_log "local" "init" "started" "0" "0" "Warmup run started. Config: ${CONFIG_PATH}; no local override."
  fi
  if ! schedule_matches; then
    case "${SCHEDULE_SKIP_REASON}" in
      previous_window)
        echo "[local] Waiting for the next 5-hour window before triggering."
        append_warmup_log "local" "skip" "previous_window" "0" "0" "Last trigger is still inside the minimum window interval."
        append_warmup_log "local" "finish" "complete" "0" "0" "Warmup run deferred until the next window."
        ;;
      already_triggered)
        echo "[local] Current schedule slot already triggered."
        append_warmup_log "local" "skip" "already_triggered" "0" "0" "Current schedule slot already triggered."
        append_warmup_log "local" "finish" "complete" "0" "0" "Warmup run finished for an already triggered slot."
        ;;
      *)
        echo "[local] Current time is outside configured schedule."
        append_warmup_log "local" "skip" "outside_schedule" "0" "0" "Current time is outside configured schedule."
        append_warmup_log "local" "finish" "complete" "0" "0" "Warmup run finished outside schedule."
        ;;
    esac
    return 0
  fi

  if run_codex; then
    record_schedule_trigger "${CURRENT_SCHEDULE_SLOT}" || return 1
    append_warmup_log "local" "finish" "complete" "0" "0" "Warmup run finished."
  else
    append_warmup_log "local" "finish" "failed" "1" "0" "Codex warmup failed; schedule slot was left retryable."
    return 1
  fi
}

run_accounts() {
  if [[ -z "${WARMUP_ACCOUNTS:-}" ]]; then
    run_once
    return
  fi

  local account profile config_dir status=0
  config_dir="$(expand_path "${WARMUP_ACCOUNT_CONFIG_DIR:-$(dirname "${CONFIG_PATH}")/../local/accounts}")"
  local -a accounts
  IFS=',' read -r -a accounts <<< "${WARMUP_ACCOUNTS}"
  for account in "${accounts[@]}"; do
    if ! [[ "${account}" =~ ^[a-z][a-z0-9-]{0,31}$ ]]; then
      echo '[local] Invalid account name in WARMUP_ACCOUNTS.' >&2
      status=1
      continue
    fi
    profile="${config_dir}/${account}.env"
    if [[ ! -f "${profile}" ]]; then
      echo "[${account}] Account profile not found: ${profile}" >&2
      status=1
      continue
    fi
    # Subshells isolate account overrides and independent retry state.
    if ! (
      WARMUP_STATE_PATH="$(warmup_state_path).${account}"
      WARMUP_LOG_PATH="$(warmup_log_path).${account}"
      WARMUP_ACCOUNT="${account}"
      load_config "${profile}" || exit 1
      export WARMUP_ACCOUNT
      echo "[${account}] Checking warmup schedule..."
      run_once
    ); then
      status=1
    fi
  done
  return "${status}"
}

if ! load_warmup_config; then
  append_warmup_log local init_error failed 1 0 "Could not load configuration: ${CONFIG_PATH}."
  return 1 2>/dev/null || exit 1
fi

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if [[ "${MODE}" == "schedule" ]]; then
    while true; do
      run_accounts || true
      sleep "${WARMUP_POLL_SECONDS:-60}"
    done
  fi
  run_accounts
fi
