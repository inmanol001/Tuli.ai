#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
MAIN="$PROJECT/Sources/VroidOverlay/main.m"
RESTORE="$(find "$PROJECT" -maxdepth 1 -type d -name 'backups_restore_render_order_only_*' -print | sort | tail -1)"
SAVE="$PROJECT/backups_before_undo_render_order_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$SAVE"
cp "$MAIN" "$SAVE/main.m.before_undo"

echo "RESTORE=$RESTORE"
echo "SAVE=$SAVE"

if [ -z "$RESTORE" ] || [ ! -f "$RESTORE/main.m.before_render_order_patch" ]; then
  echo "No encontré backup del render-order patch."
  exit 1
fi

cp "$RESTORE/main.m.before_render_order_patch" "$MAIN"

echo "Restaurado desde:"
echo "$RESTORE/main.m.before_render_order_patch"

echo ""
echo "Build:"
bash "$PROJECT/build.sh"
