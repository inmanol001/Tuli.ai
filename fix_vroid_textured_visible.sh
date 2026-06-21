#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
MAIN="$PROJECT/Sources/VroidOverlay/main.m"
BACKUP="$PROJECT/backups_textured_visible_$(date +%Y%m%d_%H%M%S)"

echo "== Fix Vroid Textured Visible =="
echo "Main: $MAIN"

if [ ! -f "$MAIN" ]; then
  echo "ERROR: no existe $MAIN"
  exit 1
fi

mkdir -p "$BACKUP"
cp "$MAIN" "$BACKUP/main.m.backup"
echo "Backup: $BACKUP/main.m.backup"

python3 <<'PY'
from pathlib import Path

main = Path("/Users/inma/Documents/Vroid/Sources/VroidOverlay/main.m")
text = main.read_text()

helpers = r'''

#pragma mark - VROID Textured Visibility Fix

- (void)vroidMakeTexturesVisibleForNode:(SCNNode *)node {
    if (!node) return;

    node.hidden = NO;
    node.opacity = 1.0;
    node.categoryBitMask = 1;

    if (node.geometry) {
        for (SCNMaterial *mat in node.geometry.materials) {
            mat.transparency = 1.0;
            mat.doubleSided = YES;
            mat.cullMode = SCNCullModeBack;

            // Mantener texturas originales, pero evitar que PhysicallyBased las oscurezca o las vuelva raras.
            mat.lightingModelName = SCNLightingModelConstant;

            // Para rostro/cabello con alpha/texturas, esto suele ser más estable en SceneKit.
            mat.writesToDepthBuffer = YES;
            mat.readsFromDepthBuffer = YES;

            // Si la textura existe en diffuse, no la reemplazamos.
            // Si no existe, ponemos blanco de fallback.
            if (!mat.diffuse.contents) {
                mat.diffuse.contents = [NSColor whiteColor];
            }

            // Evita que emission vieja o vacía afecte demasiado.
            if (!mat.emission.contents) {
                mat.emission.contents = [NSColor blackColor];
            }

            NSLog(@"[TEXTURE_FIX] material=%@ diffuse=%@ lighting=%@ transparency=%.3f doubleSided=%d",
                  mat.name ?: @"<nil>",
                  mat.diffuse.contents,
                  mat.lightingModelName,
                  mat.transparency,
                  mat.doubleSided);
        }
    }

    for (SCNNode *child in node.childNodes) {
        [self vroidMakeTexturesVisibleForNode:child];
    }
}

- (void)vroidApplyTexturedVisibleFixToContainer:(SCNNode *)container {
    if (!container) return;
    NSLog(@"[TEXTURE_FIX] Applying textured visibility fix");
    [self vroidMakeTexturesVisibleForNode:container];
}

'''

if "vroidApplyTexturedVisibleFixToContainer" not in text:
    marker = "- (void)centerAndFitNode:(SCNNode *)node"
    if marker in text:
        text = text.replace(marker, helpers + "\n" + marker, 1)
    else:
        idx = text.rfind("@end")
        if idx == -1:
            raise SystemExit("No encontré lugar para insertar helpers.")
        text = text[:idx] + helpers + "\n" + text[idx:]

call = "[self vroidRuntimeRepairLoadedContainer:container];"
if call in text and "[self vroidApplyTexturedVisibleFixToContainer:container];" not in text:
    text = text.replace(
        call,
        call + "\n    [self vroidApplyTexturedVisibleFixToContainer:container];",
        1
    )
elif "[self centerAndFitNode:container];" in text and "[self vroidApplyTexturedVisibleFixToContainer:container];" not in text:
    text = text.replace(
        "[self centerAndFitNode:container];",
        "[self vroidApplyTexturedVisibleFixToContainer:container];\n    [self centerAndFitNode:container];",
        1
    )

main.write_text(text)
print("main.m patched OK")
PY

echo ""
echo "== Compilando =="
cd "$PROJECT"

if [ -x "./build.sh" ]; then
  ./build.sh
else
  bash ./build.sh
fi

echo ""
echo "== LISTO =="
echo "Prueba:"
echo "./build/VroidOverlay.app/Contents/MacOS/VroidOverlay"
echo ""
echo "Con logs:"
echo "VROID_DEBUG=1 ./build/VroidOverlay.app/Contents/MacOS/VroidOverlay 2>&1 | tee textured_visible.log"
echo ""
echo "Restaurar si falla:"
echo "cp '$BACKUP/main.m.backup' '$MAIN'"
