#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
MAIN="$PROJECT/Sources/VroidOverlay/main.m"
BACKUP="$PROJECT/backups_fixed_rotation_$(date +%Y%m%d_%H%M%S)"

FIX_X="-1.567"
FIX_Y="6.298"
FIX_Z="0.000"

echo "== Fix Vroid Fixed Rotation =="
echo "Main: $MAIN"
echo "Rotation: X=$FIX_X Y=$FIX_Y Z=$FIX_Z"

if [ ! -f "$MAIN" ]; then
  echo "ERROR: no existe $MAIN"
  exit 1
fi

mkdir -p "$BACKUP"
cp "$MAIN" "$BACKUP/main.m.backup"
echo "Backup guardado en:"
echo "$BACKUP/main.m.backup"

python3 <<'PY'
from pathlib import Path
import re

main = Path("/Users/inma/Documents/Vroid/Sources/VroidOverlay/main.m")
text = main.read_text()

helpers = r'''

#pragma mark - VROID Fixed Look Rotation

- (BOOL)vroidUnlockRotationEnabled {
    NSString *value = [[[NSProcessInfo processInfo] environment] objectForKey:@"VROID_UNLOCK_ROTATION"];
    if (!value) return NO;

    value = [value lowercaseString];

    return [value isEqualToString:@"1"] ||
           [value isEqualToString:@"true"] ||
           [value isEqualToString:@"yes"] ||
           [value isEqualToString:@"on"];
}

- (SCNVector3)vroidFixedLookRotation {
    return SCNVector3Make(-1.567, 6.298, 0.000);
}

- (void)vroidApplyFixedLookRotation {
    if (!_rotationNode) return;

    if ([self vroidUnlockRotationEnabled]) {
        NSLog(@"[FIXED_ROTATION] unlocked by VROID_UNLOCK_ROTATION=1");
        return;
    }

    _rotationNode.eulerAngles = [self vroidFixedLookRotation];

    NSLog(@"[FIXED_ROTATION] applied x=-1.567 y=6.298 z=0.000");
}

'''

# Insert helper methods if they do not exist yet.
if "vroidApplyFixedLookRotation" not in text:
    marker = "- (void)centerAndFitNode:(SCNNode *)node"
    if marker in text:
        text = text.replace(marker, helpers + "\n" + marker, 1)
    else:
        idx = text.rfind("@end")
        if idx == -1:
            raise SystemExit("No encontré lugar para insertar helpers en main.m.")
        text = text[:idx] + helpers + "\n" + text[idx:]
else:
    # If helper already exists partially, update values.
    text = re.sub(
        r'return\s+SCNVector3Make\(\s*-?[\d.]+f?\s*,\s*-?[\d.]+f?\s*,\s*-?[\d.]+f?\s*\);',
        'return SCNVector3Make(-1.567, 6.298, 0.000);',
        text,
        count=1
    )
    text = re.sub(
        r'\[FIXED_ROTATION\]\s+applied\s+x=-?[\d.]+\s+y=-?[\d.]+\s+z=-?[\d.]+',
        '[FIXED_ROTATION] applied x=-1.567 y=6.298 z=0.000',
        text
    )

# Replace direct rotation assignments so they cannot override the fixed look.
lines = text.splitlines()
new_lines = []
inside_fixed_method = False
brace_depth = 0

for line in lines:
    stripped = line.strip()

    if "- (void)vroidApplyFixedLookRotation" in line:
        inside_fixed_method = True
        brace_depth = 0

    if inside_fixed_method:
        new_lines.append(line)
        brace_depth += line.count("{") - line.count("}")
        if brace_depth <= 0 and "}" in line:
            inside_fixed_method = False
        continue

    # Protect any direct _rotationNode.eulerAngles assignment.
    if re.search(r'_rotationNode\.eulerAngles\s*=', line):
        if "vroidApplyFixedLookRotation" in line:
            new_lines.append(line)
            continue

        indent = line[:len(line) - len(line.lstrip())]
        original = stripped

        new_lines.append(indent + "if ([self vroidUnlockRotationEnabled]) {")
        new_lines.append(indent + "    " + original)
        new_lines.append(indent + "} else {")
        new_lines.append(indent + "    [self vroidApplyFixedLookRotation];")
        new_lines.append(indent + "}")
    else:
        new_lines.append(line)

text = "\n".join(new_lines) + "\n"

# Ensure fixed rotation is applied after model/container setup.
# Insert only if there is not already an explicit call outside method body.
outside_helper = re.sub(
    r'- \(void\)vroidApplyFixedLookRotation\s*\{[\s\S]*?\n\}',
    '',
    text
)

if "[self vroidApplyFixedLookRotation];" not in outside_helper:
    hooks = [
        "[self vroidApplyFaceCameraFixForContainer:container];",
        "[self vroidApplyTexturedVisibleFixToContainer:container];",
        "[self vroidHeadOnlyPrepareContainer:container];",
        "[self vroidRuntimeRepairLoadedContainer:container];",
        "[self centerAndFitNode:container];",
        "[_rotationNode addChildNode:container];",
    ]

    inserted = False
    for hook in hooks:
        if hook in text:
            text = text.replace(
                hook,
                hook + "\n    [self vroidApplyFixedLookRotation];",
                1
            )
            inserted = True
            break

    if not inserted:
        print("WARNING: no encontré hook claro para aplicar rotación después de cargar el modelo.")

main.write_text(text)
print("main.m patched OK")
PY

echo ""
echo "== Verificando cambios =="
grep -n "vroidFixedLookRotation\|vroidApplyFixedLookRotation\|VROID_UNLOCK_ROTATION\|_rotationNode.eulerAngles\|SCNVector3Make(-1.567, 6.298, 0.000)" "$MAIN" || true

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
echo "Prueba normal con rotación fija:"
echo "./build/VroidOverlay.app/Contents/MacOS/VroidOverlay"
echo ""
echo "Prueba con logs:"
echo "VROID_DEBUG=1 ./build/VroidOverlay.app/Contents/MacOS/VroidOverlay 2>&1 | tee fixed_rotation.log"
echo ""
echo "Para desbloquear temporalmente la rotación:"
echo "VROID_UNLOCK_ROTATION=1 ./build/VroidOverlay.app/Contents/MacOS/VroidOverlay"
echo ""
echo "Para restaurar si algo falla:"
echo "cp '$BACKUP/main.m.backup' '$MAIN'"
