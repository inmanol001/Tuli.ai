#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
MAIN="$PROJECT/Sources/VroidOverlay/main.m"
BACKUP="$PROJECT/backups_camera_face_$(date +%Y%m%d_%H%M%S)"

echo "== Fix Vroid Face Camera =="
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
import re

main = Path("/Users/inma/Documents/Vroid/Sources/VroidOverlay/main.m")
text = main.read_text()

helpers = r'''

#pragma mark - VROID Face Camera Fix

- (CGFloat)vroidCameraEnvFloat:(NSString *)name defaultValue:(CGFloat)defaultValue {
    NSString *value = [[[NSProcessInfo processInfo] environment] objectForKey:name];
    if (!value || value.length == 0) return defaultValue;
    return (CGFloat)[value doubleValue];
}

- (BOOL)vroidCameraEnvBool:(NSString *)name defaultValue:(BOOL)defaultValue {
    NSString *value = [[[NSProcessInfo processInfo] environment] objectForKey:name];
    if (!value || value.length == 0) return defaultValue;
    value = [value lowercaseString];
    if ([value isEqualToString:@"1"] || [value isEqualToString:@"true"] || [value isEqualToString:@"yes"] || [value isEqualToString:@"on"]) return YES;
    if ([value isEqualToString:@"0"] || [value isEqualToString:@"false"] || [value isEqualToString:@"no"] || [value isEqualToString:@"off"]) return NO;
    return defaultValue;
}

- (void)vroidApplyFaceCameraFixForContainer:(SCNNode *)container {
    if (!_cameraNode || !_cameraNode.camera || !container) return;

    CGFloat cameraZ = [self vroidCameraEnvFloat:@"VROID_CAMERA_Z" defaultValue:8.0];
    CGFloat orthoScale = [self vroidCameraEnvFloat:@"VROID_ORTHO_SCALE" defaultValue:3.6];
    CGFloat perspectiveFOV = [self vroidCameraEnvFloat:@"VROID_CAMERA_FOV" defaultValue:22.0];
    BOOL useOrtho = [self vroidCameraEnvBool:@"VROID_ORTHO" defaultValue:YES];

    _cameraNode.position = SCNVector3Make(0.0, 0.0, cameraZ);
    _cameraNode.eulerAngles = SCNVector3Make(0.0, 0.0, 0.0);

    _cameraNode.camera.zNear = 0.001;
    _cameraNode.camera.zFar = 200.0;

    if (useOrtho) {
        _cameraNode.camera.usesOrthographicProjection = YES;
        _cameraNode.camera.orthographicScale = orthoScale;
        NSLog(@"[FACE_CAMERA] Orthographic camera active. z=%.3f scale=%.3f", cameraZ, orthoScale);
    } else {
        _cameraNode.camera.usesOrthographicProjection = NO;
        _cameraNode.camera.fieldOfView = perspectiveFOV;
        NSLog(@"[FACE_CAMERA] Perspective camera active. z=%.3f fov=%.3f", cameraZ, perspectiveFOV);
    }

    // Mantener el rostro centrado sin empujar demasiado hacia cámara.
    SCNVector3 minVec, maxVec;
    BOOL hasBounds = [container getBoundingBoxMin:&minVec max:&maxVec];

    if (hasBounds) {
        CGFloat centerX = (minVec.x + maxVec.x) * 0.5;
        CGFloat centerY = (minVec.y + maxVec.y) * 0.5;
        CGFloat centerZ = (minVec.z + maxVec.z) * 0.5;

        // Ajuste suave. No escala agresiva aquí para evitar deformación percibida.
        container.position = SCNVector3Make(container.position.x - centerX * container.scale.x,
                                            container.position.y - centerY * container.scale.y,
                                            container.position.z - centerZ * container.scale.z);

        NSLog(@"[FACE_CAMERA] container bounds min=(%.4f %.4f %.4f) max=(%.4f %.4f %.4f) center=(%.4f %.4f %.4f)",
              minVec.x, minVec.y, minVec.z,
              maxVec.x, maxVec.y, maxVec.z,
              centerX, centerY, centerZ);
    }
}

'''

if "vroidApplyFaceCameraFixForContainer" not in text:
    marker = "- (void)centerAndFitNode:(SCNNode *)node"
    if marker in text:
        text = text.replace(marker, helpers + "\n" + marker, 1)
    else:
        idx = text.rfind("@end")
        if idx == -1:
            raise SystemExit("No encontré lugar para insertar helpers.")
        text = text[:idx] + helpers + "\n" + text[idx:]

# Insert camera fix after the textured/head preparation if possible.
inserted = False

preferred_hooks = [
    "[self vroidApplyTexturedVisibleFixToContainer:container];",
    "[self vroidHeadOnlyPrepareContainer:container];",
    "[self vroidRuntimeRepairLoadedContainer:container];",
    "[self centerAndFitNode:container];",
]

for hook in preferred_hooks:
    if hook in text and "[self vroidApplyFaceCameraFixForContainer:container];" not in text:
        text = text.replace(
            hook,
            hook + "\n    [self vroidApplyFaceCameraFixForContainer:container];",
            1
        )
        inserted = True
        break

if "[self vroidApplyFaceCameraFixForContainer:container];" not in text:
    raise SystemExit("No pude enganchar el fix de cámara en main.m")

# Reduce old aggressive camera distance overrides if present.
text = re.sub(
    r'_cameraNode\.position\s*=\s*SCNVector3Make\(0\.0,\s*0\.0,\s*cameraDistance\);',
    '/* disabled by face camera fix: _cameraNode.position = SCNVector3Make(0.0, 0.0, cameraDistance); */',
    text
)

# If initial camera is very close or default, make it safer.
text = re.sub(
    r'_cameraNode\.position\s*=\s*SCNVector3Make\(0\.0,\s*0\.0,\s*6\.0\);',
    '_cameraNode.position = SCNVector3Make(0.0, 0.0, 8.0);',
    text
)

main.write_text(text)
print("main.m camera patched OK")
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
echo ""
echo "Prueba recomendada, sin deformación:"
echo "VROID_ORTHO=1 VROID_ORTHO_SCALE=3.6 VROID_CAMERA_Z=8 ./build/VroidOverlay.app/Contents/MacOS/VroidOverlay"
echo ""
echo "Más lejos:"
echo "VROID_ORTHO=1 VROID_ORTHO_SCALE=4.2 VROID_CAMERA_Z=10 ./build/VroidOverlay.app/Contents/MacOS/VroidOverlay"
echo ""
echo "Más cerca:"
echo "VROID_ORTHO=1 VROID_ORTHO_SCALE=3.0 VROID_CAMERA_Z=8 ./build/VroidOverlay.app/Contents/MacOS/VroidOverlay"
echo ""
echo "Perspectiva suave, por si prefieres algo 3D:"
echo "VROID_ORTHO=0 VROID_CAMERA_FOV=18 VROID_CAMERA_Z=12 ./build/VroidOverlay.app/Contents/MacOS/VroidOverlay"
echo ""
echo "Restaurar si falla:"
echo "cp '$BACKUP/main.m.backup' '$MAIN'"
