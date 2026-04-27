#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="${1:-config/default.env}"
MODE="${2:-once}"
DEFAULT_WARMUP_PROMPT="Warmup. Don't think, just reply: OK"
LOADED_LOCAL_CONFIG_PATH=""

if [[ ! -f "${CONFIG_PATH}" ]]; then
  echo "[local] Config file not found: ${CONFIG_PATH}" >&2
  WARMUP_LOG_PATH="${WARMUP_LOG_PATH:-./logs/warmup.log}"
  append_init_error() {
    local log_path log_dir timestamp temp_path log_max_rows
    case "${WARMUP_LOG_PATH}" in
      "~") log_path="${HOME}" ;;
      "~/"*) log_path="${HOME}/${WARMUP_LOG_PATH#"~/"}" ;;
      *) log_path="${WARMUP_LOG_PATH}" ;;
    esac
    log_dir="$(dirname "${log_path}")"
    mkdir -p "${log_dir}"
    timestamp="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf '%s\tlocal\tinit_error\tfailed\t1\t0\tConfig file not found: %s\n' "${timestamp}" "${CONFIG_PATH}" >> "${log_path}"
    temp_path="${log_path}.$$"
    log_max_rows="${WARMUP_LOG_MAX_ROWS:-200}"
    if ! [[ "${log_max_rows}" =~ ^[0-9]+$ && "${log_max_rows}" -gt 0 ]]; then
      log_max_rows=200
    fi
    tail -n "${log_max_rows}" "${log_path}" > "${temp_path}" && mv "${temp_path}" "${log_path}"
  }
  append_init_error || true
  exit 1
fi

load_config() {
  local config_file="$1"
  local line trimmed key value

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"

    [[ -z "${trimmed}" || "${trimmed}" == \#* ]] && continue
    [[ "${trimmed}" != *=* ]] && continue

    key="${trimmed%%=*}"
    value="${trimmed#*=}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    if [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
      value="${value:1:${#value}-2}"
    fi

    if [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      printf -v "${key}" '%s' "${value}"
    fi
  done < "${config_file}"
}

default_local_config_path() {
  local config_dir repo_root
  config_dir="$(dirname "${CONFIG_PATH}")"
  repo_root="$(cd "${config_dir}/.." && pwd)"
  printf '%s\n' "${repo_root}/local/local.env"
}

load_config "${CONFIG_PATH}"

LOCAL_CONFIG_PATH="${WARMUP_LOCAL_CONFIG_PATH:-$(default_local_config_path)}"
if [[ -n "${LOCAL_CONFIG_PATH}" && -f "${LOCAL_CONFIG_PATH}" ]]; then
  load_config "${LOCAL_CONFIG_PATH}"
  LOADED_LOCAL_CONFIG_PATH="${LOCAL_CONFIG_PATH}"
fi

read_env_file() {
  local env_file="$1"
  local line trimmed key value

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"

    [[ -z "${trimmed}" || "${trimmed}" == \#* ]] && continue
    [[ "${trimmed}" != *=* ]] && continue

    key="${trimmed%%=*}"
    value="${trimmed#*=}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    if [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
      value="${value:1:${#value}-2}"
    fi

    if [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      printf '%s=%s\0' "${key}" "${value}"
    fi
  done < "${env_file}"
}

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

current_hour() {
  local raw_hour
  raw_hour="$(TZ="${WARMUP_TIMEZONE:-}" date +%H)"
  printf '%d\n' "$((10#${raw_hour}))"
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
  if [[ "${minutes_ago}" -eq 0 ]]; then
    format_epoch "${now_epoch}" +%F
    return 0
  fi

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
    if (( delta <= catchup_minutes && delta < best_delta )); then
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
  mkdir -p "${state_dir}"
  temp_path="${state_path}.$$"
  now_epoch="$(current_epoch)"
  {
    printf 'LAST_TRIGGER_SLOT=%s\n' "${slot}"
    printf 'LAST_TRIGGER_EPOCH=%s\n' "${now_epoch}"
  } > "${temp_path}"
  mv "${temp_path}" "${state_path}"
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

  min_minutes="${WARMUP_MIN_WINDOW_MINUTES:-300}"
  if ! [[ "${min_minutes}" =~ ^[0-9]+$ ]]; then
    min_minutes=300
  fi

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

config_value() {
  local name="$1"
  printf '%s\n' "${!name:-}"
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

append_model_arg() {
  local provider="$1"
  local model="$2"

  [[ -z "${model}" ]] && return 0

  case "${provider}" in
    codex | gemini | claude)
      arg_list+=(--model "${model}")
      ;;
    *)
      arg_list+=(--model "${model}")
      ;;
  esac
}

prepare_provider_command() {
  local provider="$1"
  local model="$2"
  local prompt="$3"
  local first_arg

  # Intentional word splitting: config args are simple CLI flags.
  # shellcheck disable=SC2206
  arg_list=(${args})

  first_arg="${arg_list[0]:-}"
  case "${provider}" in
    codex)
      if [[ "${first_arg}" != "exec" && "${first_arg}" != "e" ]]; then
        arg_list=(exec --skip-git-repo-check --ephemeral "${arg_list[@]}")
      fi
      append_model_arg "${provider}" "${model}"
      arg_list+=("${prompt}")
      ;;
    gemini)
      append_model_arg "${provider}" "${model}"
      if [[ " ${arg_list[*]} " != *" --prompt "* && " ${arg_list[*]} " != *" -p "* ]]; then
        arg_list+=(--prompt "${prompt}")
      fi
      ;;
    claude)
      append_model_arg "${provider}" "${model}"
      ;;
    *)
      append_model_arg "${provider}" "${model}"
      arg_list+=("${prompt}")
      ;;
  esac
}

run_provider() {
  local provider="$1"
  local prefix path args model credential_path env_file prompt run_dir configured_workdir status
  local remove_run_dir start_seconds duration_seconds output_path failure_detail failure_log_lines
  local -a arg_list env_pairs

  prefix="$(printf '%s' "${provider}" | tr '[:lower:]' '[:upper:]')"
  path="$(expand_path "$(config_value "${prefix}_PATH")")"
  args="$(config_value "${prefix}_ARGS")"
  model="$(config_value "${prefix}_MODEL")"
  credential_path="$(expand_path "$(config_value "${prefix}_CREDENTIAL_PATH")")"
  env_file="$(expand_path "$(config_value "${prefix}_ENV_FILE")")"
  configured_workdir="$(expand_path "$(config_value "${prefix}_WORKDIR")")"
  prompt="${WARMUP_PROMPT:-${DEFAULT_WARMUP_PROMPT}}"

  if [[ -z "${path}" ]]; then
    path="${provider}"
  fi

  if [[ -n "${credential_path}" && ! -f "${credential_path}" ]]; then
    echo "[${provider}] No credentials found at ${credential_path}. Run the CLI login first." >&2
    append_warmup_log "${provider}" "skip" "missing_credentials" "0" "0" "No credentials found at ${credential_path}."
    return 0
  fi

  env_pairs=()
  if [[ -n "${env_file}" ]]; then
    if [[ ! -f "${env_file}" ]]; then
      echo "[${provider}] Env file not found: ${env_file}" >&2
      append_warmup_log "${provider}" "skip" "missing_env_file" "0" "0" "Env file not found: ${env_file}."
      return 0
    fi

    while IFS= read -r -d '' pair; do
      env_pairs+=("${pair}")
    done < <(read_env_file "${env_file}")
  fi

  if ! command -v "${path}" >/dev/null 2>&1 && [[ ! -x "${path}" ]]; then
    echo "[${provider}] Command not found: ${path}" >&2
    append_warmup_log "${provider}" "skip" "command_not_found" "0" "0" "Command not found: ${path}."
    return 0
  fi

  prepare_provider_command "${provider}" "${model}" "${prompt}"

  remove_run_dir=false
  if [[ -n "${configured_workdir}" ]]; then
    mkdir -p "${configured_workdir}"
    run_dir="${configured_workdir}"
  else
    run_dir="$(mktemp -d)"
    remove_run_dir=true
  fi

  echo "[${provider}] Sending warmup prompt..."
  append_warmup_log "${provider}" "start" "running" "0" "0" "Starting warmup command."
  start_seconds="$(date +%s)"
  output_path="$(mktemp)"
  set +e
  if [[ "${provider}" == "claude" ]]; then
    (cd "${run_dir}" && printf '%s' "${prompt}" | env -u GITHUB_TOKEN "${env_pairs[@]}" "${path}" "${arg_list[@]}") 2>&1 | tee "${output_path}"
    status=${PIPESTATUS[0]}
  else
    (cd "${run_dir}" && env -u GITHUB_TOKEN "${env_pairs[@]}" "${path}" "${arg_list[@]}") 2>&1 | tee "${output_path}"
    status=${PIPESTATUS[0]}
  fi
  duration_seconds="$(( $(date +%s) - start_seconds ))"
  set -e
  if [[ "${remove_run_dir}" == "true" ]]; then
    rm -rf "${run_dir}"
  fi

  if [[ ${status} -eq 0 ]]; then
    echo "[${provider}] Warmup complete."
    append_warmup_log "${provider}" "finish" "success" "${status}" "${duration_seconds}" "Warmup complete."
  else
    failure_log_lines="$(positive_integer_or_default "${WARMUP_FAILURE_LOG_LINES:-20}" 20)"
    failure_detail="$(tail -n "${failure_log_lines}" "${output_path}" | tr '\r\n\t' '   ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
    if [[ -z "${failure_detail}" ]]; then
      failure_detail="No provider output captured."
    fi
    echo "[${provider}] Warmup exited with status ${status}."
    append_warmup_log "${provider}" "finish" "failed" "${status}" "${duration_seconds}" "Warmup exited with status ${status}. Output tail: ${failure_detail}"
  fi
  rm -f "${output_path}"
  return "${status}"
}

run_once() {
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

  local provider all_providers_succeeded
  all_providers_succeeded=true
  IFS=',' read -r -a provider_list <<< "${WARMUP_PROVIDERS:-codex}"
  for provider in "${provider_list[@]}"; do
    provider="${provider// /}"
    [[ -z "${provider}" ]] && continue
    if ! run_provider "${provider}"; then
      all_providers_succeeded=false
    fi
  done
  if [[ "${all_providers_succeeded}" == "true" ]]; then
    record_schedule_trigger "${CURRENT_SCHEDULE_SLOT}"
    append_warmup_log "local" "finish" "complete" "0" "0" "Warmup run finished."
  else
    append_warmup_log "local" "finish" "failed" "1" "0" "One or more provider warmups failed; schedule slot was left retryable."
    return 1
  fi
}

if [[ "${MODE}" == "schedule" ]]; then
  while true; do
    slot="$(current_schedule_slot || true)"
    if [[ -n "${slot}" && "${slot}" != "$(state_value LAST_TRIGGER_SLOT)" ]]; then
      run_once
    fi
    sleep "${WARMUP_POLL_SECONDS:-60}"
  done
fi

run_once
