#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_SUPPORT="${HOME}/Library/Application Support/VroidOverlay"
RUNTIME_DIR="${APP_SUPPORT}/local_agent_runtime"
PLIST_ID="com.inma.vroid.localagent"
PLIST_PATH="${HOME}/Library/LaunchAgents/${PLIST_ID}.plist"
PYTHON_BIN="/usr/bin/python3"
LOG_DIR="${RUNTIME_DIR}/logs"

bash "${SCRIPT_DIR}/sync_runtime.sh"

mkdir -p "${HOME}/Library/LaunchAgents"
mkdir -p "${LOG_DIR}"

cat > "${PLIST_PATH}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PLIST_ID}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${PYTHON_BIN}</string>
    <string>${RUNTIME_DIR}/vroid_agent_daemon.py</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${RUNTIME_DIR}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>VROID_PROJECT_DIR</key>
    <string>${PROJECT_DIR}</string>
    <key>VROID_APP_SUPPORT</key>
    <string>${APP_SUPPORT}</string>
    <key>PYTHONUNBUFFERED</key>
    <string>1</string>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${HOME}/.local/bin</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/launchd.err.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$UID/${PLIST_ID}" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$UID" "${PLIST_PATH}"
launchctl enable "gui/$UID/${PLIST_ID}" >/dev/null 2>&1 || true
launchctl kickstart -k "gui/$UID/${PLIST_ID}" >/dev/null 2>&1 || true

printf 'Installed %s\n' "${PLIST_PATH}"
printf 'Runtime synced to %s\n' "${RUNTIME_DIR}"
