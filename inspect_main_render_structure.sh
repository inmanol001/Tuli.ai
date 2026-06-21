#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
MAIN="$PROJECT/Sources/VroidOverlay/main.m"
OUT="$PROJECT/main_render_structure_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$OUT"

echo "OUT=$OUT"

{
  echo "==== current main stats ===="
  stat -f "%Sm | %z bytes | %N" -t "%Y-%m-%d %H:%M:%S" "$MAIN"
  echo ""

  echo "==== class/interface boundaries ===="
  grep -nE "^@interface|^@implementation|^@end|#pragma mark" "$MAIN" || true
  echo ""

  echo "==== render/model refs ===="
  grep -nE "loadModelAtURL|AI.usdc|SCNView|SCNScene|SCNNode|SCNCamera|pointOfView|camera|centerAndFitNode|modelContainer|rotationNode|floatNode|container|rootNode|childNodes|opacity|hidden|scale|position|euler|vroidApplyFaceCameraFix|vroidApplyFixedLookRotation|vroidRuntimeRepairLoadedContainer|vroidApplyTexturedVisibleFix|vroidPreviewSnapshotNode|previewScene|flattenedClone|notifyRotationChanged" "$MAIN" || true
  echo ""

  echo "==== suspicious fragments with context ===="
  for pat in \
    "vroidPreviewSnapshotNode" \
    "previewScene" \
    "Runtime Repair Helpers" \
    "notifyRotationChanged" \
    "loadModelAtURL" \
    "centerAndFitNode" \
    "vroidApplyFaceCameraFixForContainer" \
    "vroidApplyFixedLookRotation" \
    "_cameraNode" \
    "_sceneView" \
    "_modelContainer" \
    "_rotationNode" \
    "_floatNode"
  do
    echo ""
    echo "---- $pat ----"
    grep -n "$pat" "$MAIN" | while IFS=: read -r line rest; do
      start=$((line-12)); [ "$start" -lt 1 ] && start=1
      end=$((line+28))
      echo "----- around line $line -----"
      nl -ba "$MAIN" | sed -n "${start},${end}p"
    done
  done
} > "$OUT/main_render_structure.txt" 2>&1

{
  echo "==== compile test ===="
  bash "$PROJECT/build.sh"
} > "$OUT/build_test.txt" 2>&1 || true

{
  echo "Main render structure verdict"
  echo ""
  grep -nE "^@interface|^@implementation|^@end" "$MAIN" || true
  echo ""
  echo "Build result:"
  if grep -q "error:" "$OUT/build_test.txt"; then
    echo "FAIL"
    tail -80 "$OUT/build_test.txt"
  else
    echo "OK or no explicit compiler error"
    tail -40 "$OUT/build_test.txt"
  fi
  echo ""
  echo "Files:"
  echo "$OUT/main_render_structure.txt"
  echo "$OUT/build_test.txt"
} > "$OUT/verdict.txt"

zip -qr "$OUT.zip" "$OUT"

echo ""
echo "==== verdict ===="
cat "$OUT/verdict.txt"
echo ""
echo "ZIP=$OUT.zip"
echo "$OUT.zip" | pbcopy
