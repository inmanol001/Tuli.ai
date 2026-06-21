#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
APP_SUPPORT="$HOME/Library/Application Support/VroidOverlay"
RUNTIME="$APP_SUPPORT/local_agent_runtime"
BRIDGE_SRC="$PROJECT/openclaw_vroid_bridge.py"
BRIDGE_DST="$APP_SUPPORT/openclaw_vroid_bridge.py"
PLIST_ID="com.inma.vroid.localagent"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_ID}.plist"

echo "== Fix Tuli bridge path =="

echo ""
echo "== 1. Stop LaunchAgent temporarily =="
launchctl bootout "gui/$UID/${PLIST_ID}" >/dev/null 2>&1 || true
launchctl remove "$PLIST_ID" >/dev/null 2>&1 || true
pkill -f "vroid_agent_daemon.py" 2>/dev/null || true
sleep 1

echo ""
echo "== 2. Copy bridge where current scripts expect it =="
mkdir -p "$APP_SUPPORT"

if [ ! -f "$BRIDGE_SRC" ]; then
  echo "ERROR: no existe bridge source:"
  echo "$BRIDGE_SRC"
  exit 1
fi

cp "$BRIDGE_SRC" "$BRIDGE_DST"
chmod +x "$BRIDGE_DST"

echo "Bridge copiado a:"
echo "$BRIDGE_DST"

echo ""
echo "== 3. Also copy bridge inside runtime for fallback =="
cp "$BRIDGE_SRC" "$RUNTIME/openclaw_vroid_bridge.py"
chmod +x "$RUNTIME/openclaw_vroid_bridge.py"

echo ""
echo "== 4. Clear only current logs =="
mkdir -p "$RUNTIME/logs"
: > "$RUNTIME/logs/agent.log"
: > "$RUNTIME/logs/launchd.out.log"
: > "$RUNTIME/logs/launchd.err.log"

echo ""
echo "== 5. Verify plist points to runtime =="
grep -n "vroid_agent_daemon.py\|WorkingDirectory\|local_agent_runtime\|Documents/Vroid/local_agent" "$PLIST_PATH" || true

if grep -q "/Users/inma/Documents/Vroid/local_agent/vroid_agent_daemon.py" "$PLIST_PATH"; then
  echo "ERROR: plist todavía apunta al path viejo bloqueado."
  exit 1
fi

echo ""
echo "== 6. Manual run_once test =="
cd "$RUNTIME"
/usr/bin/python3 "$RUNTIME/run_once_test.py" random_curiosity || true

echo ""
echo "== 7. Reload LaunchAgent clean =="
launchctl bootstrap "gui/$UID" "$PLIST_PATH"
launchctl kickstart -k "gui/$UID/${PLIST_ID}"
sleep 4

echo ""
echo "== 8. Status =="
launchctl list | grep "$PLIST_ID" || true

echo ""
echo "== 9. Detailed launchctl print =="
launchctl print "gui/$UID/${PLIST_ID}" 2>/dev/null | sed -n '1,160p' || true

echo ""
echo "== 10. Logs =="
echo "--- err ---"
tail -80 "$RUNTIME/logs/launchd.err.log" || true

echo ""
echo "--- out ---"
tail -80 "$RUNTIME/logs/launchd.out.log" || true

echo ""
echo "--- agent ---"
tail -80 "$RUNTIME/logs/agent.log" || true

echo ""
echo "== DONE =="
echo "Bridge root: $BRIDGE_DST"
echo "Runtime: $RUNTIME"
