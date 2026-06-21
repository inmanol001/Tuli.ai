#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
MAIN="$PROJECT/Sources/VroidOverlay/main.m"
BRIDGE="$PROJECT/openclaw_vroid_bridge.py"
BACKUP="$PROJECT/backups_bridge_contract_fix_$(date +%Y%m%d_%H%M%S)"

echo "== Fix OpenClaw ↔ Vroid Bridge Contract =="
echo "Project: $PROJECT"

if [ ! -f "$MAIN" ]; then
  echo "ERROR: no existe $MAIN"
  exit 1
fi

if [ ! -f "$BRIDGE" ]; then
  echo "ERROR: no existe $BRIDGE"
  exit 1
fi

mkdir -p "$BACKUP"
cp "$MAIN" "$BACKUP/main.m.backup"
cp "$BRIDGE" "$BACKUP/openclaw_vroid_bridge.py.backup"

echo "Backup:"
echo "$BACKUP"

python3 <<'PY'
from pathlib import Path
import re

main = Path("/Users/inma/Documents/Vroid/Sources/VroidOverlay/main.m")
text = main.read_text()

old = '''    if ([type isEqualToString:@"speech_end"]) {
        [self vroidHideSpeechBubble];
        [self vroidDebugLogEvent:command rawLine:nil action:@"speech_end" result:@"ok"];
        return;
    }'''

new = '''    if ([type isEqualToString:@"speech_end"]) {
        if (_pendingSpeechText.length > 0) {
            [self vroidDebugLogEvent:command rawLine:nil action:@"speech_end_start_pending_speech" result:_pendingSpeechText];
            [self vroidStartPendingSpeechIfNeeded];
        } else {
            [self vroidHideSpeechBubble];
            [self vroidDebugLogEvent:command rawLine:nil action:@"speech_end" result:@"ok_no_pending_text"];
        }
        return;
    }'''

if old in text:
    text = text.replace(old, new, 1)
else:
    print("WARNING: no encontré el bloque speech_end exacto. Intentando patch por regex.")
    pattern = r'if \(\[type isEqualToString:@"speech_end"\]\) \{\s*\[self vroidHideSpeechBubble\];\s*\[self vroidDebugLogEvent:command rawLine:nil action:@"speech_end" result:@"ok"\];\s*return;\s*\}'
    text2 = re.sub(pattern, new.strip(), text, count=1, flags=re.S)
    if text2 == text:
        raise SystemExit("No pude parchear speech_end en main.m")
    text = text2

main.write_text(text)
print("main.m patched: speech_end ahora inicia el habla pendiente")
PY

python3 <<'PY'
from pathlib import Path
import re

bridge = Path("/Users/inma/Documents/Vroid/openclaw_vroid_bridge.py")
text = bridge.read_text()

# Fix 1: default bubble should be enabled for normal emit mode.
text = text.replace(
    'bubble = bool(args.bubble) and not bool(args.no_bubble)',
    'bubble = (True if not args.no_bubble else False) if not args.bubble else True'
)

# Fix 2: do not immediately emit bubble_hide after speech_end in single-shot.
# The app will hide the bubble after the speech animation finishes.
text = text.replace(
'''        emit_event(path, event_id, debug_log_path, "speech_end")
        if bubble:
            emit_event(path, event_id, debug_log_path, "bubble_hide")
        return 0''',
'''        emit_event(path, event_id, debug_log_path, "speech_end")
        return 0'''
)

# Fix 3: for end-only, keep old behavior safe but do not force bubble_hide unless user explicitly asks no-bubble is false.
text = text.replace(
'''        emit_event(path, event_id, debug_log_path, "speech_end")
        if bubble:
            emit_event(path, event_id, debug_log_path, "bubble_hide")
        return 0''',
'''        emit_event(path, event_id, debug_log_path, "speech_end")
        return 0'''
)

bridge.write_text(text)
print("bridge patched: no oculta burbuja inmediatamente y bubble default ON")
PY

cat > "$PROJECT/test_vroid_bridge_now.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
STREAM="$HOME/Library/Application Support/VroidOverlay/openclaw_stream.jsonl"

mkdir -p "$(dirname "$STREAM")"

echo "Limpiando stream viejo:"
: > "$STREAM"

echo "Stream:"
echo "$STREAM"

echo ""
echo "Enviando prueba..."
VROID_DEBUG=1 "$PROJECT/openclaw_vroid_bridge.py" \
  --text "Hello, I am connected to OpenClaw now. I can speak and react." \
  --emotion happy \
  --bubble

echo ""
echo "Contenido del stream:"
tail -20 "$STREAM"

echo ""
echo "Si la app está abierta, debe mostrar burbuja y mover la boca/cabeza."
SH

chmod +x "$PROJECT/test_vroid_bridge_now.sh"

echo ""
echo "== Compilando app =="
cd "$PROJECT"

if [ -x "./build.sh" ]; then
  ./build.sh
else
  bash ./build.sh
fi

echo ""
echo "== LISTO =="
echo ""
echo "1) Abre la app en una terminal:"
echo "   cd $PROJECT"
echo "   VROID_DEBUG=1 ./build/VroidOverlay.app/Contents/MacOS/VroidOverlay"
echo ""
echo "2) En otra terminal manda una prueba:"
echo "   $PROJECT/test_vroid_bridge_now.sh"
echo ""
echo "3) Para OpenClaw, el comando correcto será:"
echo "   $PROJECT/openclaw_vroid_bridge.py --text \"texto de OpenClaw\" --emotion happy --bubble"
echo ""
echo "Restaurar si algo falla:"
echo "cp '$BACKUP/main.m.backup' '$MAIN'"
echo "cp '$BACKUP/openclaw_vroid_bridge.py.backup' '$BRIDGE'"
