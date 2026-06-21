#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
APP_SUPPORT="$HOME/Library/Application Support/VroidOverlay"
RUNTIME="$APP_SUPPORT/local_agent_runtime"
KIT="$PROJECT/tuli_feature_rescue_kit_safe_no_ui_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$KIT/files"
mkdir -p "$KIT/reference_only"

echo "== Saving SAFE Tuli feature rescue kit =="
echo "KIT=$KIT"
echo ""
echo "Este kit NO toca main.m, diálogo, burbuja, SceneKit, cámara ni UI."

copy_if_exists() {
  local src="$1"
  local dst="$2"
  if [ -f "$src" ]; then
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    echo "saved: $src"
  else
    echo "missing: $src"
  fi
}

echo ""
echo "== 1. Save reference-only main.m =="
copy_if_exists "$PROJECT/Sources/VroidOverlay/main.m" "$KIT/reference_only/main_current_reference_DO_NOT_RESTORE_AUTOMATICALLY.m"

echo ""
echo "== 2. Save memory/state/tasks/runtime features =="
copy_if_exists "$APP_SUPPORT/conversation_memory.json" "$KIT/files/conversation_memory.json"
copy_if_exists "$APP_SUPPORT/tuli_tasks.json" "$KIT/files/tuli_tasks.json"
copy_if_exists "$RUNTIME/agent_state.json" "$KIT/files/agent_state.json"
copy_if_exists "$RUNTIME/personality.yaml" "$KIT/files/personality.yaml"

copy_if_exists "$PROJECT/local_agent/tasks_store.py" "$KIT/files/local_agent/tasks_store.py"
copy_if_exists "$PROJECT/local_agent/tuli_tasks.py" "$KIT/files/local_agent/tuli_tasks.py"
copy_if_exists "$RUNTIME/tasks_store.py" "$KIT/files/runtime/tasks_store.py"
copy_if_exists "$RUNTIME/tuli_tasks.py" "$KIT/files/runtime/tuli_tasks.py"

copy_if_exists "$PROJECT/openclaw_vroid_bridge.py" "$KIT/files/openclaw_vroid_bridge.project.py"
copy_if_exists "$APP_SUPPORT/openclaw_vroid_bridge.py" "$KIT/files/openclaw_vroid_bridge.appsupport.py"
copy_if_exists "$RUNTIME/openclaw_vroid_bridge.py" "$KIT/files/openclaw_vroid_bridge.runtime.py"

copy_if_exists "$HOME/Library/LaunchAgents/com.inma.vroid.localagent.plist" "$KIT/files/com.inma.vroid.localagent.plist"

echo ""
echo "== 3. Save Kokoro status/reference =="
{
  echo "KOKORO_REPO=/Users/inma/Documents/Vroid/kokoro-fastapi"
  echo "KOKORO_URL=http://127.0.0.1:8880/v1/audio/speech"
  echo "KOKORO_VOICE=af_bella"
  echo "TULI_TEXT_MODEL=qwen3:1.7b"
  echo ""
  echo "== Port 8880 =="
  lsof -nP -iTCP:8880 -sTCP:LISTEN || true
  echo ""
  echo "== Kokoro process =="
  ps aux | grep -iE "kokoro|uvicorn|api.src.main" | grep -v grep || true
  echo ""
  echo "== Kokoro model files =="
  ls -lh /Users/inma/Documents/Vroid/kokoro-fastapi/api/src/models/v1_0 2>/dev/null || true
  echo ""
  echo "== Kokoro voices =="
  ls -lh /Users/inma/Documents/Vroid/kokoro-fastapi/api/src/voices/v1_0 2>/dev/null | head -80 || true
} > "$KIT/files/kokoro_reference.txt"

echo ""
echo "== 4. Create SAFE reapply script =="
cat > "$KIT/reapply_tuli_features_after_restore_SAFE_NO_UI.sh" <<'REBASH'
#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
APP_SUPPORT="$HOME/Library/Application Support/VroidOverlay"
RUNTIME="$APP_SUPPORT/local_agent_runtime"
KIT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "== Reapply Tuli features SAFE NO UI =="
echo "KIT_DIR=$KIT_DIR"
echo ""
echo "Este script NO toca:"
echo "- main.m"
echo "- cuadro de diálogo / burbuja"
echo "- SceneKit"
echo "- cámara"
echo "- modelo 3D"
echo "- dashboard visual"
echo ""

mkdir -p "$APP_SUPPORT"
mkdir -p "$RUNTIME"
mkdir -p "$PROJECT/local_agent"

restore_file() {
  local src="$1"
  local dst="$2"
  if [ -f "$src" ]; then
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    echo "restored: $dst"
  else
    echo "missing in kit: $src"
  fi
}

echo ""
echo "== 1. Restore memory/state/tasks only =="
restore_file "$KIT_DIR/files/conversation_memory.json" "$APP_SUPPORT/conversation_memory.json"
restore_file "$KIT_DIR/files/tuli_tasks.json" "$APP_SUPPORT/tuli_tasks.json"
restore_file "$KIT_DIR/files/agent_state.json" "$RUNTIME/agent_state.json"
restore_file "$KIT_DIR/files/personality.yaml" "$RUNTIME/personality.yaml"

restore_file "$KIT_DIR/files/local_agent/tasks_store.py" "$PROJECT/local_agent/tasks_store.py"
restore_file "$KIT_DIR/files/local_agent/tuli_tasks.py" "$PROJECT/local_agent/tuli_tasks.py"
restore_file "$KIT_DIR/files/runtime/tasks_store.py" "$RUNTIME/tasks_store.py"
restore_file "$KIT_DIR/files/runtime/tuli_tasks.py" "$RUNTIME/tuli_tasks.py"

chmod +x "$PROJECT/local_agent/tuli_tasks.py" 2>/dev/null || true
chmod +x "$RUNTIME/tuli_tasks.py" 2>/dev/null || true

echo ""
echo "== 2. Restore bridge only =="
restore_file "$KIT_DIR/files/openclaw_vroid_bridge.project.py" "$PROJECT/openclaw_vroid_bridge.py"
restore_file "$KIT_DIR/files/openclaw_vroid_bridge.appsupport.py" "$APP_SUPPORT/openclaw_vroid_bridge.py"
restore_file "$KIT_DIR/files/openclaw_vroid_bridge.runtime.py" "$RUNTIME/openclaw_vroid_bridge.py"

chmod +x "$PROJECT/openclaw_vroid_bridge.py" 2>/dev/null || true
chmod +x "$APP_SUPPORT/openclaw_vroid_bridge.py" 2>/dev/null || true
chmod +x "$RUNTIME/openclaw_vroid_bridge.py" 2>/dev/null || true

echo ""
echo "== 3. Re-clean identity memory =="
python3 - <<'PY'
import json
from pathlib import Path

app = Path.home() / "Library/Application Support/VroidOverlay"
runtime = app / "local_agent_runtime"

conv_path = app / "conversation_memory.json"
state_path = runtime / "agent_state.json"

bad = ["Luma", "José", "Jose", "20 de julio", "Independencia de México", "Never call yourself Tuli"]

pinned_app = [
    "The avatar's name is Tuli.",
    "Tuli is the user's local floating desktop companion.",
    "Tuli should be concise, warm, playful, and non-invasive.",
    "Tuli should not invent facts.",
    "Tuli should say she does not know when context is missing.",
    "Tuli should help the user track tasks, projects, and next actions."
]

pinned_daemon = [
    "The avatar's name is Tuli.",
    "Tuli is a tiny floating desktop companion.",
    "Tuli should speak briefly, warmly, naturally, and with light playfulness.",
    "Tuli should not claim to be the user, a generic assistant, a model, or a system.",
    "Tuli should not invent facts when she does not know something.",
    "Tuli should help the user track tasks, projects, and next actions."
]

def poisoned(x):
    s = json.dumps(x, ensure_ascii=False).lower()
    return any(b.lower() in s for b in bad)

try:
    conv = json.loads(conv_path.read_text()) if conv_path.exists() else {}
except Exception:
    conv = {}

conv.setdefault("short_term", [])
conv.setdefault("medium_term", [])
conv.setdefault("long_term", [])
conv["short_term"] = [x for x in conv.get("short_term", []) if not poisoned(x)][-20:]
conv["medium_term"] = [x for x in conv.get("medium_term", []) if not poisoned(x)][-20:]
conv["long_term"] = [x for x in conv.get("long_term", []) if not poisoned(x)][-20:]
conv["pinned_facts"] = pinned_app
conv_path.write_text(json.dumps(conv, indent=2, ensure_ascii=False) + "\n")

try:
    state = json.loads(state_path.read_text()) if state_path.exists() else {}
except Exception:
    state = {}

state["recent_lines"] = [x for x in state.get("recent_lines", []) if not poisoned(x)][-30:]
state["recent_actions"] = [x for x in state.get("recent_actions", []) if not poisoned(x)][-80:]
state["pinned_facts"] = pinned_daemon
state_path.write_text(json.dumps(state, indent=2, ensure_ascii=False) + "\n")

print("identity memory cleaned")
PY

echo ""
echo "== 4. Verify tasks =="
python3 "$PROJECT/local_agent/tuli_tasks.py" summary || true

echo ""
echo "== 5. Restart local agent only =="
launchctl bootout "gui/$UID" "$HOME/Library/LaunchAgents/com.inma.vroid.localagent.plist" 2>/dev/null || true
sleep 1
launchctl bootstrap "gui/$UID" "$HOME/Library/LaunchAgents/com.inma.vroid.localagent.plist" 2>/dev/null || true
launchctl kickstart -k "gui/$UID/com.inma.vroid.localagent" 2>/dev/null || true

echo ""
echo "== DONE SAFE NO UI =="
echo "Ahora compila/abre la app restaurada aparte. Este script no tocó la UI."
REBASH

chmod +x "$KIT/reapply_tuli_features_after_restore_SAFE_NO_UI.sh"

echo ""
echo "== 5. Create Kokoro run helper, no UI patch =="
cat > "$KIT/run_restored_app_with_kokoro_env_ONLY.sh" <<'RUNBASH'
#!/usr/bin/env bash
set -euo pipefail

cd /Users/inma/Documents/Vroid

pkill -f VroidOverlay 2>/dev/null || true
sleep 1

VROID_DEBUG=1 \
VROID_TTS_PROVIDER=kokoro \
VROID_KOKORO_URL="http://127.0.0.1:8880/v1/audio/speech" \
VROID_KOKORO_VOICE="af_bella" \
./build/VroidOverlay.app/Contents/MacOS/VroidOverlay
RUNBASH

chmod +x "$KIT/run_restored_app_with_kokoro_env_ONLY.sh"

cat > "$KIT/README_SAFE_NO_UI.txt" <<EOF
SAFE Tuli Feature Rescue Kit

Created: $(date)

This kit deliberately DOES NOT touch:
- Sources/VroidOverlay/main.m
- dialog/bubble UI
- SceneKit
- camera
- model loading
- dashboard visual code

It restores only:
- conversation_memory.json
- agent_state.json
- personality.yaml
- tuli_tasks.json
- tasks_store.py
- tuli_tasks.py
- OpenClaw bridge copies
- local LaunchAgent restart
- Kokoro reference/env helper

Usage after restoring a visible-head main.m:

1. Build restored app:
   cd /Users/inma/Documents/Vroid
   bash build.sh

2. Reapply non-UI features:
   $KIT/reapply_tuli_features_after_restore_SAFE_NO_UI.sh

3. Run app with Kokoro env only:
   $KIT/run_restored_app_with_kokoro_env_ONLY.sh

If restored main.m does not have Kokoro TTS support, do not patch UI.
Patch only vroidSpeakText / TTS section later.
EOF

zip -qr "$KIT.zip" "$KIT"

echo ""
echo "== DONE SAFE KIT =="
echo "KIT: $KIT"
echo "ZIP: $KIT.zip"
echo "$KIT" > "$PROJECT/latest_tuli_feature_rescue_kit_SAFE_NO_UI.txt"
echo "$KIT.zip" | pbcopy
echo "Ruta del ZIP copiada al portapapeles."
