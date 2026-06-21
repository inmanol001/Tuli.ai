#!/usr/bin/env bash
set -euo pipefail

PLIST_ID="com.inma.vroid.localagent"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_ID}.plist"

launchctl bootout "gui/$UID/${PLIST_ID}" >/dev/null 2>&1 || true
launchctl remove "${PLIST_ID}" >/dev/null 2>&1 || true
rm -f "$PLIST_PATH"

printf 'Removed %s\n' "$PLIST_PATH"
