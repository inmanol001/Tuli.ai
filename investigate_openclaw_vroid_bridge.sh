#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
OUT="$PROJECT/openclaw_vroid_bridge_debug_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"

echo "== OpenClaw ↔ Vroid Bridge Investigation ==" | tee "$OUT/README.txt"
echo "Project: $PROJECT" | tee -a "$OUT/README.txt"
echo "Date: $(date)" | tee -a "$OUT/README.txt"
echo "User: $(whoami)" | tee -a "$OUT/README.txt"
echo "" | tee -a "$OUT/README.txt"

cd "$PROJECT"

echo "== 1. System ==" | tee "$OUT/system.txt"
{
  uname -a
  sw_vers || true
  echo "SHELL=$SHELL"
  echo "PATH=$PATH"
  date
} >> "$OUT/system.txt" 2>&1 || true

echo "== 2. Project tree ==" | tee "$OUT/project_tree.txt"
find "$PROJECT" \
  -path "$PROJECT/.build" -prune -o \
  -path "$PROJECT/build" -prune -o \
  -path "$PROJECT/backups_*" -prune -o \
  -maxdepth 6 \
  \( -type f -o -type d \) \
  | sed "s#^$PROJECT/##" \
  | sort >> "$OUT/project_tree.txt" 2>/dev/null || true

echo "== 3. Important files ==" | tee "$OUT/important_files.txt"
for f in \
  "$PROJECT/Sources/VroidOverlay/main.m" \
  "$PROJECT/openclaw_vroid_bridge.py" \
  "$PROJECT/overlay_debug.log" \
  "$PROJECT/bridge_debug.log" \
  "$PROJECT/build.sh" \
  "$PROJECT/AI.usdc"
do
  echo "---- $f ----" >> "$OUT/important_files.txt"
  if [ -e "$f" ]; then
    ls -lah "$f" >> "$OUT/important_files.txt" 2>&1 || true
    file "$f" >> "$OUT/important_files.txt" 2>&1 || true
    shasum -a 256 "$f" >> "$OUT/important_files.txt" 2>&1 || true
  else
    echo "MISSING" >> "$OUT/important_files.txt"
  fi
done

echo "== 4. Running processes ==" | tee "$OUT/processes.txt"
{
  echo "---- OpenClaw processes ----"
  ps aux | grep -iE "openclaw|gateway|codex" | grep -v grep || true

  echo ""
  echo "---- Vroid/overlay/bridge/python processes ----"
  ps aux | grep -iE "VroidOverlay|vroid|openclaw_vroid_bridge|bridge|python" | grep -v grep || true
} >> "$OUT/processes.txt" 2>&1 || true

echo "== 5. Ports / sockets ==" | tee "$OUT/ports.txt"
{
  echo "---- lsof openclaw port 18789 ----"
  lsof -nP -iTCP:18789 -sTCP:LISTEN || true

  echo ""
  echo "---- all local listening ports possibly relevant ----"
  lsof -nP -iTCP -sTCP:LISTEN | grep -iE "openclaw|python|Vroid|node|swift|18789|localhost|127.0.0.1" || true

  echo ""
  echo "---- unix sockets maybe relevant ----"
  lsof -nP -U | grep -iE "openclaw|vroid|bridge|overlay" || true
} >> "$OUT/ports.txt" 2>&1 || true

echo "== 6. OpenClaw CLI status ==" | tee "$OUT/openclaw_status.txt"
{
  echo "---- which openclaw ----"
  which openclaw || true

  echo ""
  echo "---- openclaw --version ----"
  openclaw --version || true

  echo ""
  echo "---- openclaw status ----"
  openclaw status || true

  echo ""
  echo "---- openclaw models status ----"
  openclaw models status || true

  echo ""
  echo "---- openclaw models auth list ----"
  openclaw models auth list || true
} >> "$OUT/openclaw_status.txt" 2>&1 || true

echo "== 7. OpenClaw gateway HTTP probe ==" | tee "$OUT/openclaw_gateway_probe.txt"
{
  echo "---- curl localhost:18789 ----"
  curl -sv "http://localhost:18789" --max-time 3 || true

  echo ""
  echo "---- curl 127.0.0.1:18789 ----"
  curl -sv "http://127.0.0.1:18789" --max-time 3 || true

  echo ""
  echo "---- curl possible health/status endpoints ----"
  for path in / /health /status /api/status /sessions /api/sessions; do
    echo "---- $path ----"
    curl -sS "http://127.0.0.1:18789$path" --max-time 2 || true
    echo ""
  done
} >> "$OUT/openclaw_gateway_probe.txt" 2>&1 || true

echo "== 8. OpenClaw logs ==" | tee "$OUT/openclaw_logs.txt"
{
  echo "---- /tmp/openclaw logs ----"
  ls -lah /tmp/openclaw 2>/dev/null || true

  echo ""
  echo "---- recent logs ----"
  for log in $(ls -t /tmp/openclaw/*.log 2>/dev/null | head -5); do
    echo ""
    echo "======== $log ========"
    tail -300 "$log" || true
  done
} >> "$OUT/openclaw_logs.txt" 2>&1 || true

echo "== 9. Bridge source search ==" | tee "$OUT/bridge_source_search.txt"
grep -RIn \
  --exclude-dir=.git \
  --exclude-dir=.build \
  --exclude-dir=build \
  --exclude-dir="openclaw_vroid_bridge_debug_*" \
  -E "openclaw|OpenClaw|gateway|18789|localhost|127\.0\.0\.1|socket|websocket|ws://|http://|requests|urllib|aiohttp|flask|fastapi|watch|poll|json|emotion|speech|speak|bubble|gesture|face|expression|morph|blink|mouth|viseme|signal|bridge|overlay_debug|bridge_debug|tmp|NamedPipe|NSFileHandle|DispatchSource|Timer|NSTimer" \
  "$PROJECT" > "$OUT/bridge_source_search.txt" 2>/dev/null || true

echo "== 10. main.m communication search ==" | tee "$OUT/main_communication_search.txt"
if [ -f "$PROJECT/Sources/VroidOverlay/main.m" ]; then
  grep -nE "openclaw|OpenClaw|bridge|signal|json|emotion|speech|speak|bubble|gesture|expression|morph|blink|mouth|viseme|file|read|write|Timer|NSTimer|DispatchSource|socket|http|localhost|127\.0\.0\.1|overlay_debug|bridge_debug|NSLog|tail|log" \
    "$PROJECT/Sources/VroidOverlay/main.m" > "$OUT/main_communication_search.txt" 2>&1 || true

  nl -ba "$PROJECT/Sources/VroidOverlay/main.m" > "$OUT/main_numbered.m" 2>&1 || true
fi

echo "== 11. Python bridge inspection ==" | tee "$OUT/python_bridge_inspection.txt"
{
  if [ -f "$PROJECT/openclaw_vroid_bridge.py" ]; then
    echo "---- numbered bridge ----"
    nl -ba "$PROJECT/openclaw_vroid_bridge.py"

    echo ""
    echo "---- syntax check ----"
    python3 -m py_compile "$PROJECT/openclaw_vroid_bridge.py" && echo "PYTHON SYNTAX OK" || echo "PYTHON SYNTAX FAILED"

    echo ""
    echo "---- imports ----"
    grep -nE "^import |^from " "$PROJECT/openclaw_vroid_bridge.py" || true

    echo ""
    echo "---- likely endpoints/files ----"
    grep -nE "18789|localhost|127\.0\.0\.1|http|ws://|websocket|openclaw|json|\.json|\.txt|\.log|tmp|signal|bridge" "$PROJECT/openclaw_vroid_bridge.py" || true
  else
    echo "MISSING: $PROJECT/openclaw_vroid_bridge.py"
  fi
} >> "$OUT/python_bridge_inspection.txt" 2>&1 || true

echo "== 12. App logs ==" | tee "$OUT/app_logs.txt"
{
  for log in \
    "$PROJECT/overlay_debug.log" \
    "$PROJECT/bridge_debug.log" \
    "$HOME/Library/Logs/VroidOverlay.log" \
    "$HOME/Library/Logs/overlay_debug.log" \
    "$HOME/Library/Logs/bridge_debug.log"
  do
    echo ""
    echo "======== $log ========"
    if [ -f "$log" ]; then
      tail -500 "$log"
    else
      echo "MISSING"
    fi
  done

  echo ""
  echo "---- find related logs ----"
  find "$PROJECT" "$HOME/Library/Logs" /tmp \
    -maxdepth 3 \
    -type f \
    \( -iname "*vroid*.log" -o -iname "*overlay*.log" -o -iname "*bridge*.log" -o -iname "*openclaw*.log" \) \
    2>/dev/null \
    | sort
} >> "$OUT/app_logs.txt" 2>&1 || true

echo "== 13. Signal files investigation ==" | tee "$OUT/signal_files.txt"
{
  echo "---- likely signal files in project/home/tmp ----"
  find "$PROJECT" "$HOME" /tmp \
    -maxdepth 4 \
    -type f \
    \( \
      -iname "*vroid*signal*" -o \
      -iname "*vroid*bridge*" -o \
      -iname "*openclaw*bridge*" -o \
      -iname "*overlay*signal*" -o \
      -iname "*character*.json" -o \
      -iname "*speech*.json" -o \
      -iname "*emotion*.json" -o \
      -iname "*bubble*.json" \
    \) \
    2>/dev/null \
    | sort

  echo ""
  echo "---- recent json/txt/log files in project ----"
  find "$PROJECT" \
    -maxdepth 5 \
    -type f \
    \( -iname "*.json" -o -iname "*.txt" -o -iname "*.log" \) \
    -mtime -2 \
    -print0 2>/dev/null \
    | xargs -0 ls -lah 2>/dev/null || true
} >> "$OUT/signal_files.txt" 2>&1 || true

echo "== 14. Generate local test signal candidates ==" | tee "$OUT/test_signal_candidates.txt"
cat > "$OUT/test_payload.json" <<'JSON'
{
  "text": "Hello. This is a local bridge test from the diagnostic script.",
  "emotion": "happy",
  "gesture": "talk",
  "bubble": true,
  "source": "bridge_diagnostic",
  "timestamp": "__TIMESTAMP__"
}
JSON

python3 <<'PY' "$OUT/test_payload.json"
from pathlib import Path
import sys, datetime, json
p = Path(sys.argv[1])
data = json.loads(p.read_text())
data["timestamp"] = datetime.datetime.now().isoformat()
p.write_text(json.dumps(data, indent=2))
PY

{
  echo "Test payload generated at:"
  echo "$OUT/test_payload.json"
  echo ""
  echo "Potential signal names to try manually if your app watches files:"
  echo "$PROJECT/openclaw_vroid_signal.json"
  echo "$PROJECT/vroid_signal.json"
  echo "$PROJECT/bridge_signal.json"
  echo "/tmp/openclaw_vroid_signal.json"
  echo "/tmp/vroid_overlay_signal.json"
} >> "$OUT/test_signal_candidates.txt"

echo "== 15. Optional controlled local signal test ==" | tee "$OUT/local_signal_test.txt"
{
  echo "This script does NOT overwrite app files by default."
  echo "To send a manual file signal, run one of these after reviewing:"
  echo ""
  echo "cp '$OUT/test_payload.json' '$PROJECT/openclaw_vroid_signal.json'"
  echo "cp '$OUT/test_payload.json' '$PROJECT/vroid_signal.json'"
  echo "cp '$OUT/test_payload.json' '/tmp/openclaw_vroid_signal.json'"
  echo "cp '$OUT/test_payload.json' '/tmp/vroid_overlay_signal.json'"
} >> "$OUT/local_signal_test.txt"

echo "== 16. Live monitor helper ==" | tee "$OUT/monitor_bridge_live.sh"
cat > "$OUT/monitor_bridge_live.sh" <<'MONITOR'
#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"

echo "Monitoring bridge/app/openclaw logs. Ctrl+C to stop."
echo ""

while true; do
  clear
  echo "== $(date) =="
  echo ""
  echo "== Processes =="
  ps aux | grep -iE "openclaw|VroidOverlay|openclaw_vroid_bridge|python" | grep -v grep || true

  echo ""
  echo "== Port 18789 =="
  lsof -nP -iTCP:18789 -sTCP:LISTEN || true

  echo ""
  echo "== Recent overlay log =="
  tail -20 "$PROJECT/overlay_debug.log" 2>/dev/null || true

  echo ""
  echo "== Recent bridge log =="
  tail -20 "$PROJECT/bridge_debug.log" 2>/dev/null || true

  echo ""
  echo "== Recent OpenClaw log =="
  latest="$(ls -t /tmp/openclaw/*.log 2>/dev/null | head -1 || true)"
  if [ -n "$latest" ]; then
    tail -20 "$latest"
  fi

  sleep 2
done
MONITOR
chmod +x "$OUT/monitor_bridge_live.sh"

echo "== 17. Suggested contract file ==" | tee "$OUT/suggested_contract.json"
cat > "$OUT/suggested_contract.json" <<'JSON'
{
  "version": 1,
  "type": "character_event",
  "id": "unique-event-id",
  "timestamp": "2026-06-20T22:00:00",
  "source": "openclaw",
  "text": "Text the character should say.",
  "emotion": "neutral|happy|sad|thinking|surprised|angry",
  "gesture": "idle|talk|nod|blink|look_left|look_right",
  "bubble": {
    "visible": true,
    "text": "Text shown above the head"
  },
  "speech": {
    "enabled": true,
    "voice": "local_tts",
    "audio_path": "/Users/inma/LocalAI/out.wav"
  }
}
JSON

echo "== 18. Final summary generator ==" | tee "$OUT/diagnostic_summary.txt"
{
  echo "OpenClaw gateway:"
  if lsof -nP -iTCP:18789 -sTCP:LISTEN >/dev/null 2>&1; then
    echo "  OK: port 18789 is listening."
  else
    echo "  WARNING: port 18789 is not listening."
  fi

  echo ""
  echo "Vroid app process:"
  if ps aux | grep -i "VroidOverlay" | grep -v grep >/dev/null 2>&1; then
    echo "  OK: VroidOverlay process is running."
  else
    echo "  WARNING: VroidOverlay process not found."
  fi

  echo ""
  echo "Bridge process:"
  if ps aux | grep -i "openclaw_vroid_bridge.py" | grep -v grep >/dev/null 2>&1; then
    echo "  OK: openclaw_vroid_bridge.py process is running."
  else
    echo "  WARNING: openclaw_vroid_bridge.py process not found."
  fi

  echo ""
  echo "Important next files to inspect:"
  echo "  $OUT/openclaw_status.txt"
  echo "  $OUT/openclaw_gateway_probe.txt"
  echo "  $OUT/python_bridge_inspection.txt"
  echo "  $OUT/main_communication_search.txt"
  echo "  $OUT/app_logs.txt"
  echo "  $OUT/signal_files.txt"
} >> "$OUT/diagnostic_summary.txt"

zip -qr "$OUT.zip" "$OUT"

echo ""
echo "DIAGNÓSTICO COMPLETO."
echo "Carpeta: $OUT"
echo "ZIP: $OUT.zip"
echo ""
echo "Archivos clave:"
echo "1) $OUT/diagnostic_summary.txt"
echo "2) $OUT/openclaw_status.txt"
echo "3) $OUT/openclaw_gateway_probe.txt"
echo "4) $OUT/python_bridge_inspection.txt"
echo "5) $OUT/main_communication_search.txt"
echo "6) $OUT/app_logs.txt"
echo "7) $OUT/signal_files.txt"
echo ""
echo "Monitor en vivo:"
echo "$OUT/monitor_bridge_live.sh"
echo ""
echo "Para monitorear mientras pruebas OpenClaw:"
echo "bash '$OUT/monitor_bridge_live.sh'"
