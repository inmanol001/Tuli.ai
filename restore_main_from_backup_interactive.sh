#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
MAIN="$PROJECT/Sources/VroidOverlay/main.m"
SAVE="$PROJECT/backups_before_manual_main_restore_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$SAVE"

echo "== Restore main.m from backup =="
echo "MAIN=$MAIN"
echo ""

echo "== 1. Guardando main.m actual antes de restaurar =="
cp "$MAIN" "$SAVE/main.m.before_manual_restore"
echo "Guardado en:"
echo "$SAVE/main.m.before_manual_restore"

echo ""
echo "== 2. Backups disponibles =="
mapfile -t CANDIDATES < <(
  find "$PROJECT" -maxdepth 4 -type f \
    \( -name "main.m.backup" \
    -o -name "main.m.before*" \
    -o -name "main.m.current*" \
    -o -name "main.m.broken*" \
    -o -name "*.m.backup" \) \
    -print | sort
)

if [ "${#CANDIDATES[@]}" -eq 0 ]; then
  echo "ERROR: no encontré backups de main.m."
  exit 1
fi

i=1
for f in "${CANDIDATES[@]}"; do
  printf "%2d) " "$i"
  stat -f "%Sm | %z bytes | %N" -t "%Y-%m-%d %H:%M:%S" "$f"
  i=$((i+1))
done

echo ""
echo "Elige el número del backup que quieres restaurar."
echo "Recomendación: usa el backup que tú sabes que tenía la cabeza visible."
echo ""
read -r -p "Número: " CHOICE

if ! [[ "$CHOICE" =~ ^[0-9]+$ ]]; then
  echo "ERROR: selección inválida."
  exit 1
fi

INDEX=$((CHOICE-1))

if [ "$INDEX" -lt 0 ] || [ "$INDEX" -ge "${#CANDIDATES[@]}" ]; then
  echo "ERROR: número fuera de rango."
  exit 1
fi

BACKUP="${CANDIDATES[$INDEX]}"

echo ""
echo "== 3. Backup seleccionado =="
echo "$BACKUP"
stat -f "%Sm | %z bytes | %N" -t "%Y-%m-%d %H:%M:%S" "$BACKUP"

echo ""
read -r -p "¿Restaurar este backup sobre Sources/VroidOverlay/main.m? escribe YES: " CONFIRM

if [ "$CONFIRM" != "YES" ]; then
  echo "Cancelado. No se cambió main.m."
  exit 0
fi

cp "$BACKUP" "$MAIN"

echo ""
echo "== 4. Verificando señales peligrosas =="
grep -nE "vroidInvestigationDump3DState|vroidEmergencyForce|EMERGENCY_3D|INVESTIGATE_3D" "$MAIN" && {
  echo ""
  echo "ADVERTENCIA: el backup seleccionado contiene restos de parches malos."
  echo "Puedes restaurar otro backup si este no compila."
} || echo "OK: no veo restos de mis parches malos."

echo ""
echo "== 5. Compilando =="
if bash "$PROJECT/build.sh"; then
  echo ""
  echo "== BUILD OK =="
  echo "main.m restaurado desde:"
  echo "$BACKUP"
  echo ""
  echo "Copia del main anterior guardada en:"
  echo "$SAVE/main.m.before_manual_restore"
else
  echo ""
  echo "== BUILD FALLÓ =="
  echo "El main.m restaurado no compila."
  echo ""
  echo "Puedes volver al main anterior con:"
  echo "cp \"$SAVE/main.m.before_manual_restore\" \"$MAIN\""
  exit 1
fi
