#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST_ID="com.inma.vroid.localagent"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_ID}.plist"
PYTHON_BIN="/usr/bin/python3"
DAEMON_PATH="${SCRIPT_DIR}/vroid_agent_daemon.py"
LOG_DIR="${SCRIPT_DIR}/logs"

mkdir -p "$HOME/Library/LaunchAgents"
mkdir -p "$LOG_DIR"

cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PLIST_ID}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${PYTHON_BIN}</string>
    <string>${DAEMON_PATH}</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${SCRIPT_DIR}</string>
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
launchctl bootstrap "gui/$UID" "$PLIST_PATH"
launchctl enable "gui/$UID/${PLIST_ID}" >/dev/null 2>&1 || true
launchctl kickstart -k "gui/$UID/${PLIST_ID}" >/dev/null 2>&1 || true

printf 'Installed %s\n' "$PLIST_PATH"
