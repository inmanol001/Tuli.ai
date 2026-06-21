#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
APP_SUPPORT="$HOME/Library/Application Support/VroidOverlay"
RUNTIME="$APP_SUPPORT/local_agent_runtime"
MAIN="$PROJECT/Sources/VroidOverlay/main.m"
OUT="$PROJECT/lost_interaction_mouse_debug_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$OUT"

echo "== Investigando features perdidos: escribirle + repulsión mouse + voz/memoria =="
echo "OUT=$OUT"

echo ""
echo "== 1. Estado del main actual =="
{
  echo "MAIN=$MAIN"
  stat -f "%Sm | %z bytes | %N" -t "%Y-%m-%d %H:%M:%S" "$MAIN" || true

  echo ""
  echo "---- class boundaries ----"
  grep -nE "^@interface|^@implementation|^@end|#pragma mark" "$MAIN" || true

  echo ""
  echo "---- escribirle / input / command refs ----"
  grep -nE "NSTextField|NSTextView|textField|input|command|submit|send|returnPressed|controlTextDidEndEditing|controlTextDidChange|keyDown|insertText|doCommandBySelector|bubble|dialog|prompt|userPrompt|chat|message|type|typed|Command|Workflows|Music|quick_action" "$MAIN" || true

  echo ""
  echo "---- mouse / hover / tracking / repel refs ----"
  grep -nE "mouse|cursor|NSEvent|tracking|NSTrackingArea|mouseMoved|mouseEntered|mouseExited|mouseDragged|acceptsMouseMovedEvents|addTrackingArea|updateTrackingAreas|convertPoint|locationInWindow|repel|repulsion|avoid|evade|distance|proximity|magnet|push|float|position|setFrameOrigin|setFrame|drag" "$MAIN" || true

  echo ""
  echo "---- Kokoro / speech refs ----"
  grep -nE "vroidSpeakText|vroidStopSpeaking|NSTask|speechTask|say|afplay|curl|VROID_TTS_PROVIDER|VROID_KOKORO|kokoro|v1/audio/speech|mp3|response_format|VOICE" "$MAIN" || true

  echo ""
  echo "---- memory refs ----"
  grep -nE "conversation_memory|short_term|medium_term|long_term|pinned_facts|vroidLoadConversation|vroidSaveConversation|vroidAppendConversation|vroidChatMessagesForUserPrompt|memory|remember" "$MAIN" || true

  echo ""
  echo "---- OpenClaw bridge/event refs ----"
  grep -nE "openclaw_stream|speech_start|bubble_show|text_delta|emotion_hint|speech_end|overlay_event|json_parse|dispatch|apply_emotion|poll_line" "$MAIN" || true
} > "$OUT/current_main_feature_refs.txt" 2>&1

echo ""
echo "== 2. Buscar features en backups =="
{
  echo "---- backups disponibles ----"
  find "$PROJECT" -maxdepth 4 -type f \
    \( -name "main.m.backup" \
    -o -name "main.m.before*" \
    -o -name "main.m.current*" \
    -o -name "main.m.broken*" \
    -o -name "*.m.backup" \) \
    -print0 | while IFS= read -r -d '' f; do
      stat -f "%Sm | %z bytes | %N" -t "%Y-%m-%d %H:%M:%S" "$f"
    done | sort

  echo ""
  echo "---- feature scan per backup ----"

  find "$PROJECT" -maxdepth 4 -type f \
    \( -name "main.m.backup" \
    -o -name "main.m.before*" \
    -o -name "main.m.current*" \
    -o -name "main.m.broken*" \
    -o -name "*.m.backup" \) \
    -print0 | while IFS= read -r -d '' f; do

      echo ""
      echo "=============================="
      stat -f "%Sm | %z bytes | %N" -t "%Y-%m-%d %H:%M:%S" "$f"
      echo "=============================="

      echo "HAS_INPUT_REFS=$(grep -Eiq 'NSTextField|NSTextView|controlTextDid|keyDown|userPrompt|chat|command|submit|send|typed|quick_action' "$f" && echo YES || echo NO)"
      echo "HAS_MOUSE_REPEL_REFS=$(grep -Eiq 'mouseMoved|NSTrackingArea|tracking|acceptsMouseMovedEvents|repel|repulsion|avoid|evade|proximity|cursor|locationInWindow|setFrameOrigin' "$f" && echo YES || echo NO)"
      echo "HAS_KOKORO_REFS=$(grep -Eiq 'VROID_TTS_PROVIDER|VROID_KOKORO|kokoro|v1/audio/speech|afplay|response_format' "$f" && echo YES || echo NO)"
      echo "HAS_MEMORY_REFS=$(grep -Eiq 'conversation_memory|pinned_facts|vroidLoadConversation|vroidSaveConversation|vroidChatMessagesForUserPrompt' "$f" && echo YES || echo NO)"
      echo "HAS_OPENCLAW_REFS=$(grep -Eiq 'openclaw_stream|speech_start|bubble_show|text_delta|emotion_hint|speech_end' "$f" && echo YES || echo NO)"
      echo "HAS_SCENEKIT_REFS=$(grep -Eiq 'SCNView|SCNScene|AI.usdc|loadModelAtURL' "$f" && echo YES || echo NO)"

      echo ""
      echo "-- matching lines sample --"
      grep -nE "NSTextField|NSTextView|controlTextDid|keyDown|userPrompt|chat|command|submit|send|typed|mouseMoved|NSTrackingArea|tracking|acceptsMouseMovedEvents|repel|repulsion|avoid|evade|proximity|cursor|locationInWindow|setFrameOrigin|VROID_TTS_PROVIDER|VROID_KOKORO|kokoro|v1/audio/speech|conversation_memory|pinned_facts" "$f" | head -80 || true
  done
} > "$OUT/backup_feature_scan.txt" 2>&1

echo ""
echo "== 3. Seleccionar mejor backup candidato por features =="
python3 - <<'PY' > "$OUT/backup_feature_scores.txt"
from pathlib import Path
import re, subprocess

project = Path("/Users/inma/Documents/Vroid")

patterns = {
    "input": r"NSTextField|NSTextView|controlTextDid|keyDown|userPrompt|chat|command|submit|send|typed|quick_action",
    "mouse_repel": r"mouseMoved|NSTrackingArea|tracking|acceptsMouseMovedEvents|repel|repulsion|avoid|evade|proximity|cursor|locationInWindow|setFrameOrigin",
    "kokoro": r"VROID_TTS_PROVIDER|VROID_KOKORO|kokoro|v1/audio/speech|afplay|response_format",
    "memory": r"conversation_memory|pinned_facts|vroidLoadConversation|vroidSaveConversation|vroidChatMessagesForUserPrompt",
    "openclaw": r"openclaw_stream|speech_start|bubble_show|text_delta|emotion_hint|speech_end",
    "scenekit": r"SCNView|SCNScene|AI.usdc|loadModelAtURL",
    "bad_patch": r"vroidInvestigationDump3DState|vroidEmergencyForce|EMERGENCY_3D|INVESTIGATE_3D",
}

files = []
for pat in ["main.m.backup", "main.m.before*", "main.m.current*", "main.m.broken*", "*.m.backup"]:
    files.extend(project.glob(f"**/{pat}"))

seen = set()
rows = []
for f in files:
    if f in seen or not f.is_file():
        continue
    seen.add(f)
    try:
        text = f.read_text(errors="replace")
    except Exception:
        continue
    flags = {k: bool(re.search(v, text, re.I)) for k, v in patterns.items()}
    score = 0
    for k in ["input", "mouse_repel", "kokoro", "memory", "openclaw", "scenekit"]:
        score += int(flags[k])
    if flags["bad_patch"]:
        score -= 3
    rows.append((score, f.stat().st_mtime, f, flags, f.stat().st_size))

rows.sort(key=lambda x: (x[0], x[1]), reverse=True)

print("score | date | size | flags | file")
for score, mtime, f, flags, size in rows:
    dt = subprocess.check_output(["date", "-r", str(int(mtime)), "+%Y-%m-%d %H:%M:%S"]).decode().strip()
    good = ",".join(k for k,v in flags.items() if v)
    print(f"{score:>5} | {dt} | {size} | {good} | {f}")
PY

cat "$OUT/backup_feature_scores.txt"

echo ""
echo "== 4. Comparar main actual contra mejor backup candidato =="
BEST="$(awk -F' \\| ' 'NR==2 {print $5}' "$OUT/backup_feature_scores.txt" 2>/dev/null || true)"

{
  echo "BEST=$BEST"
  if [ -n "$BEST" ] && [ -f "$BEST" ]; then
    echo ""
    echo "---- best stats ----"
    stat -f "%Sm | %z bytes | %N" -t "%Y-%m-%d %H:%M:%S" "$BEST"

    echo ""
    echo "---- render/input/mouse/kokoro diff filtered ----"
    diff -u "$BEST" "$MAIN" | grep -nE "^[+-].*(NSTextField|NSTextView|controlTextDid|keyDown|userPrompt|chat|command|submit|send|typed|mouseMoved|NSTrackingArea|tracking|acceptsMouseMovedEvents|repel|repulsion|avoid|evade|proximity|cursor|locationInWindow|setFrameOrigin|VROID_TTS_PROVIDER|VROID_KOKORO|kokoro|v1/audio/speech|afplay|conversation_memory|pinned_facts|SCNView|SCNScene|AI.usdc|loadModelAtURL|bubble|dialog)" || true

    echo ""
    echo "---- full diff first 500 lines ----"
    diff -u "$BEST" "$MAIN" | sed -n '1,500p' || true
  else
    echo "No BEST candidate found"
  fi
} > "$OUT/diff_best_backup_vs_current.txt" 2>&1

echo ""
echo "== 5. Estado externo: memoria/tareas/Kokoro/daemon =="
{
  echo "---- tasks summary ----"
  python3 "$PROJECT/local_agent/tuli_tasks.py" summary 2>&1 || true
  python3 "$RUNTIME/tuli_tasks.py" summary 2>&1 || true

  echo ""
  echo "---- memory files ----"
  ls -lh "$APP_SUPPORT/conversation_memory.json" "$APP_SUPPORT/tuli_tasks.json" "$RUNTIME/agent_state.json" "$RUNTIME/personality.yaml" 2>/dev/null || true

  echo ""
  echo "---- Kokoro ----"
  curl -sS http://127.0.0.1:8880/v1/models 2>&1 | head -40 || true
  lsof -nP -iTCP:8880 -sTCP:LISTEN || true

  echo ""
  echo "---- daemon/bridge ----"
  launchctl list | grep -iE "vroid|tuli|localagent" || true
  ps aux | grep -iE "VroidOverlay|vroid_agent_daemon|kokoro|uvicorn|ollama" | grep -v grep || true
} > "$OUT/external_features_status.txt" 2>&1

echo ""
echo "== 6. Veredicto automático =="
{
  echo "Lost interaction/mouse features verdict"
  echo ""
  echo "Current main:"
  stat -f "%Sm | %z bytes | %N" -t "%Y-%m-%d %H:%M:%S" "$MAIN"
  echo ""
  echo "Best backup candidates:"
  sed -n '1,12p' "$OUT/backup_feature_scores.txt"
  echo ""
  echo "Current main feature refs summary:"
  echo "- input refs: $(grep -Eiq 'NSTextField|NSTextView|controlTextDid|keyDown|userPrompt|chat|command|submit|send|typed|quick_action' "$MAIN" && echo YES || echo NO)"
  echo "- mouse repel refs: $(grep -Eiq 'mouseMoved|NSTrackingArea|tracking|acceptsMouseMovedEvents|repel|repulsion|avoid|evade|proximity|cursor|locationInWindow|setFrameOrigin' "$MAIN" && echo YES || echo NO)"
  echo "- Kokoro refs: $(grep -Eiq 'VROID_TTS_PROVIDER|VROID_KOKORO|kokoro|v1/audio/speech|afplay|response_format' "$MAIN" && echo YES || echo NO)"
  echo "- memory refs: $(grep -Eiq 'conversation_memory|pinned_facts|vroidLoadConversation|vroidSaveConversation|vroidChatMessagesForUserPrompt' "$MAIN" && echo YES || echo NO)"
  echo "- OpenClaw refs: $(grep -Eiq 'openclaw_stream|speech_start|bubble_show|text_delta|emotion_hint|speech_end' "$MAIN" && echo YES || echo NO)"
  echo ""
  echo "Important files:"
  echo "$OUT/current_main_feature_refs.txt"
  echo "$OUT/backup_feature_scan.txt"
  echo "$OUT/backup_feature_scores.txt"
  echo "$OUT/diff_best_backup_vs_current.txt"
  echo "$OUT/external_features_status.txt"
} > "$OUT/verdict.txt"

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
