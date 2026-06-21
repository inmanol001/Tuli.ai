#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
APP_SUPPORT="$HOME/Library/Application Support/VroidOverlay"
RUNTIME="$APP_SUPPORT/local_agent_runtime"
MAIN="$PROJECT/Sources/VroidOverlay/main.m"
OUT="$PROJECT/codex_kokoro_patch_debug_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$OUT"

echo "== Investigando si Codex cambió say -> Kokoro =="
echo "OUT: $OUT"

echo ""
echo "== 1. Git status/diff =="
{
  cd "$PROJECT"
  echo "---- git status ----"
  git status --short 2>/dev/null || true

  echo ""
  echo "---- git diff summary ----"
  git diff --stat 2>/dev/null || true

  echo ""
  echo "---- git diff main.m relevant ----"
  git diff -- Sources/VroidOverlay/main.m 2>/dev/null | sed -n '1,260p' || true

  echo ""
  echo "---- git diff personality ----"
  git diff -- local_agent/personality.yaml 2>/dev/null | sed -n '1,220p' || true
} > "$OUT/git_diff.txt" 2>&1

echo ""
echo "== 2. Buscar referencias TTS en main.m =="
{
  if [ -f "$MAIN" ]; then
    grep -nE "Kokoro|kokoro|audio/speech|v1/audio|127\.0\.0\.1:8880|localhost:8880|afplay|say|NSTask|speechVoice|VROID_SPEECH|Piper|piper|mp3|wav|AVAudio|NSSpeech|vroidSpeakText|vroidStartPendingSpeech|speech_end_start_pending_speech" "$MAIN" || true
  else
    echo "MISSING $MAIN"
  fi
} > "$OUT/main_tts_refs.txt" 2>&1

echo ""
echo "== 3. Extraer métodos de voz alrededor de main.m =="
{
  if [ -f "$MAIN" ]; then
    echo "---- around vroidSpeakText / voice name ----"
    nl -ba "$MAIN" | sed -n '1440,1535p'

    echo ""
    echo "---- around stream event handling ----"
    nl -ba "$MAIN" | sed -n '1550,1665p'

    echo ""
    echo "---- around pending speech ----"
    nl -ba "$MAIN" | sed -n '2035,2070p'
  fi
} > "$OUT/main_voice_methods.txt" 2>&1

echo ""
echo "== 4. Buscar referencias en todo el proyecto =="
{
  grep -RIn \
    --exclude-dir=.git \
    --exclude-dir=build \
    --exclude-dir=.build \
    --exclude-dir=.venv \
    --exclude-dir=kokoro-fastapi/.venv \
    --exclude-dir="backups_*" \
    --exclude-dir="codex_kokoro_patch_debug_*" \
    -E "Kokoro|kokoro|v1/audio/speech|audio/speech|127\.0\.0\.1:8880|localhost:8880|afplay|say -v|NSTask|VROID_SPEECH|Piper|piper|response_format|mp3|wav" \
    "$PROJECT" "$APP_SUPPORT" 2>/dev/null || true
} > "$OUT/project_tts_search.txt"

echo ""
echo "== 5. Runtime/local agent speech config =="
{
  echo "---- runtime files ----"
  find "$RUNTIME" -maxdepth 2 -type f -print 2>/dev/null | sort || true

  echo ""
  echo "---- runtime personality ----"
  cat "$RUNTIME/personality.yaml" 2>/dev/null || true

  echo ""
  echo "---- runtime daemon refs ----"
  grep -nE "kokoro|Kokoro|audio/speech|afplay|say|piper|voice|tts|speech|subprocess|curl|urllib|requests" "$RUNTIME/vroid_agent_daemon.py" 2>/dev/null || true

  echo ""
  echo "---- runtime send_event refs ----"
  grep -nE "kokoro|Kokoro|audio/speech|afplay|say|piper|voice|tts|speech|subprocess|curl|urllib|requests" "$RUNTIME/send_event.py" 2>/dev/null || true

  echo ""
  echo "---- runtime bridge refs ----"
  grep -nE "kokoro|Kokoro|audio/speech|afplay|say|piper|voice|tts|speech|subprocess|curl|urllib|requests" "$APP_SUPPORT/openclaw_vroid_bridge.py" 2>/dev/null || true
} > "$OUT/runtime_tts_refs.txt" 2>&1

echo ""
echo "== 6. Procesos y puertos activos =="
{
  echo "---- processes ----"
  ps aux | grep -iE "VroidOverlay|kokoro|uvicorn|piper|afplay|say|vroid_agent|openclaw|ollama|python" | grep -v grep || true

  echo ""
  echo "---- ports ----"
  for port in 8880 11434 18789; do
    echo ""
    echo "PORT $port"
    lsof -nP -iTCP:$port -sTCP:LISTEN || true
  done
} > "$OUT/processes_ports.txt" 2>&1

echo ""
echo "== 7. Probar Kokoro server =="
{
  echo "---- /docs ----"
  curl -sS --max-time 3 http://127.0.0.1:8880/docs | head -20 || true

  echo ""
  echo "---- /v1/models ----"
  curl -sS --max-time 3 http://127.0.0.1:8880/v1/models || true

  echo ""
  echo "---- /v1/audio/voices ----"
  curl -sS --max-time 3 http://127.0.0.1:8880/v1/audio/voices | head -80 || true

  echo ""
  echo "---- model files ----"
  ls -lh "$PROJECT/kokoro-fastapi/api/src/models/v1_0/" 2>/dev/null || true

  echo ""
  echo "---- voice files sample ----"
  ls -lh "$PROJECT/kokoro-fastapi/api/src/voices/v1_0/" 2>/dev/null | head -60 || true
} > "$OUT/kokoro_server_probe.txt" 2>&1

echo ""
echo "== 8. Logs recientes =="
{
  echo "---- VroidOverlay overlay_debug.log ----"
  tail -160 "$APP_SUPPORT/overlay_debug.log" 2>/dev/null || true

  echo ""
  echo "---- bridge_debug.log ----"
  tail -160 "$APP_SUPPORT/bridge_debug.log" 2>/dev/null || true

  echo ""
  echo "---- runtime agent.log ----"
  tail -160 "$RUNTIME/logs/agent.log" 2>/dev/null || true

  echo ""
  echo "---- launchd err ----"
  tail -160 "$RUNTIME/logs/launchd.err.log" 2>/dev/null || true
} > "$OUT/recent_logs.txt" 2>&1

echo ""
echo "== 9. Hacer evento de prueba al avatar =="
{
  echo "---- emitting test event ----"
  /usr/bin/python3 "$APP_SUPPORT/openclaw_vroid_bridge.py" \
    --text "Kokoro patch inspection test." \
    --emotion curious \
    --bubble || true

  echo ""
  echo "---- stream tail ----"
  tail -40 "$APP_SUPPORT/openclaw_stream.jsonl" 2>/dev/null || true

  echo ""
  echo "---- overlay debug after event ----"
  sleep 2
  tail -120 "$APP_SUPPORT/overlay_debug.log" 2>/dev/null || true
} > "$OUT/test_event_result.txt" 2>&1

echo ""
echo "== 10. Veredicto automático =="
{
  echo "Codex Kokoro Patch Verdict"
  echo ""

  MAIN_HAS_KOKORO=0
  MAIN_HAS_SAY=0
  MAIN_HAS_AFPLAY=0
  KOKORO_RUNNING=0
  RUNTIME_HAS_KOKORO=0

  grep -qE "kokoro|Kokoro|127\.0\.0\.1:8880|v1/audio/speech|audio/speech" "$MAIN" 2>/dev/null && MAIN_HAS_KOKORO=1 || true
  grep -qE "say|/usr/bin/say|NSTask" "$MAIN" 2>/dev/null && MAIN_HAS_SAY=1 || true
  grep -qE "afplay|AVAudio" "$MAIN" 2>/dev/null && MAIN_HAS_AFPLAY=1 || true
  lsof -nP -iTCP:8880 -sTCP:LISTEN >/dev/null 2>&1 && KOKORO_RUNNING=1 || true
  grep -RqiE "kokoro|127\.0\.0\.1:8880|v1/audio/speech|audio/speech" "$RUNTIME" 2>/dev/null && RUNTIME_HAS_KOKORO=1 || true

  echo "main.m has Kokoro reference: $MAIN_HAS_KOKORO"
  echo "main.m still has say/NSTask reference: $MAIN_HAS_SAY"
  echo "main.m has afplay/AVAudio reference: $MAIN_HAS_AFPLAY"
  echo "runtime has Kokoro reference: $RUNTIME_HAS_KOKORO"
  echo "Kokoro server listening on 8880: $KOKORO_RUNNING"
  echo ""

  if [ "$MAIN_HAS_KOKORO" = "1" ] && [ "$KOKORO_RUNNING" = "1" ]; then
    echo "LIKELY: Codex added Kokoro path and server is active."
  elif [ "$MAIN_HAS_KOKORO" = "1" ] && [ "$KOKORO_RUNNING" = "0" ]; then
    echo "PARTIAL: main.m mentions Kokoro, but Kokoro server is not running."
  elif [ "$MAIN_HAS_KOKORO" = "0" ] && [ "$MAIN_HAS_SAY" = "1" ]; then
    echo "NO: avatar likely still uses macOS say path."
  else
    echo "UNCLEAR: inspect main_tts_refs.txt and main_voice_methods.txt."
  fi

  echo ""
  echo "Important files:"
  echo "$OUT/git_diff.txt"
  echo "$OUT/main_tts_refs.txt"
  echo "$OUT/main_voice_methods.txt"
  echo "$OUT/runtime_tts_refs.txt"
  echo "$OUT/kokoro_server_probe.txt"
  echo "$OUT/test_event_result.txt"
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
