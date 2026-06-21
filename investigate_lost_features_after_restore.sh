#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
APP_SUPPORT="$HOME/Library/Application Support/VroidOverlay"
RUNTIME="$APP_SUPPORT/local_agent_runtime"
MAIN="$PROJECT/Sources/VroidOverlay/main.m"
APP="$PROJECT/build/VroidOverlay.app"
SAFE_KIT_FILE="$PROJECT/latest_tuli_feature_rescue_kit_SAFE_NO_UI.txt"
OUT="$PROJECT/lost_features_after_restore_debug_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$OUT"

echo "== Investigando qué se perdió después del restore =="
echo "OUT=$OUT"
echo ""

echo "== 1. Kit seguro detectado =="
{
  echo "SAFE_KIT_FILE=$SAFE_KIT_FILE"
  if [ -f "$SAFE_KIT_FILE" ]; then
    KIT="$(cat "$SAFE_KIT_FILE")"
    echo "KIT=$KIT"
    if [ -d "$KIT" ]; then
      echo "KIT exists: YES"
      find "$KIT" -maxdepth 4 -type f -print | sort
    else
      echo "KIT exists: NO"
    fi
  else
    echo "SAFE_KIT_FILE missing"
  fi
} > "$OUT/kit_status.txt" 2>&1

echo "== 2. Estado de main.m restaurado =="
{
  echo "MAIN=$MAIN"
  stat -f "%Sm | %z bytes | %N" -t "%Y-%m-%d %H:%M:%S" "$MAIN" || true

  echo ""
  echo "---- class boundaries ----"
  grep -nE "^@interface|^@implementation|^@end|#pragma mark" "$MAIN" || true

  echo ""
  echo "---- TTS / Kokoro / speech refs ----"
  grep -nE "vroidSpeakText|vroidStopSpeaking|speech_start|speech_end|VROID_TTS_PROVIDER|VROID_KOKORO|KOKORO|kokoro|v1/audio/speech|afplay|NSTask| say |speechTask|AVSpeech|NSSpeech|response_format|mp3|wav" "$MAIN" || true

  echo ""
  echo "---- Memory refs in main.m ----"
  grep -nE "conversation_memory|short_term|medium_term|long_term|pinned_facts|vroidLoadConversation|vroidSaveConversation|vroidAppendConversation|vroidChatMessagesForUserPrompt|memory|remember|recuerd" "$MAIN" || true

  echo ""
  echo "---- Bridge/event refs in main.m ----"
  grep -nE "openclaw_stream|openclaw|bubble_show|text_delta|emotion_hint|speech_start|speech_end|overlay_event|poll_line|dispatch|json_parse|apply_emotion" "$MAIN" || true

  echo ""
  echo "---- UI/dialog/bubble refs, solo para detectar, no modificar ----"
  grep -nE "bubble|dialog|speechBubble|textView|NSTextView|NSTextField|label|Command|Music|Workflows|menu|dashboard|todo|task" "$MAIN" || true

  echo ""
  echo "---- SceneKit/model refs, solo diagnóstico ----"
  grep -nE "AI.usdc|loadModelAtURL|SCNView|SCNScene|SCNNode|SCNCamera|centerAndFitNode|rotationNode|floatNode|modelContainer|camera|pointOfView|FaceCamera|FixedLookRotation|Preview|Snapshot|flattenedClone" "$MAIN" || true
} > "$OUT/main_feature_refs.txt" 2>&1

echo "== 3. Build test =="
{
  cd "$PROJECT"
  echo "Running bash build.sh..."
  bash build.sh
} > "$OUT/build_test.txt" 2>&1 || true

echo "== 4. App bundle / recursos =="
{
  echo "APP=$APP"
  ls -ld "$APP" 2>/dev/null || true
  ls -lh "$APP/Contents/MacOS" 2>/dev/null || true

  echo ""
  echo "---- Info.plist ----"
  plutil -p "$APP/Contents/Info.plist" 2>/dev/null || true

  echo ""
  echo "---- AI.usdc in project/app ----"
  find "$PROJECT" "$APP_SUPPORT" -name "AI.usdc" -print 2>/dev/null | sort | while read -r f; do
    ls -lh "$f"
    shasum -a 256 "$f" || true
  done

  echo ""
  echo "---- resources in app ----"
  find "$APP/Contents" -maxdepth 5 -type f \
    \( -iname "*.usdc" -o -iname "*.usd" -o -iname "*.usdz" -o -iname "*.png" -o -iname "*.jpg" -o -iname "*.json" -o -iname "*.plist" \) \
    -print 2>/dev/null | sort | while read -r f; do
      ls -lh "$f"
    done
} > "$OUT/app_bundle_resources.txt" 2>&1

echo "== 5. Memoria / tareas / runtime actual =="
{
  echo "---- conversation_memory.json ----"
  if [ -f "$APP_SUPPORT/conversation_memory.json" ]; then
    python3 - <<PY
import json
from pathlib import Path
p=Path("$APP_SUPPORT/conversation_memory.json")
print("path:", p)
print("size:", p.stat().st_size)
try:
    data=json.loads(p.read_text())
    print("json: OK")
    print("keys:", list(data.keys()))
    for k in ["short_term","medium_term","long_term","pinned_facts"]:
        v=data.get(k)
        print(k, type(v).__name__, len(v) if isinstance(v, list) else "n/a")
    print(json.dumps(data, ensure_ascii=False, indent=2))
except Exception as e:
    print("json: FAIL", repr(e))
PY
  else
    echo "MISSING conversation_memory.json"
  fi

  echo ""
  echo "---- agent_state.json ----"
  if [ -f "$RUNTIME/agent_state.json" ]; then
    python3 - <<PY
import json
from pathlib import Path
p=Path("$RUNTIME/agent_state.json")
print("path:", p)
print("size:", p.stat().st_size)
try:
    data=json.loads(p.read_text())
    print("json: OK")
    print("keys:", list(data.keys()))
    print("recent_lines:", len(data.get("recent_lines", []) or []))
    print("recent_actions:", len(data.get("recent_actions", []) or []))
    print("pinned_facts:", len(data.get("pinned_facts", []) or []))
    print(json.dumps(data, ensure_ascii=False, indent=2))
except Exception as e:
    print("json: FAIL", repr(e))
PY
  else
    echo "MISSING agent_state.json"
  fi

  echo ""
  echo "---- personality.yaml ----"
  cat "$RUNTIME/personality.yaml" 2>/dev/null || echo "MISSING personality.yaml"

  echo ""
  echo "---- tuli_tasks.json ----"
  if [ -f "$APP_SUPPORT/tuli_tasks.json" ]; then
    python3 - <<PY
import json
from pathlib import Path
p=Path("$APP_SUPPORT/tuli_tasks.json")
print("path:", p)
print("size:", p.stat().st_size)
try:
    data=json.loads(p.read_text())
    print("json: OK")
    print("tasks:", len(data.get("tasks", []) if isinstance(data, dict) else []))
    print(json.dumps(data, ensure_ascii=False, indent=2))
except Exception as e:
    print("json: FAIL", repr(e))
PY
  else
    echo "MISSING tuli_tasks.json"
  fi

  echo ""
  echo "---- tasks CLI source/runtime ----"
  ls -lh "$PROJECT/local_agent/tasks_store.py" "$PROJECT/local_agent/tuli_tasks.py" 2>/dev/null || true
  ls -lh "$RUNTIME/tasks_store.py" "$RUNTIME/tuli_tasks.py" 2>/dev/null || true

  echo ""
  echo "---- tasks summary ----"
  python3 "$PROJECT/local_agent/tuli_tasks.py" summary 2>&1 || true
  python3 "$RUNTIME/tuli_tasks.py" summary 2>&1 || true
} > "$OUT/memory_tasks_runtime.txt" 2>&1

echo "== 6. Bridge / daemon / LaunchAgent =="
{
  echo "---- bridge files ----"
  for f in \
    "$PROJECT/openclaw_vroid_bridge.py" \
    "$APP_SUPPORT/openclaw_vroid_bridge.py" \
    "$RUNTIME/openclaw_vroid_bridge.py"
  do
    echo ""
    echo "==== $f ===="
    if [ -f "$f" ]; then
      ls -lh "$f"
      grep -nE "speech_start|bubble_show|text_delta|emotion_hint|speech_end|openclaw_stream|argparse|--text|--emotion|--bubble" "$f" | head -80 || true
    else
      echo "MISSING"
    fi
  done

  echo ""
  echo "---- daemon file refs ----"
  DAEMON="$RUNTIME/vroid_agent_daemon.py"
  if [ -f "$DAEMON" ]; then
    ls -lh "$DAEMON"
    grep -nE "qwen3|ollama|agent_state|personality|pinned_facts|tasks_store|tuli_tasks|task_summary|openclaw_vroid_bridge|local_events|openclaw_stream|random_curiosity|forced_event|prompt|model_name|model_provider" "$DAEMON" || true
  else
    echo "MISSING daemon"
  fi

  echo ""
  echo "---- launchagent ----"
  PLIST="$HOME/Library/LaunchAgents/com.inma.vroid.localagent.plist"
  if [ -f "$PLIST" ]; then
    plutil -p "$PLIST" || cat "$PLIST"
  else
    echo "MISSING plist"
  fi

  echo ""
  echo "---- launchctl ----"
  launchctl list | grep -iE "vroid|tuli|localagent" || true
  launchctl print "gui/$UID/com.inma.vroid.localagent" 2>/dev/null | sed -n '1,160p' || true

  echo ""
  echo "---- processes ----"
  ps aux | grep -iE "VroidOverlay|vroid_agent_daemon|openclaw|ollama|kokoro|uvicorn|python|afplay|say" | grep -v grep || true
} > "$OUT/bridge_daemon_launchagent.txt" 2>&1

echo "== 7. Kokoro / modelo de voz / modelo texto =="
{
  echo "---- Kokoro server ----"
  curl -sS http://127.0.0.1:8880/v1/models 2>&1 | head -80 || true
  echo ""
  curl -sS http://127.0.0.1:8880/v1/audio/voices 2>&1 | head -80 || true
  echo ""

  echo "---- port 8880 ----"
  lsof -nP -iTCP:8880 -sTCP:LISTEN || true

  echo ""
  echo "---- Ollama ----"
  curl -sS http://127.0.0.1:11434/api/tags 2>&1 | head -120 || true
  echo ""
  lsof -nP -iTCP:11434 -sTCP:LISTEN || true

  echo ""
  echo "---- expected model references ----"
  grep -RInE "qwen3:1.7b|model_provider|model_name|ollama|KOKORO|af_bella|VROID_TTS_PROVIDER" \
    "$RUNTIME" "$PROJECT/local_agent" "$APP_SUPPORT/conversation_memory.json" "$RUNTIME/personality.yaml" \
    2>/dev/null || true
} > "$OUT/kokoro_ollama_models.txt" 2>&1

echo "== 8. Comparar contra kit seguro, si existe =="
{
  if [ -f "$SAFE_KIT_FILE" ]; then
    KIT="$(cat "$SAFE_KIT_FILE")"
    echo "KIT=$KIT"

    if [ -d "$KIT" ]; then
      echo ""
      echo "---- diff memory ----"
      diff -u "$KIT/files/conversation_memory.json" "$APP_SUPPORT/conversation_memory.json" 2>/dev/null || true

      echo ""
      echo "---- diff tasks ----"
      diff -u "$KIT/files/tuli_tasks.json" "$APP_SUPPORT/tuli_tasks.json" 2>/dev/null || true

      echo ""
      echo "---- diff agent_state ----"
      diff -u "$KIT/files/agent_state.json" "$RUNTIME/agent_state.json" 2>/dev/null || true

      echo ""
      echo "---- diff personality ----"
      diff -u "$KIT/files/personality.yaml" "$RUNTIME/personality.yaml" 2>/dev/null || true

      echo ""
      echo "---- diff task scripts ----"
      diff -u "$KIT/files/local_agent/tasks_store.py" "$PROJECT/local_agent/tasks_store.py" 2>/dev/null || true
      diff -u "$KIT/files/local_agent/tuli_tasks.py" "$PROJECT/local_agent/tuli_tasks.py" 2>/dev/null || true

      echo ""
      echo "---- diff bridge ----"
      diff -u "$KIT/files/openclaw_vroid_bridge.project.py" "$PROJECT/openclaw_vroid_bridge.py" 2>/dev/null || true
    else
      echo "KIT directory missing"
    fi
  else
    echo "No SAFE KIT file"
  fi
} > "$OUT/diff_against_safe_kit.txt" 2>&1

echo "== 9. Logs recientes =="
{
  echo "---- overlay_debug.log ----"
  tail -260 "$APP_SUPPORT/overlay_debug.log" 2>/dev/null || true

  echo ""
  echo "---- agent.log ----"
  tail -260 "$RUNTIME/logs/agent.log" 2>/dev/null || true

  echo ""
  echo "---- launchd err/out ----"
  tail -180 "$RUNTIME/logs/launchd.err.log" 2>/dev/null || true
  tail -180 "$RUNTIME/logs/launchd.out.log" 2>/dev/null || true

  echo ""
  echo "---- openclaw_stream ----"
  tail -160 "$APP_SUPPORT/openclaw_stream.jsonl" 2>/dev/null || true
} > "$OUT/recent_logs.txt" 2>&1

echo "== 10. Veredicto automático =="
python3 - <<PY > "$OUT/verdict.txt"
import json, re, subprocess
from pathlib import Path

project = Path("/Users/inma/Documents/Vroid")
app = Path.home() / "Library/Application Support/VroidOverlay"
runtime = app / "local_agent_runtime"
main = project / "Sources/VroidOverlay/main.m"
kit_file = project / "latest_tuli_feature_rescue_kit_SAFE_NO_UI.txt"

main_text = main.read_text(errors="replace") if main.exists() else ""

def exists(p): return "OK" if Path(p).exists() else "MISSING"

def json_ok(p):
    p = Path(p)
    if not p.exists(): return "MISSING"
    try:
        json.loads(p.read_text())
        return "OK"
    except Exception as e:
        return "BAD_JSON"

def has(text, *terms):
    return any(t.lower() in text.lower() for t in terms)

print("Lost Features After Restore Verdict")
print()

print("Core files:")
print("- main.m:", exists(main))
print("- built app:", exists(project / "build/VroidOverlay.app/Contents/MacOS/VroidOverlay"))
print("- conversation_memory.json:", json_ok(app / "conversation_memory.json"))
print("- agent_state.json:", json_ok(runtime / "agent_state.json"))
print("- tuli_tasks.json:", json_ok(app / "tuli_tasks.json"))
print("- source tasks_store.py:", exists(project / "local_agent/tasks_store.py"))
print("- runtime tasks_store.py:", exists(runtime / "tasks_store.py"))
print("- project bridge:", exists(project / "openclaw_vroid_bridge.py"))
print("- runtime bridge:", exists(runtime / "openclaw_vroid_bridge.py"))
print("- personality.yaml:", exists(runtime / "personality.yaml"))
print()

print("main.m capabilities detected:")
print("- OpenClaw stream/events:", has(main_text, "openclaw_stream", "speech_start", "bubble_show", "text_delta", "emotion_hint"))
print("- conversation memory in app:", has(main_text, "conversation_memory", "vroidLoadConversation", "vroidSaveConversation"))
print("- Kokoro TTS support:", has(main_text, "VROID_TTS_PROVIDER", "v1/audio/speech", "VROID_KOKORO", "afplay"))
print("- macOS say/NSTask speech:", has(main_text, "NSTask", "say", "speechTask"))
print("- task/todo UI or task refs:", has(main_text, "tuli_tasks", "tasks_store", "todo", "task_summary"))
print("- SceneKit/model refs:", has(main_text, "SCNView", "SCNScene", "AI.usdc", "loadModelAtURL"))
print()

bad_terms = ["Luma", "José", "Jose", "20 de julio", "Independencia de México", "Never call yourself Tuli"]
for label, path in [
    ("conversation_memory", app / "conversation_memory.json"),
    ("agent_state", runtime / "agent_state.json"),
    ("personality", runtime / "personality.yaml"),
]:
    txt = path.read_text(errors="replace") if path.exists() else ""
    found = [b for b in bad_terms if b.lower() in txt.lower()]
    print(f"- poison in {label}:", found if found else "none")

print()
print("Build:")
bt = Path("$OUT/build_test.txt").read_text(errors="replace")
print("OK" if "error:" not in bt.lower() else "FAIL")
if "error:" in bt.lower():
    for line in bt.splitlines()[-40:]:
        print(line)

print()
print("Safe kit:")
if kit_file.exists():
    print(kit_file.read_text().strip())
else:
    print("missing")

print()
print("Next: use detailed files:")
for f in [
    "main_feature_refs.txt",
    "memory_tasks_runtime.txt",
    "bridge_daemon_launchagent.txt",
    "kokoro_ollama_models.txt",
    "diff_against_safe_kit.txt",
    "recent_logs.txt",
]:
    print("-", Path("$OUT") / f)
PY

zip -qr "$OUT.zip" "$OUT"

echo ""
echo "== DONE =="
echo "Folder: $OUT"
echo "ZIP: $OUT.zip"
echo ""
echo "==== VERDICT ===="
cat "$OUT/verdict.txt"
echo ""
echo "$OUT.zip" | pbcopy
echo "Ruta del ZIP copiada al portapapeles."
