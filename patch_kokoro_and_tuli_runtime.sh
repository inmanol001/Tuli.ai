#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
KOKORO="$PROJECT/kokoro-fastapi"
LOCAL_AGENT_SRC="$PROJECT/local_agent"
APP_SUPPORT="$HOME/Library/Application Support/VroidOverlay"
LOCAL_AGENT_RUN="$APP_SUPPORT/local_agent_runtime"
PLIST_ID="com.inma.vroid.localagent"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_ID}.plist"
BACKUP="$PROJECT/backups_patch_runtime_$(date +%Y%m%d_%H%M%S)"

echo "== Patch Kokoro + Tuli runtime =="
echo "Backup: $BACKUP"

mkdir -p "$BACKUP"
mkdir -p "$APP_SUPPORT"
mkdir -p "$HOME/Library/LaunchAgents"

echo ""
echo "== 1. Backup =="
[ -d "$LOCAL_AGENT_SRC" ] && cp -R "$LOCAL_AGENT_SRC" "$BACKUP/local_agent.backup"
[ -f "$PROJECT/repair_and_start_kokoro.sh" ] && cp "$PROJECT/repair_and_start_kokoro.sh" "$BACKUP/repair_and_start_kokoro.sh.backup"
[ -f "$PLIST_PATH" ] && cp "$PLIST_PATH" "$BACKUP/${PLIST_ID}.plist.backup"

echo ""
echo "== 2. Stop old LaunchAgent =="
launchctl bootout "gui/$UID/${PLIST_ID}" >/dev/null 2>&1 || true
pkill -f "vroid_agent_daemon.py" 2>/dev/null || true
sleep 1

echo ""
echo "== 3. Patch Kokoro script: skip download if model exists =="
if [ -f "$PROJECT/repair_and_start_kokoro.sh" ]; then
  python3 - <<'PY'
from pathlib import Path

p = Path("/Users/inma/Documents/Vroid/repair_and_start_kokoro.sh")
s = p.read_text()

old = 'uv run --no-sync python docker/scripts/download_model.py --output api/src/models/v1_0'

new = '''if [ -s "api/src/models/v1_0/kokoro-v1_0.pth" ] && [ -s "api/src/models/v1_0/config.json" ]; then
  echo "Modelo Kokoro ya existe en api/src/models/v1_0. Saltando descarga."
else
  uv run --no-sync python docker/scripts/download_model.py --output api/src/models/v1_0
fi'''

if old in s:
    s = s.replace(old, new)
    p.write_text(s)
    print("OK: Kokoro download guard added.")
else:
    print("WARN: no encontré la línea exacta de download_model.py; no modifiqué Kokoro script.")
PY
else
  echo "WARN: no existe $PROJECT/repair_and_start_kokoro.sh"
fi

echo ""
echo "== 4. Patch local agent source: Luma -> Tuli =="
if [ ! -d "$LOCAL_AGENT_SRC" ]; then
  echo "ERROR: no existe $LOCAL_AGENT_SRC"
  exit 1
fi

python3 - <<'PY'
from pathlib import Path

base = Path("/Users/inma/Documents/Vroid/local_agent")
targets = [
    base / "vroid_agent_daemon.py",
    base / "run_once_test.py",
    base / "send_event.py",
    base / "personality.yaml",
    base / "agent_state.json",
    base / "phrase_templates.json",
]

for p in targets:
    if not p.exists():
        continue

    s = p.read_text(encoding="utf-8", errors="replace")
    original = s

    # Rename identity references that are still hardcoded.
    s = s.replace("You are Luma,", "You are Tuli,")
    s = s.replace("You are Luma", "You are Tuli")
    s = s.replace("Luma local autonomy daemon", "Tuli local autonomy daemon")
    s = s.replace('"agent_name": "Luma"', '"agent_name": "Tuli"')
    s = s.replace("'agent_name': 'Luma'", "'agent_name': 'Tuli'")

    # Keep negative rules readable but avoid prefixes being only Luma.
    s = s.replace('("Luma:", "Luma -", "Luma –")', '("Tuli:", "Tuli -", "Tuli –", "Luma:", "Luma -", "Luma –")')

    # Generic replacements in comments/descriptions only.
    s = s.replace("Luma", "Tuli")

    if s != original:
        p.write_text(s, encoding="utf-8")
        print("patched", p)
PY

echo ""
echo "== 5. Verify source still has old names =="
grep -RIn "Luma\|José\|Jose" "$LOCAL_AGENT_SRC" \
  --exclude-dir=logs \
  --exclude="*.pyc" \
  || echo "OK: no old names found in local_agent source."

echo ""
echo "== 6. Create runtime copy outside Documents =="
rm -rf "$LOCAL_AGENT_RUN"
mkdir -p "$LOCAL_AGENT_RUN"
cp -R "$LOCAL_AGENT_SRC"/. "$LOCAL_AGENT_RUN"/

# Copy bridge too, because some send_event scripts may look for it nearby.
if [ -f "$PROJECT/openclaw_vroid_bridge.py" ]; then
  cp "$PROJECT/openclaw_vroid_bridge.py" "$LOCAL_AGENT_RUN/openclaw_vroid_bridge.py"
fi

mkdir -p "$LOCAL_AGENT_RUN/logs"
touch "$LOCAL_AGENT_RUN/logs/agent.log"
touch "$LOCAL_AGENT_RUN/logs/launchd.out.log"
touch "$LOCAL_AGENT_RUN/logs/launchd.err.log"

chmod -R u+rwX "$LOCAL_AGENT_RUN"
chmod +x "$LOCAL_AGENT_RUN"/*.py 2>/dev/null || true

echo ""
echo "== 7. Patch runtime paths if needed =="
python3 - <<'PY'
from pathlib import Path

run = Path.home() / "Library/Application Support/VroidOverlay/local_agent_runtime"
project = "/Users/inma/Documents/Vroid"

# Add PROJECT_DIR env fallback in scripts if they use parent project assumptions.
for p in [run / "send_event.py", run / "vroid_agent_daemon.py", run / "run_once_test.py"]:
    if not p.exists():
        continue
    s = p.read_text(encoding="utf-8", errors="replace")
    original = s

    # If code has literal old local_agent path, update to runtime path.
    s = s.replace("/Users/inma/Documents/Vroid/local_agent", str(run))

    # If it refers to ../openclaw_vroid_bridge.py and runtime has a copy, this is okay.
    # Also make the original project discoverable by env.
    if "PROJECT_DIR" not in s and p.name == "send_event.py":
        s = 'import os\nPROJECT_DIR = os.environ.get("VROID_PROJECT_DIR", "/Users/inma/Documents/Vroid")\n' + s

    if s != original:
        p.write_text(s, encoding="utf-8")
        print("patched runtime", p)
PY

echo ""
echo "== 8. Write LaunchAgent pointing to App Support runtime =="
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
      <string>${LOCAL_AGENT_RUN}/vroid_agent_daemon.py</string>
    </array>

    <key>WorkingDirectory</key>
    <string>${LOCAL_AGENT_RUN}</string>

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
    <string>${LOCAL_AGENT_RUN}/logs/launchd.out.log</string>

    <key>StandardErrorPath</key>
    <string>${LOCAL_AGENT_RUN}/logs/launchd.err.log</string>
  </dict>
</plist>
PLIST

chmod 644 "$PLIST_PATH"

echo ""
echo "== 9. Test daemon manually from runtime =="
cd "$LOCAL_AGENT_RUN"
python3 run_once_test.py random_curiosity || true

echo ""
echo "== 10. Load LaunchAgent =="
launchctl bootstrap "gui/$UID" "$PLIST_PATH" || true
launchctl kickstart -k "gui/$UID/${PLIST_ID}" || true
sleep 3

echo ""
echo "== 11. Status =="
launchctl list | grep "$PLIST_ID" || true

echo ""
echo "== 12. Logs =="
echo "--- runtime agent.log ---"
tail -80 "$LOCAL_AGENT_RUN/logs/agent.log" || true

echo ""
echo "--- runtime launchd.err.log ---"
tail -80 "$LOCAL_AGENT_RUN/logs/launchd.err.log" || true

echo ""
echo "--- runtime launchd.out.log ---"
tail -80 "$LOCAL_AGENT_RUN/logs/launchd.out.log" || true

echo ""
echo "== 13. Kokoro model check =="
if [ -s "$KOKORO/api/src/models/v1_0/kokoro-v1_0.pth" ] && [ -s "$KOKORO/api/src/models/v1_0/config.json" ]; then
  echo "OK: Kokoro model exists:"
  ls -lh "$KOKORO/api/src/models/v1_0/kokoro-v1_0.pth" "$KOKORO/api/src/models/v1_0/config.json"
else
  echo "WARN: Kokoro model/config missing."
fi

echo ""
echo "== DONE =="
echo "Runtime local agent:"
echo "$LOCAL_AGENT_RUN"
echo ""
echo "LaunchAgent:"
echo "$PLIST_PATH"
echo ""
echo "Backup:"
echo "$BACKUP"
