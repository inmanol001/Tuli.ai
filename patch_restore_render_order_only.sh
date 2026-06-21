#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
MAIN="$PROJECT/Sources/VroidOverlay/main.m"
BACKUP="$PROJECT/backups_restore_render_order_only_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$BACKUP"
cp "$MAIN" "$BACKUP/main.m.before_render_order_patch"

echo "== Patch restore render order only =="
echo "Backup: $BACKUP"

python3 - <<'PY'
from pathlib import Path

main = Path("/Users/inma/Documents/Vroid/Sources/VroidOverlay/main.m")
s = main.read_text()

# Remove any accidental bad investigation/emergency calls if present.
for bad in [
    '[self vroidEmergencyForceSceneVisible];',
]:
    s = s.replace("\n    " + bad, "")

# Main surgical fix:
# Do NOT run face-camera before centerAndFit. That can double-center the model and leave camera stale.
old = '''    [self vroidRuntimeRepairLoadedContainer:container];
    [self vroidApplyTexturedVisibleFixToContainer:container];
    [self vroidApplyFaceCameraFixForContainer:container];
    [self centerAndFitNode:container];'''

new = '''    [self vroidRuntimeRepairLoadedContainer:container];
    [self vroidApplyTexturedVisibleFixToContainer:container];

    // Render restore: center/scale model first.
    // The previous face-camera call here could move the container before centerAndFit,
    // then centerAndFit moved it again while cameraDistance was disabled.
    [self centerAndFitNode:container];

    // Keep face-camera disabled by default for stable visibility.
    // Re-enable manually later only after the avatar is visible again.
    // [self vroidApplyFaceCameraFixForContainer:container];'''

if old in s:
    s = s.replace(old, new)
    print("patched loadModelAtURL render order")
else:
    print("WARN: exact render-order block not found")

# Restore camera positioning inside centerAndFitNode.
old2 = '''    CGFloat cameraDistance = MAX(2.5, largest * 3.0);
    /* disabled by face camera fix: _cameraNode.position = SCNVector3Make(0.0, 0.0, cameraDistance); */'''

new2 = '''    CGFloat cameraDistance = MAX(2.5, largest * 3.0);
    _cameraNode.position = SCNVector3Make(0.0, 0.0, cameraDistance);
    _cameraNode.eulerAngles = SCNVector3Make(0.0, 0.0, 0.0);
    _cameraNode.camera.usesOrthographicProjection = NO;
    _cameraNode.camera.fieldOfView = 35.0;'''

if old2 in s:
    s = s.replace(old2, new2)
    print("restored cameraDistance in centerAndFitNode")
else:
    print("WARN: disabled cameraDistance line not found")

# Make fixed rotation less dangerous: keep env unlock behavior, but do not force it when VROID_UNLOCK_ROTATION=1.
# No change needed if user launches with VROID_UNLOCK_ROTATION=1.

main.write_text(s)
PY

echo ""
echo "== Sanity check changed lines =="
grep -nE "vroidApplyFaceCameraFixForContainer|cameraDistance|centerAndFitNode|Render restore|disabled by face camera" "$MAIN" | head -80

echo ""
echo "== Build =="
bash "$PROJECT/build.sh"

echo ""
echo "== Kill duplicate app instances =="
pkill -f VroidOverlay || true
sleep 1

echo ""
echo "== Run with safe visibility flags =="
VROID_DEBUG=1 \
VROID_UNLOCK_ROTATION=1 \
VROID_SHOW_CONTROLS=1 \
VROID_SHOW_GIZMO=1 \
VROID_ORTHO=0 \
VROID_CAMERA_Z=8 \
VROID_CAMERA_FOV=35 \
VROID_TTS_PROVIDER=kokoro \
VROID_KOKORO_URL="http://127.0.0.1:8880/v1/audio/speech" \
VROID_KOKORO_VOICE="af_bella" \
"$PROJECT/build/VroidOverlay.app/Contents/MacOS/VroidOverlay"
