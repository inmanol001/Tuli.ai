#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
MAIN="$PROJECT/Sources/VroidOverlay/main.m"

LATEST="$(find "$PROJECT" -maxdepth 1 -type d -name 'backups_rebuild_lost_nonrender_features_*' -print | sort | tail -1)"

echo "== Rollback failed non-render rebuild =="
echo "LATEST=$LATEST"

if [ -z "$LATEST" ] || [ ! -f "$LATEST/main.m.before_rebuild" ]; then
  echo "ERROR: no encontré backup main.m.before_rebuild"
  exit 1
fi

SAVE="$PROJECT/backups_before_rollback_failed_nonrender_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$SAVE"

cp "$MAIN" "$SAVE/main.m.partial_failed_patch"
cp "$LATEST/main.m.before_rebuild" "$MAIN"

echo "Restaurado:"
echo "$LATEST/main.m.before_rebuild"
echo ""
echo "Parcial fallido guardado en:"
echo "$SAVE/main.m.partial_failed_patch"

echo ""
echo "== Build =="
bash "$PROJECT/build.sh"

echo ""
echo "== OK rollback completo =="
