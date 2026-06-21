#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="/Users/inma/Documents/Vroid"
MAIN="$PROJECT_DIR/Sources/VroidOverlay/main.m"
BACKUP_DIR="$PROJECT_DIR/backups_scenekit_fix_$(date +%Y%m%d_%H%M%S)"

echo "== Vroid SceneKit Visibility Fix =="
echo "Project: $PROJECT_DIR"
echo "Main: $MAIN"

if [ ! -f "$MAIN" ]; then
  echo "ERROR: no existe $MAIN"
  exit 1
fi

mkdir -p "$BACKUP_DIR"
cp "$MAIN" "$BACKUP_DIR/main.m.backup"

echo "Backup guardado en:"
echo "$BACKUP_DIR/main.m.backup"

python3 <<'PY'
from pathlib import Path
import re

main = Path("/Users/inma/Documents/Vroid/Sources/VroidOverlay/main.m")
text = main.read_text()

helpers = r'''

#pragma mark - VROID Runtime Repair Helpers

- (BOOL)vroidEnvEnabled:(NSString *)name {
    NSString *value = [[[NSProcessInfo processInfo] environment] objectForKey:name];
    if (!value) return NO;
    value = [value lowercaseString];
    return [value isEqualToString:@"1"] ||
           [value isEqualToString:@"true"] ||
           [value isEqualToString:@"yes"] ||
           [value isEqualToString:@"on"];
}

- (void)vroidDumpNodeTree:(SCNNode *)node label:(NSString *)label indent:(NSUInteger)indent {
    if (!node) return;

    NSMutableString *pad = [NSMutableString string];
    for (NSUInteger i = 0; i < indent; i++) {
        [pad appendString:@"  "];
    }

    SCNVector3 minVec, maxVec;
    BOOL hasBounds = [node getBoundingBoxMin:&minVec max:&maxVec];

    NSLog(@"%@[%@] node=%@ hidden=%d opacity=%.3f children=%lu hasGeometry=%d bounds=%d min=(%.4f, %.4f, %.4f) max=(%.4f, %.4f, %.4f) pos=(%.4f, %.4f, %.4f) scale=(%.4f, %.4f, %.4f)",
          pad,
          label ?: @"node",
          node.name ?: @"<nil>",
          node.hidden,
          node.opacity,
          (unsigned long)node.childNodes.count,
          node.geometry != nil,
          hasBounds,
          minVec.x, minVec.y, minVec.z,
          maxVec.x, maxVec.y, maxVec.z,
          node.position.x, node.position.y, node.position.z,
          node.scale.x, node.scale.y, node.scale.z);

    if (node.geometry) {
        NSLog(@"%@  geometry=%@ materials=%lu",
              pad,
              node.geometry.name ?: NSStringFromClass(node.geometry.class),
              (unsigned long)node.geometry.materials.count);

        NSInteger idx = 0;
        for (SCNMaterial *mat in node.geometry.materials) {
            NSLog(@"%@  material[%ld] name=%@ diffuse=%@ transparency=%.3f doubleSided=%d writesDepth=%d readsDepth=%d cullMode=%ld lighting=%@",
                  pad,
                  (long)idx,
                  mat.name ?: @"<nil>",
                  mat.diffuse.contents,
                  mat.transparency,
                  mat.doubleSided,
                  mat.writesToDepthBuffer,
                  mat.readsFromDepthBuffer,
                  (long)mat.cullMode,
                  mat.lightingModelName);
            idx++;
        }
    }

    for (SCNNode *child in node.childNodes) {
        [self vroidDumpNodeTree:child label:@"child" indent:indent + 1];
    }
}

- (void)vroidRepairVisibilityForNode:(SCNNode *)node {
    if (!node) return;

    node.hidden = NO;
    node.opacity = 1.0;
    node.categoryBitMask = 1;

    if (node.geometry) {
        for (SCNMaterial *mat in node.geometry.materials) {
            mat.transparency = 1.0;
            mat.doubleSided = YES;
            mat.writesToDepthBuffer = YES;
            mat.readsFromDepthBuffer = YES;
            mat.cullMode = SCNCullModeBack;

            if (!mat.lightingModelName) {
                mat.lightingModelName = SCNLightingModelBlinn;
            }

            if (!mat.diffuse.contents) {
                mat.diffuse.contents = [NSColor whiteColor];
            }
        }
    }

    for (SCNNode *child in node.childNodes) {
        [self vroidRepairVisibilityForNode:child];
    }
}

- (void)vroidForceWhiteMaterialsForNode:(SCNNode *)node {
    if (!node) return;

    node.hidden = NO;
    node.opacity = 1.0;
    node.categoryBitMask = 1;

    if (node.geometry) {
        for (SCNMaterial *mat in node.geometry.materials) {
            mat.diffuse.contents = [NSColor whiteColor];
            mat.emission.contents = [NSColor colorWithWhite:0.18 alpha:1.0];
            mat.transparency = 1.0;
            mat.doubleSided = YES;
            mat.writesToDepthBuffer = YES;
            mat.readsFromDepthBuffer = YES;
            mat.cullMode = SCNCullModeBack;
            mat.lightingModelName = SCNLightingModelConstant;
        }
    }

    for (SCNNode *child in node.childNodes) {
        [self vroidForceWhiteMaterialsForNode:child];
    }
}

- (void)vroidAddDebugBoundsForNode:(SCNNode *)node toRoot:(SCNNode *)root {
    if (!node || !root) return;

    if (node.geometry) {
        SCNVector3 minVec, maxVec;
        BOOL hasBounds = [node getBoundingBoxMin:&minVec max:&maxVec];

        if (hasBounds) {
            CGFloat w = MAX(0.001, maxVec.x - minVec.x);
            CGFloat h = MAX(0.001, maxVec.y - minVec.y);
            CGFloat d = MAX(0.001, maxVec.z - minVec.z);

            SCNBox *box = [SCNBox boxWithWidth:w height:h length:d chamferRadius:0.0];
            box.firstMaterial.diffuse.contents = [NSColor colorWithCalibratedRed:1.0 green:0.1 blue:0.1 alpha:0.18];
            box.firstMaterial.emission.contents = [NSColor colorWithCalibratedRed:1.0 green:0.1 blue:0.1 alpha:0.25];
            box.firstMaterial.transparency = 0.25;
            box.firstMaterial.doubleSided = YES;
            box.firstMaterial.writesToDepthBuffer = NO;
            box.firstMaterial.readsFromDepthBuffer = NO;

            SCNNode *boxNode = [SCNNode nodeWithGeometry:box];
            boxNode.name = [NSString stringWithFormat:@"DEBUG_BOUNDS_%@", node.name ?: @"node"];
            boxNode.position = SCNVector3Make((minVec.x + maxVec.x) * 0.5,
                                              (minVec.y + maxVec.y) * 0.5,
                                              (minVec.z + maxVec.z) * 0.5);
            boxNode.renderingOrder = 999;
            [node addChildNode:boxNode];
        }
    }

    for (SCNNode *child in node.childNodes) {
        [self vroidAddDebugBoundsForNode:child toRoot:root];
    }
}

- (void)vroidRuntimeRepairLoadedContainer:(SCNNode *)container {
    if (!container) return;

    NSLog(@"[VROID_FIX] Runtime repair started. container=%@", container);

    [self vroidRepairVisibilityForNode:container];

    if ([self vroidEnvEnabled:@"VROID_FORCE_WHITE"]) {
        NSLog(@"[VROID_FIX] VROID_FORCE_WHITE=1 active");
        [self vroidForceWhiteMaterialsForNode:container];
    }

    if ([self vroidEnvEnabled:@"VROID_SHOW_BOUNDS"]) {
        NSLog(@"[VROID_FIX] VROID_SHOW_BOUNDS=1 active");
        [self vroidAddDebugBoundsForNode:container toRoot:container];
    }

    if ([self vroidEnvEnabled:@"VROID_DEBUG"]) {
        NSLog(@"[VROID_FIX] VROID_DEBUG=1 active. Dumping node tree...");
        [self vroidDumpNodeTree:container label:@"container-after-repair" indent:0];
    }

    NSLog(@"[VROID_FIX] Runtime repair finished.");
}

'''

if "vroidRuntimeRepairLoadedContainer" not in text:
    # Insert helpers before centerAndFitNode, because that method exists in the file.
    marker = "- (void)centerAndFitNode:(SCNNode *)node"
    if marker in text:
        text = text.replace(marker, helpers + "\n" + marker, 1)
    else:
        # fallback: insert before @end
        idx = text.rfind("@end")
        if idx == -1:
            raise SystemExit("No se encontró lugar para insertar helpers.")
        text = text[:idx] + helpers + "\n" + text[idx:]

# Insert runtime repair before centerAndFitNode:container
call = "[self centerAndFitNode:container];"
repair_call = """[self vroidRuntimeRepairLoadedContainer:container];
    [self centerAndFitNode:container];"""

if "vroidRuntimeRepairLoadedContainer:container" not in text:
    if call in text:
        text = text.replace(call, repair_call, 1)
    else:
        raise SystemExit("No se encontró '[self centerAndFitNode:container];' para insertar reparación.")

# Extra safety: if loadedScene root clone is used, make sure root clone is not hidden.
target = "SCNNode *rootClone = [loadedScene.rootNode clone];"
if target in text and "rootClone.hidden = NO;" not in text:
    text = text.replace(
        target,
        target + "\n    rootClone.hidden = NO;\n    rootClone.opacity = 1.0;",
        1
    )

main.write_text(text)
print("main.m patched OK")
PY

echo ""
echo "== Diff generado =="
diff -u "$BACKUP_DIR/main.m.backup" "$MAIN" || true

echo ""
echo "== Compilando =="
cd "$PROJECT_DIR"

if [ -x "./build.sh" ]; then
  ./build.sh
else
  echo "No encontré build.sh ejecutable. Intentando bash build.sh..."
  bash ./build.sh
fi

echo ""
echo "== FIX APLICADO =="
echo "Ahora prueba normal:"
echo "./build/VroidOverlay.app/Contents/MacOS/VroidOverlay"
echo ""
echo "Prueba debug:"
echo "VROID_DEBUG=1 ./build/VroidOverlay.app/Contents/MacOS/VroidOverlay 2>&1 | tee live_debug.log"
echo ""
echo "Prueba fuerza blanco:"
echo "VROID_DEBUG=1 VROID_FORCE_WHITE=1 ./build/VroidOverlay.app/Contents/MacOS/VroidOverlay 2>&1 | tee force_white.log"
echo ""
echo "Prueba bounds:"
echo "VROID_DEBUG=1 VROID_SHOW_BOUNDS=1 ./build/VroidOverlay.app/Contents/MacOS/VroidOverlay 2>&1 | tee bounds.log"
echo ""
echo "Para restaurar si algo falla:"
echo "cp '$BACKUP_DIR/main.m.backup' '$MAIN'"
