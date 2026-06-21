#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
MAIN="$PROJECT/Sources/VroidOverlay/main.m"
APP="$PROJECT/build/VroidOverlay.app/Contents/MacOS/VroidOverlay"

echo "== Emergency restore after failed mouse patch =="

LATEST="$(find "$PROJECT" -maxdepth 1 -type d -name 'backups_manual_mouse_repulsion_v1_*' -print | sort | tail -1)"

echo "Latest mouse backup:"
echo "$LATEST"

if [ -z "$LATEST" ] || [ ! -f "$LATEST/main.m.before_mouse_repulsion_v1" ]; then
  echo "ERROR: no encontré el backup antes del patch de mouse."
  exit 1
fi

SAVE="$PROJECT/backups_emergency_after_mouse_failed_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$SAVE"

cp "$MAIN" "$SAVE/main.m.current_before_emergency_restore"
cp "$LATEST/main.m.before_mouse_repulsion_v1" "$MAIN"

echo ""
echo "Restaurado main.m desde:"
echo "$LATEST/main.m.before_mouse_repulsion_v1"
echo ""
echo "El main parcial quedó guardado en:"
echo "$SAVE/main.m.current_before_emergency_restore"

echo ""
echo "== Verificando que no quedó el patch de mouse =="
if grep -q "TULI_MANUAL_MOUSE_REPULSION_V1" "$MAIN"; then
  echo "ERROR: todavía quedó TULI_MANUAL_MOUSE_REPULSION_V1 en main.m"
  exit 1
else
  echo "OK: main.m no contiene el patch de mouse."
fi

echo ""
echo "== Corriendo app existente SIN build =="
if [ ! -x "$APP" ]; then
  echo "ERROR: no existe app ejecutable:"
  echo "$APP"
  exit 1
fi

pkill -f VroidOverlay 2>/dev/null || true
sleep 1

"$APP"
