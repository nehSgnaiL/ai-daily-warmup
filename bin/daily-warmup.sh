#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="${1:-config/default.env}"
MODE="${2:-once}"
DEFAULT_WARMUP_PROMPT="Warmup. Don't think, just reply: OK"

if [[ ! -f "${CONFIG_PATH}" ]]; then
  echo "[local] Config file not found: ${CONFIG_PATH}" >&2
  exit 1
fi

load_config() {
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
  done < "${CONFIG_PATH}"
}

load_config

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
  raw_hour="$(TZ="${WARMUP_TIMEZONE:-$(date +%Z)}" date +%H)"
  printf '%d\n' "$((10#${raw_hour}))"
}

schedule_matches() {
  if [[ "${WARMUP_SCHEDULE_ENABLED:-true}" != "true" ]]; then
    return 0
  fi

  local hours hour
  hours=",${WARMUP_HOURS:-8,13,18},"
  hour="$(current_hour)"
  [[ "${hours}" == *",${hour},"* ]]
}

config_value() {
  local name="$1"
  printf '%s\n' "${!name:-}"
}

warmup_log_path() {
  expand_path "${WARMUP_LOG_PATH:-~/.local/state/ai-daily-warmup/warmup.log}"
}

append_warmup_log() {
  local provider="$1"
  local result="$2"
  local status="$3"
  local log_path log_dir temp_path timestamp

  log_path="$(warmup_log_path)"
  [[ -z "${log_path}" ]] && return 0

  log_dir="$(dirname "${log_path}")"
  mkdir -p "${log_dir}"
  timestamp="$(TZ="${WARMUP_TIMEZONE:-$(date +%Z)}" date '+%Y-%m-%dT%H:%M:%S%z')"
  printf '%s\t%s\t%s\t%s\n' "${timestamp}" "${provider}" "${result}" "${status}" >> "${log_path}"

  temp_path="${log_path}.$$"
  tail -n 100 "${log_path}" > "${temp_path}" && mv "${temp_path}" "${log_path}"
}

run_provider() {
  local provider="$1"
  local prefix path args model credential_path env_file prompt run_dir configured_workdir status
  local remove_run_dir
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
    return 0
  fi

  env_pairs=()
  if [[ -n "${env_file}" ]]; then
    if [[ ! -f "${env_file}" ]]; then
      echo "[${provider}] Env file not found: ${env_file}" >&2
      return 0
    fi

    while IFS= read -r -d '' pair; do
      env_pairs+=("${pair}")
    done < <(read_env_file "${env_file}")
  fi

  if ! command -v "${path}" >/dev/null 2>&1 && [[ ! -x "${path}" ]]; then
    echo "[${provider}] Command not found: ${path}" >&2
    return 0
  fi

  # Intentional word splitting: config args are simple CLI flags.
  # shellcheck disable=SC2206
  arg_list=(${args})
  if [[ -n "${model}" ]]; then
    arg_list+=(--model "${model}")
  fi

  remove_run_dir=false
  if [[ -n "${configured_workdir}" ]]; then
    mkdir -p "${configured_workdir}"
    run_dir="${configured_workdir}"
  else
    run_dir="$(mktemp -d)"
    remove_run_dir=true
  fi

  echo "[${provider}] Sending warmup prompt..."
  set +e
  if [[ "${provider}" == "claude" ]]; then
    (cd "${run_dir}" && printf '%s' "${prompt}" | env -u GITHUB_TOKEN "${env_pairs[@]}" "${path}" "${arg_list[@]}")
  else
    (cd "${run_dir}" && env -u GITHUB_TOKEN "${env_pairs[@]}" "${path}" "${prompt}" "${arg_list[@]}")
  fi
  status=$?
  set -e
  if [[ "${remove_run_dir}" == "true" ]]; then
    rm -rf "${run_dir}"
  fi

  if [[ ${status} -eq 0 ]]; then
    echo "[${provider}] Warmup complete."
    append_warmup_log "${provider}" "success" "${status}"
  else
    echo "[${provider}] Warmup exited with status ${status}."
    append_warmup_log "${provider}" "failed" "${status}"
  fi
}

run_once() {
  if ! schedule_matches; then
    echo "[local] Current hour is outside configured schedule."
    return 0
  fi

  local provider
  IFS=',' read -r -a provider_list <<< "${WARMUP_PROVIDERS:-codex}"
  for provider in "${provider_list[@]}"; do
    provider="${provider// /}"
    [[ -z "${provider}" ]] && continue
    run_provider "${provider}" || true
  done
}

if [[ "${MODE}" == "schedule" ]]; then
  last_run_key=""
  while true; do
    hour="$(current_hour)"
    today="$(TZ="${WARMUP_TIMEZONE:-$(date +%Z)}" date +%F)"
    run_key="${today}-${hour}"
    if schedule_matches && [[ "${run_key}" != "${last_run_key}" ]]; then
      run_once
      last_run_key="${run_key}"
    fi
    sleep "${WARMUP_POLL_SECONDS:-60}"
  done
fi

run_once
