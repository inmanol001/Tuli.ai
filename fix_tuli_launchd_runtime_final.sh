#!/usr/bin/env bash
set -euo pipefail

APP_SUPPORT="$HOME/Library/Application Support/VroidOverlay"
RUNTIME="$APP_SUPPORT/local_agent_runtime"
PROJECT="/Users/inma/Documents/Vroid"
SRC="$PROJECT/local_agent"
PLIST_ID="com.inma.vroid.localagent"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_ID}.plist"
BACKUP="$PROJECT/backups_tuli_launchd_final_$(date +%Y%m%d_%H%M%S)"

echo "== Fix Tuli LaunchAgent final =="
echo "Runtime: $RUNTIME"
echo "Backup: $BACKUP"

mkdir -p "$BACKUP"
mkdir -p "$RUNTIME/logs"

echo ""
echo "== 1. Stop old launchd jobs hard =="
launchctl bootout "gui/$UID/${PLIST_ID}" >/dev/null 2>&1 || true
launchctl remove "$PLIST_ID" >/dev/null 2>&1 || true
pkill -f "vroid_agent_daemon.py" 2>/dev/null || true
sleep 1

echo ""
echo "== 2. Backup current files =="
[ -d "$SRC" ] && cp -R "$SRC" "$BACKUP/local_agent_source.backup"
[ -d "$RUNTIME" ] && cp -R "$RUNTIME" "$BACKUP/local_agent_runtime.backup"
[ -f "$PLIST_PATH" ] && cp "$PLIST_PATH" "$BACKUP/${PLIST_ID}.plist.backup"

echo ""
echo "== 3. Rebuild runtime copy =="
rm -rf "$RUNTIME"
mkdir -p "$RUNTIME"
cp -R "$SRC"/. "$RUNTIME"/
mkdir -p "$RUNTIME/logs"

if [ -f "$PROJECT/openclaw_vroid_bridge.py" ]; then
  cp "$PROJECT/openclaw_vroid_bridge.py" "$RUNTIME/openclaw_vroid_bridge.py"
fi

chmod -R u+rwX "$RUNTIME"
chmod +x "$RUNTIME"/*.py 2>/dev/null || true

echo ""
echo "== 4. Fix Python files safely =="
python3 - <<'PY'
from pathlib import Path
import re

runtime = Path.home() / "Library/Application Support/VroidOverlay/local_agent_runtime"

def fix_future_import_position(text: str) -> str:
    lines = text.splitlines()
    future_lines = [line for line in lines if line.startswith("from __future__ import")]
    if not future_lines:
        return text

    lines = [line for line in lines if not line.startswith("from __future__ import")]

    shebang = []
    encoding = []

    while lines and lines[0].startswith("#!"):
        shebang.append(lines.pop(0))

    while lines and re.match(r"#.*coding[:=]", lines[0]):
        encoding.append(lines.pop(0))

    new_lines = shebang + encoding + future_lines + lines
    return "\n".join(new_lines) + ("\n" if text.endswith("\n") else "")

for p in runtime.glob("*.py"):
    text = p.read_text(encoding="utf-8", errors="replace")
    old = text

    # Remove accidental injected header from prior patch if present.
    text = text.replace(
        'import os\nPROJECT_DIR = os.environ.get("VROID_PROJECT_DIR", "/Users/inma/Documents/Vroid")\n',
        ''
    )

    # Identity cleanup.
    text = text.replace("You are Luma,", "You are Tuli,")
    text = text.replace("You are Luma", "You are Tuli")
    text = text.replace("Luma local autonomy daemon", "Tuli local autonomy daemon")
    text = text.replace("Luma:", "Tuli:")
    text = text.replace("Luma -", "Tuli -")
    text = text.replace("Luma –", "Tuli –")
    text = text.replace("Luma", "Tuli")

    text = fix_future_import_position(text)

    if text != old:
        p.write_text(text, encoding="utf-8")
        print("patched", p)

# Also patch JSON/YAML configs in runtime.
for p in list(runtime.glob("*.json")) + list(runtime.glob("*.yaml")) + list(runtime.glob("*.yml")):
    text = p.read_text(encoding="utf-8", errors="replace")
    old = text
    text = text.replace('"agent_name": "Luma"', '"agent_name": "Tuli"')
    text = text.replace("You are Luma", "You are Tuli")
    text = text.replace("Luma", "Tuli")
    if text != old:
        p.write_text(text, encoding="utf-8")
        print("patched", p)
PY

echo ""
echo "== 5. Verify compile =="
python3 -m py_compile "$RUNTIME"/*.py

echo ""
echo "== 6. Clean logs =="
: > "$RUNTIME/logs/agent.log"
: > "$RUNTIME/logs/launchd.out.log"
: > "$RUNTIME/logs/launchd.err.log"

echo ""
echo "== 7. Write absolutely clean plist =="
cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>${PLIST_ID}</string>

    <key>ProgramArguments</key>
    <array>
      <string>/usr/bin/python3</string>
      <string>${RUNTIME}/vroid_agent_daemon.py</string>
    </array>

    <key>WorkingDirectory</key>
    <string>${RUNTIME}</string>

    <key>EnvironmentVariables</key>
    <dict>
      <key>VROID_PROJECT_DIR</key>
      <string>${PROJECT}</string>
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
    <string>${RUNTIME}/logs/launchd.out.log</string>

    <key>StandardErrorPath</key>
    <string>${RUNTIME}/logs/launchd.err.log</string>
  </dict>
</plist>
PLIST

chmod 644 "$PLIST_PATH"

echo ""
echo "== 8. Confirm plist does NOT point to Documents local_agent =="
grep -n "vroid_agent_daemon.py\|WorkingDirectory\|Documents/Vroid/local_agent\|local_agent_runtime" "$PLIST_PATH" || true

if grep -q "/Users/inma/Documents/Vroid/local_agent/vroid_agent_daemon.py" "$PLIST_PATH"; then
  echo "ERROR: plist still points to old blocked path."
  exit 1
fi

echo ""
echo "== 9. Manual runtime test =="
cd "$RUNTIME"
python3 run_once_test.py random_curiosity || true

echo ""
echo "== 10. Load clean plist =="
launchctl bootstrap "gui/$UID" "$PLIST_PATH"
launchctl kickstart -k "gui/$UID/${PLIST_ID}"
sleep 3

echo ""
echo "== 11. Status =="
launchctl list | grep "$PLIST_ID" || true

echo ""
echo "== 12. Logs =="
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
echo "Runtime: $RUNTIME"
echo "Plist: $PLIST_PATH"
echo "Backup: $BACKUP"
