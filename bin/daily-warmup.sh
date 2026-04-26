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
    local log_path log_dir timestamp temp_path
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
    tail -n 100 "${log_path}" > "${temp_path}" && mv "${temp_path}" "${log_path}"
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
  local config_dir
  config_dir="$(dirname "${CONFIG_PATH}")"
  printf '%s\n' "${config_dir}/local.env"
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

current_hour() {
  local raw_hour
  raw_hour="$(TZ="${WARMUP_TIMEZONE:-}" date +%H)"
  printf '%d\n' "$((10#${raw_hour}))"
}

schedule_matches() {
  if [[ "${WARMUP_SCHEDULE_ENABLED:-true}" != "true" ]]; then
    return 0
  fi

  local hours hour
  hours="${WARMUP_HOURS:-8,13,18}"
  hours="${hours//[[:space:]]/}"
  hours=",${hours},"
  hour="$(current_hour)"
  [[ "${hours}" == *",${hour},"* ]]
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
  tail -n 100 "${log_path}" > "${temp_path}" && mv "${temp_path}" "${log_path}" || true
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
  local remove_run_dir start_seconds duration_seconds
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
  set +e
  if [[ "${provider}" == "claude" ]]; then
    (cd "${run_dir}" && printf '%s' "${prompt}" | env -u GITHUB_TOKEN "${env_pairs[@]}" "${path}" "${arg_list[@]}")
  else
    (cd "${run_dir}" && env -u GITHUB_TOKEN "${env_pairs[@]}" "${path}" "${arg_list[@]}")
  fi
  status=$?
  duration_seconds="$(( $(date +%s) - start_seconds ))"
  set -e
  if [[ "${remove_run_dir}" == "true" ]]; then
    rm -rf "${run_dir}"
  fi

  if [[ ${status} -eq 0 ]]; then
    echo "[${provider}] Warmup complete."
    append_warmup_log "${provider}" "finish" "success" "${status}" "${duration_seconds}" "Warmup complete."
  else
    echo "[${provider}] Warmup exited with status ${status}."
    append_warmup_log "${provider}" "finish" "failed" "${status}" "${duration_seconds}" "Warmup exited with status ${status}."
  fi
}

run_once() {
  if [[ -n "${LOADED_LOCAL_CONFIG_PATH}" ]]; then
    append_warmup_log "local" "init" "started" "0" "0" "Warmup run started. Config: ${CONFIG_PATH}; local override: ${LOADED_LOCAL_CONFIG_PATH}."
  else
    append_warmup_log "local" "init" "started" "0" "0" "Warmup run started. Config: ${CONFIG_PATH}; no local override."
  fi
  if ! schedule_matches; then
    echo "[local] Current hour is outside configured schedule."
    append_warmup_log "local" "skip" "outside_schedule" "0" "0" "Current hour is outside configured schedule."
    append_warmup_log "local" "finish" "complete" "0" "0" "Warmup run finished outside schedule."
    return 0
  fi

  local provider
  IFS=',' read -r -a provider_list <<< "${WARMUP_PROVIDERS:-codex}"
  for provider in "${provider_list[@]}"; do
    provider="${provider// /}"
    [[ -z "${provider}" ]] && continue
    run_provider "${provider}" || true
  done
  append_warmup_log "local" "finish" "complete" "0" "0" "Warmup run finished."
}

if [[ "${MODE}" == "schedule" ]]; then
  last_run_key=""
  while true; do
    hour="$(current_hour)"
    today="$(TZ="${WARMUP_TIMEZONE:-}" date +%F)"
    run_key="${today}-${hour}"
    if schedule_matches && [[ "${run_key}" != "${last_run_key}" ]]; then
      run_once
      last_run_key="${run_key}"
    fi
    sleep "${WARMUP_POLL_SECONDS:-60}"
  done
fi

run_once
