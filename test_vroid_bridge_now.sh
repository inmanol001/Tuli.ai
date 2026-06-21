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
