#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="${1:-config/default.env}"
TASK_NAME="${TASK_NAME:-ai-daily-warmup}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER_PATH="${REPO_ROOT}/bin/daily-warmup.sh"

usage() {
  cat <<EOF
Usage:
  bin/install-scheduler.sh [config/default.env]
  bin/install-scheduler.sh --uninstall
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ "${1:-}" == "--uninstall" ]]; then
  if [[ "$(uname -s)" == "Darwin" ]]; then
    PLIST_PATH="${HOME}/Library/LaunchAgents/com.${TASK_NAME}.plist"
    launchctl bootout "gui/$(id -u)" "${PLIST_PATH}" >/dev/null 2>&1 || true
    rm -f "${PLIST_PATH}"
    echo "Removed LaunchAgent: com.${TASK_NAME}"
  elif command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now "${TASK_NAME}.timer" >/dev/null 2>&1 || true
    rm -f "${HOME}/.config/systemd/user/${TASK_NAME}.service" "${HOME}/.config/systemd/user/${TASK_NAME}.timer"
    systemctl --user daemon-reload
    echo "Removed systemd user timer: ${TASK_NAME}.timer"
  else
    echo "No supported scheduler found to uninstall." >&2
    exit 1
  fi
  exit 0
fi

if [[ "${CONFIG_PATH}" != /* ]]; then
  CONFIG_PATH="${REPO_ROOT}/${CONFIG_PATH}"
fi

if [[ ! -f "${CONFIG_PATH}" ]]; then
  echo "Config file not found: ${CONFIG_PATH}" >&2
  exit 1
fi

if [[ ! -f "${RUNNER_PATH}" ]]; then
  echo "Runner not found: ${RUNNER_PATH}" >&2
  exit 1
fi

config_value() {
  local key="$1"
  awk -F= -v key="${key}" '
    $0 !~ /^[[:space:]]*#/ && $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
      value=$2
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      gsub(/^"|"$/, "", value)
      print value
      exit
    }
  ' "${CONFIG_PATH}"
}

IFS=',' read -r -a HOURS <<< "$(config_value WARMUP_HOURS)"
if [[ ${#HOURS[@]} -eq 0 || -z "${HOURS[0]}" ]]; then
  HOURS=(8 13 18)
fi

for index in "${!HOURS[@]}"; do
  HOURS[$index]="${HOURS[$index]// /}"
  if ! [[ "${HOURS[$index]}" =~ ^[0-9]+$ ]] || (( HOURS[$index] < 0 || HOURS[$index] > 23 )); then
    echo "Invalid hour in WARMUP_HOURS: ${HOURS[$index]}" >&2
    exit 1
  fi
done

if [[ "$(uname -s)" == "Darwin" ]]; then
  PLIST_PATH="${HOME}/Library/LaunchAgents/com.${TASK_NAME}.plist"
  mkdir -p "$(dirname "${PLIST_PATH}")"

  {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.${TASK_NAME}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${RUNNER_PATH}</string>
    <string>${CONFIG_PATH}</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${REPO_ROOT}</string>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Minute</key>
    <integer>0</integer>
  </dict>
  <key>StandardOutPath</key>
  <string>${HOME}/Library/Logs/${TASK_NAME}.log</string>
  <key>StandardErrorPath</key>
  <string>${HOME}/Library/Logs/${TASK_NAME}.log</string>
</dict>
</plist>
EOF
  } > "${PLIST_PATH}"

  launchctl bootout "gui/$(id -u)" "${PLIST_PATH}" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "${PLIST_PATH}"
  echo "Installed LaunchAgent: com.${TASK_NAME}"
  echo "Warmup hours from config: ${HOURS[*]}"
elif command -v systemctl >/dev/null 2>&1; then
  SYSTEMD_DIR="${HOME}/.config/systemd/user"
  mkdir -p "${SYSTEMD_DIR}"

  cat > "${SYSTEMD_DIR}/${TASK_NAME}.service" <<EOF
[Unit]
Description=Warm up configured AI CLIs

[Service]
Type=oneshot
WorkingDirectory=${REPO_ROOT}
ExecStart=/usr/bin/env bash ${RUNNER_PATH} ${CONFIG_PATH}
EOF

  {
    cat <<EOF
[Unit]
Description=Run ${TASK_NAME} on the configured warmup hours

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
EOF
  } > "${SYSTEMD_DIR}/${TASK_NAME}.timer"

  systemctl --user daemon-reload
  systemctl --user enable --now "${TASK_NAME}.timer"
  echo "Installed systemd user timer: ${TASK_NAME}.timer"
  echo "Warmup hours from config: ${HOURS[*]}"
else
  echo "No supported scheduler found. Use './bin/daily-warmup.sh ${CONFIG_PATH} schedule' instead." >&2
  exit 1
fi
