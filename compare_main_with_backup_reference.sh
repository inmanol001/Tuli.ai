#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
MAIN="$PROJECT/Sources/VroidOverlay/main.m"
OUT="$PROJECT/main_backup_compare_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$OUT"

echo "== Compare current main.m with backup reference =="
echo "OUT=$OUT"

echo ""
echo "== 1. Buscar backups disponibles =="
find "$PROJECT" -maxdepth 3 -type f \
  \( -name "main.m.backup" -o -name "main.m.before*" -o -name "main.m.current*" -o -name "main.m.broken*" \) \
  -print0 | while IFS= read -r -d '' f; do
    stat -f "%Sm | %z bytes | %N" -t "%Y-%m-%d %H:%M:%S" "$f"
  done | sort > "$OUT/backups_available.txt"

cat "$OUT/backups_available.txt"

echo ""
echo "== 2. Seleccionar backup de referencia =="

if [ "${BACKUP:-}" != "" ]; then
  REF="$BACKUP"
else
  # Por defecto usa el backup más reciente que NO tenga mis parches malos.
  REF="$(find "$PROJECT" -maxdepth 3 -type f \
    \( -name "main.m.backup" -o -name "main.m.before*" -o -name "main.m.current*" -o -name "main.m.broken*" \) \
    -print0 | while IFS= read -r -d '' f; do
      if ! grep -qE "vroidInvestigationDump3DState|vroidEmergencyForce" "$f"; then
        echo "$f"
      fi
    done | sort | tail -1)"
fi

if [ -z "$REF" ] || [ ! -f "$REF" ]; then
  echo "ERROR: no pude seleccionar backup."
  echo "Puedes correrlo así:"
  echo "BACKUP='/ruta/al/main.m.backup' ./compare_main_with_backup_reference.sh"
  exit 1
fi

echo "REF=$REF"
echo "$REF" > "$OUT/reference_path.txt"

cp "$MAIN" "$OUT/main_current.m"
cp "$REF" "$OUT/main_reference.m"

echo ""
echo "== 3. Fechas y tamaños =="
{
  echo "CURRENT:"
  stat -f "%Sm | %z bytes | %N" -t "%Y-%m-%d %H:%M:%S" "$MAIN"
  echo ""
  echo "REFERENCE:"
  stat -f "%Sm | %z bytes | %N" -t "%Y-%m-%d %H:%M:%S" "$REF"
} | tee "$OUT/file_stats.txt"

echo ""
echo "== 4. Buscar señales importantes en ambos =="
{
  for f in "$OUT/main_reference.m" "$OUT/main_current.m"; do
    echo ""
    echo "=============================="
    echo "$f"
    echo "=============================="

    echo ""
    echo "---- clase / ivars principales ----"
    grep -nE "@interface OverlaySceneView|@implementation OverlaySceneView|SCNView|SCNNode \\*_|_sceneView|_modelContainer|_containerNode|_rotationNode|_floatNode|_cameraNode" "$f" | head -120 || true

    echo ""
    echo "---- modelo/render/cámara ----"
    grep -nE "loadModelAtURL|AI.usdc|SCNScene|SCNCamera|pointOfView|cameraNode|centerAndFitNode|vroidApplyFaceCameraFix|vroidApplyFixedLookRotation|vroidRuntimeRepairLoadedContainer|vroidApplyTexturedVisibleFix" "$f" || true

    echo ""
    echo "---- cambios sospechosos Codex ----"
    grep -nE "vroidPreviewSnapshotNode|previewScene|flattenedClone|Runtime Repair Helpers|notifyRotationChanged|gridRoot|snapshotNode|preview|clone.position|clone.rotation|clone.scale" "$f" || true

    echo ""
    echo "---- mis parches malos ----"
    grep -nE "vroidInvestigationDump3DState|vroidEmergencyForce|EMERGENCY_3D|INVESTIGATE_3D" "$f" || true
  done
} > "$OUT/key_refs_compare.txt"

echo ""
echo "== 5. Diff completo =="
diff -u "$OUT/main_reference.m" "$OUT/main_current.m" > "$OUT/full_diff_reference_vs_current.diff" || true

echo ""
echo "== 6. Diff filtrado visual/render =="
grep -nE "^[+-].*(SCNView|SCNScene|SCNNode|SCNCamera|camera|pointOfView|AI.usdc|loadModelAtURL|centerAndFitNode|scale|position|rotation|hidden|opacity|alpha|preview|snapshot|flattenedClone|Runtime Repair|notifyRotationChanged|vroidEmergency|vroidInvestigation|_cameraNode|_sceneView|_modelContainer|_containerNode|_rotationNode|_floatNode)" \
  "$OUT/full_diff_reference_vs_current.diff" > "$OUT/render_related_diff.txt" || true

cat "$OUT/render_related_diff.txt" | sed -n '1,260p'

echo ""
echo "== 7. Probar si el backup compila temporalmente =="
echo "NO se va a dejar restaurado. Se restaura el main actual al final."

cp "$MAIN" "$OUT/main_before_temp_build_restore.m"

set +e
cp "$REF" "$MAIN"
bash "$PROJECT/build.sh" > "$OUT/reference_build_test.log" 2>&1
BUILD_CODE=$?
cp "$OUT/main_before_temp_build_restore.m" "$MAIN"
set -e

if [ "$BUILD_CODE" -eq 0 ]; then
  echo "REFERENCE BUILD: OK" | tee "$OUT/reference_build_verdict.txt"
else
  echo "REFERENCE BUILD: FAIL" | tee "$OUT/reference_build_verdict.txt"
  tail -80 "$OUT/reference_build_test.log"
fi

echo ""
echo "== 8. Probar si el main actual compila =="
set +e
bash "$PROJECT/build.sh" > "$OUT/current_build_test.log" 2>&1
CURRENT_CODE=$?
set -e

if [ "$CURRENT_CODE" -eq 0 ]; then
  echo "CURRENT BUILD: OK" | tee "$OUT/current_build_verdict.txt"
else
  echo "CURRENT BUILD: FAIL" | tee "$OUT/current_build_verdict.txt"
  tail -80 "$OUT/current_build_test.log"
fi

echo ""
echo "== 9. Veredicto =="
{
  echo "Main Backup Compare Verdict"
  echo ""
  echo "Reference:"
  cat "$OUT/reference_path.txt"
  echo ""
  cat "$OUT/file_stats.txt"
  echo ""
  cat "$OUT/reference_build_verdict.txt"
  cat "$OUT/current_build_verdict.txt"
  echo ""
  echo "Important outputs:"
  echo "$OUT/backups_available.txt"
  echo "$OUT/key_refs_compare.txt"
  echo "$OUT/render_related_diff.txt"
  echo "$OUT/full_diff_reference_vs_current.diff"
  echo "$OUT/reference_build_test.log"
  echo "$OUT/current_build_test.log"
} | tee "$OUT/verdict.txt"

zip -qr "$OUT.zip" "$OUT"

echo ""
echo "== DONE =="
echo "Folder: $OUT"
echo "ZIP: $OUT.zip"
echo "$OUT.zip" | pbcopy
echo "Ruta del ZIP copiada al portapapeles."
