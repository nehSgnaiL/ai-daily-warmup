#!/usr/bin/env bash

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

    if [[ ${#value} -ge 2 ]] && { [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]] || [[ "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; }; then
      value="${value:1:${#value}-2}"
    fi

    if [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      printf '%s=%s\0' "${key}" "${value}"
    fi
  done < "${env_file}"
}

load_config() {
  local config_file="$1" config_pair
  [[ -f "${config_file}" && -r "${config_file}" ]] || {
    echo "Config file is not readable: ${config_file}" >&2
    return 1
  }
  while IFS= read -r -d '' config_pair; do
    printf -v "${config_pair%%=*}" '%s' "${config_pair#*=}"
  done < <(read_env_file "${config_file}")
}

load_warmup_config() {
  load_config "${CONFIG_PATH}" || return 1
  local config_dir repo_root local_config
  config_dir="$(dirname "${CONFIG_PATH}")"
  repo_root="$(cd "${config_dir}/.." && pwd)" || return 1
  local_config="${WARMUP_LOCAL_CONFIG_PATH:-${repo_root}/local/local.env}"
  LOADED_LOCAL_CONFIG_PATH=""
  if [[ -f "${local_config}" ]]; then
    load_config "${local_config}" || return 1
    LOADED_LOCAL_CONFIG_PATH="${local_config}"
  fi
}
