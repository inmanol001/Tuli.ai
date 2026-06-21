#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
APP_SUPPORT="$HOME/Library/Application Support/VroidOverlay"
RUNTIME="$APP_SUPPORT/local_agent_runtime"
OUT="$PROJECT/tuli_speech_debug_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$OUT"

echo "== Tuli Speech Engine Inspection =="
echo "OUT=$OUT"

echo ""
echo "== 1. Search speech/TTS code references =="
grep -RIn \
  --exclude-dir=.git \
  --exclude-dir=build \
  --exclude-dir=.build \
  --exclude-dir=.venv \
  --exclude-dir=kokoro-fastapi/.venv \
  --exclude-dir="backups_*" \
  --exclude-dir="tuli_*_debug_*" \
  -E "speech|speak|tts|voice|kokoro|piper|say |NSSpeech|AVSpeech|AVAudio|afplay|mp3|wav|audio/speech|v1/audio/speech|response_format|openclaw_stream|text_delta|speech_start|speech_end" \
  "$PROJECT" "$APP_SUPPORT" \
  > "$OUT/speech_code_search.txt" 2>/dev/null || true

echo ""
echo "== 2. Main app speech references =="
if [ -f "$PROJECT/Sources/VroidOverlay/main.m" ]; then
  grep -nE "speech|speak|NSSpeech|AVSpeech|AVAudio|say |afplay|wav|mp3|speech_start|speech_end|openclaw_stream|text_delta|bubble|pendingSpeech|vroidStart" \
    "$PROJECT/Sources/VroidOverlay/main.m" \
    > "$OUT/main_m_speech_refs.txt" 2>/dev/null || true
else
  echo "MISSING main.m" > "$OUT/main_m_speech_refs.txt"
fi

echo ""
echo "== 3. Bridge speech logic =="
for f in \
  "$PROJECT/openclaw_vroid_bridge.py" \
  "$APP_SUPPORT/openclaw_vroid_bridge.py" \
  "$RUNTIME/openclaw_vroid_bridge.py" \
  "$RUNTIME/send_event.py" \
  "$RUNTIME/vroid_agent_daemon.py" \
  "$RUNTIME/run_once_test.py"
do
  echo "" >> "$OUT/bridge_and_agent_speech.txt"
  echo "======== $f ========" >> "$OUT/bridge_and_agent_speech.txt"
  if [ -f "$f" ]; then
    grep -nE "speech|speak|tts|voice|kokoro|piper|say |afplay|wav|mp3|audio/speech|v1/audio/speech|openclaw_stream|subprocess|curl|requests|urllib|emit|bubble|text_delta" \
      "$f" >> "$OUT/bridge_and_agent_speech.txt" 2>/dev/null || true
  else
    echo "MISSING" >> "$OUT/bridge_and_agent_speech.txt"
  fi
done

echo ""
echo "== 4. Config/env files =="
{
  echo "---- runtime personality ----"
  cat "$RUNTIME/personality.yaml" 2>/dev/null || true

  echo ""
  echo "---- runtime state ----"
  cat "$RUNTIME/agent_state.json" 2>/dev/null || true

  echo ""
  echo "---- app support files ----"
  find "$APP_SUPPORT" -maxdepth 2 -type f -print | sort
} > "$OUT/config_state.txt" 2>&1 || true

echo ""
echo "== 5. Running processes =="
{
  ps aux | grep -iE "kokoro|piper|say|afplay|speech|tts|uvicorn|VroidOverlay|vroid_agent|openclaw_vroid_bridge|python" | grep -v grep || true
} > "$OUT/processes.txt" 2>&1 || true

echo ""
echo "== 6. Active ports =="
{
  for port in 8880 8000 11434 18789; do
    echo ""
    echo "---- port $port ----"
    lsof -nP -iTCP:$port -sTCP:LISTEN || true
  done
} > "$OUT/ports.txt" 2>&1 || true

echo ""
echo "== 7. Kokoro probe =="
{
  echo "---- docs probe ----"
  curl -sS --max-time 3 http://127.0.0.1:8880/docs | head -20 || true

  echo ""
  echo "---- openapi probe ----"
  curl -sS --max-time 3 http://127.0.0.1:8880/openapi.json | python3 -m json.tool 2>/dev/null | head -120 || true

  echo ""
  echo "---- models dir ----"
  ls -lah "$PROJECT/kokoro-fastapi/api/src/models/v1_0" 2>/dev/null || true

  echo ""
  echo "---- voices dir sample ----"
  ls -lah "$PROJECT/kokoro-fastapi/api/src/voices/v1_0" 2>/dev/null | head -80 || true
} > "$OUT/kokoro_probe.txt" 2>&1 || true

echo ""
echo "== 8. Piper probe =="
{
  echo "---- piper command ----"
  which piper || true
  "$HOME/LocalAI/tts_local/bin/piper" --help 2>&1 | head -20 || true

  echo ""
  echo "---- piper voices ----"
  find "$HOME/LocalAI/piper_voices" -maxdepth 4 -type f \( -iname "*.onnx" -o -iname "*.json" \) -print 2>/dev/null | sort || true
} > "$OUT/piper_probe.txt" 2>&1 || true

echo ""
echo "== 9. Recent stream events =="
{
  STREAM="$APP_SUPPORT/openclaw_stream.jsonl"
  echo "STREAM=$STREAM"
  if [ -f "$STREAM" ]; then
    tail -80 "$STREAM"
  else
    echo "NO_STREAM"
  fi
} > "$OUT/recent_stream.txt" 2>&1 || true

echo ""
echo "== 10. Last app/agent logs =="
{
  echo "---- runtime agent.log ----"
  tail -120 "$RUNTIME/logs/agent.log" 2>/dev/null || true

  echo ""
  echo "---- runtime launchd.err ----"
  tail -120 "$RUNTIME/logs/launchd.err.log" 2>/dev/null || true

  echo ""
  echo "---- runtime launchd.out ----"
  tail -120 "$RUNTIME/logs/launchd.out.log" 2>/dev/null || true
} > "$OUT/logs.txt" 2>&1 || true

echo ""
echo "== 11. Quick verdict =="
{
  echo "Speech/TTS verdict candidates:"
  echo ""

  if grep -RIn "NSSpeechSynthesizer\|AVSpeechSynthesizer" "$PROJECT/Sources/VroidOverlay/main.m" >/dev/null 2>&1; then
    echo "- Native macOS speech found in main.m: NSSpeechSynthesizer/AVSpeechSynthesizer."
  fi

  if grep -RIn "say " "$PROJECT" "$APP_SUPPORT" >/dev/null 2>&1; then
    echo "- macOS 'say' command reference found."
  fi

  if grep -RIn "piper" "$PROJECT" "$APP_SUPPORT" >/dev/null 2>&1; then
    echo "- Piper reference found."
  fi

  if grep -RIn "kokoro\|v1/audio/speech\|audio/speech" "$PROJECT" "$APP_SUPPORT" >/dev/null 2>&1; then
    echo "- Kokoro/OpenAI-compatible /v1/audio/speech reference found."
  fi

  if lsof -nP -iTCP:8880 -sTCP:LISTEN >/dev/null 2>&1; then
    echo "- Kokoro server appears listening on port 8880."
  else
    echo "- Kokoro server is NOT listening on port 8880."
  fi

  if [ -x "$HOME/LocalAI/tts_local/bin/piper" ]; then
    echo "- Piper binary exists at $HOME/LocalAI/tts_local/bin/piper."
  fi

  echo ""
  echo "Key files to inspect:"
  echo "$OUT/speech_code_search.txt"
  echo "$OUT/main_m_speech_refs.txt"
  echo "$OUT/bridge_and_agent_speech.txt"
  echo "$OUT/processes.txt"
  echo "$OUT/ports.txt"
  echo "$OUT/kokoro_probe.txt"
  echo "$OUT/piper_probe.txt"
  echo "$OUT/recent_stream.txt"
} > "$OUT/verdict.txt"

zip -qr "$OUT.zip" "$OUT"

echo ""
echo "DONE"
echo "Folder: $OUT"
echo "ZIP: $OUT.zip"
echo ""
echo "Resumen:"
cat "$OUT/verdict.txt"
echo ""
echo "$OUT.zip" | pbcopy
echo "Ruta del ZIP copiada al portapapeles."
