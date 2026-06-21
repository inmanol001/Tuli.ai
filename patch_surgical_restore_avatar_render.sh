#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
MAIN="$PROJECT/Sources/VroidOverlay/main.m"
BACKUP="$PROJECT/backups_surgical_restore_avatar_render_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$BACKUP"
cp "$MAIN" "$BACKUP/main.m.before_patch"

echo "== Surgical restore avatar render =="
echo "Backup: $BACKUP"

python3 - <<'PY'
from pathlib import Path
import re

main = Path("/Users/inma/Documents/Vroid/Sources/VroidOverlay/main.m")
s = main.read_text()

# 1. Ensure SCNView uses the camera node explicitly.
needle = '''        _cameraNode.position = SCNVector3Make(0.0, 0.0, 8.0);
        [scene.rootNode addChildNode:_cameraNode];'''

replacement = '''        _cameraNode.position = SCNVector3Make(0.0, 0.0, 8.0);
        [scene.rootNode addChildNode:_cameraNode];
        self.pointOfView = _cameraNode;
        NSLog(@"[RENDER_RESTORE] pointOfView assigned to camera node");'''

if needle in s and "pointOfView assigned to camera node" not in s:
    s = s.replace(needle, replacement)
    print("patched: self.pointOfView = _cameraNode")
else:
    print("skip/warn: camera pointOfView patch not applied or already present")

# 2. Disable FaceCamera during loadModelAtURL. It mutates container position before centerAndFit.
s = s.replace(
'''    [self vroidRuntimeRepairLoadedContainer:container];
    [self vroidApplyTexturedVisibleFixToContainer:container];
    [self vroidApplyFaceCameraFixForContainer:container];
    [self centerAndFitNode:container];''',
'''    [self vroidRuntimeRepairLoadedContainer:container];
    [self vroidApplyTexturedVisibleFixToContainer:container];

    // Render restore: do not mutate container with FaceCamera before final centering.
    // [self vroidApplyFaceCameraFixForContainer:container];
    [self centerAndFitNode:container];'''
)

# 3. Restore camera in centerAndFitNode.
s = s.replace(
'''    CGFloat cameraDistance = MAX(2.5, largest * 3.0);
    /* disabled by face camera fix: _cameraNode.position = SCNVector3Make(0.0, 0.0, cameraDistance); */''',
'''    CGFloat cameraDistance = MAX(2.5, largest * 3.0);
    _cameraNode.position = SCNVector3Make(0.0, 0.0, cameraDistance);
    _cameraNode.eulerAngles = SCNVector3Make(0.0, 0.0, 0.0);
    _cameraNode.camera.usesOrthographicProjection = NO;
    _cameraNode.camera.fieldOfView = 35.0;
    self.pointOfView = _cameraNode;
    NSLog(@"[RENDER_RESTORE] centerAndFit cameraDistance=%.3f", cameraDistance);'''
)

# 4. Protect real avatar nodes from cleaner/hide routines.
# Insert a guard at the start of any rootChildren loop that might hide scene root nodes.
pattern = r'(for \(SCNNode \*node in rootChildren\) \{\n)'
guard = '''        if (node == _floatNode || node == _rotationNode || node == _modelContainer || node == _cameraNode) {
            NSLog(@"[RENDER_RESTORE] protecting avatar/camera root node from hide: %@", node);
            node.hidden = NO;
            node.opacity = 1.0;
            continue;
        }
'''
if "protecting avatar/camera root node from hide" not in s:
    s, n = re.subn(pattern, r'\1' + guard, s, count=1)
    print("patched: rootChildren hide guard", n)
else:
    print("skip: rootChildren guard already present")

# 5. After adding the model container, force parent chain visible.
needle2 = '''    _modelContainer = container;
    [_rotationNode addChildNode:container];'''
replacement2 = '''    _modelContainer = container;
    [_rotationNode addChildNode:container];

    _floatNode.hidden = NO;
    _floatNode.opacity = 1.0;
    _rotationNode.hidden = NO;
    _rotationNode.opacity = 1.0;
    _modelContainer.hidden = NO;
    _modelContainer.opacity = 1.0;
    NSLog(@"[RENDER_RESTORE] model attached. float hidden=%d rotation hidden=%d model hidden=%d children=%lu",
          _floatNode.hidden,
          _rotationNode.hidden,
          _modelContainer.hidden,
          (unsigned long)_modelContainer.childNodes.count);'''

if needle2 in s and "model attached. float hidden" not in s:
    s = s.replace(needle2, replacement2)
    print("patched: force model parent chain visible")
else:
    print("skip/warn: attach visibility patch not applied or already present")

# 6. Make fixed look rotation opt-in, not automatic.
fixed = '''    _rotationNode.eulerAngles = [self vroidFixedLookRotation];
    NSLog(@"[FIXED_ROTATION] applied x=-1.567 y=6.298 z=0.000");'''
fixed_replacement = '''    NSString *forceFixed = [[[NSProcessInfo processInfo] environment] objectForKey:@"VROID_FORCE_FIXED_ROTATION"];
    if (!forceFixed || forceFixed.length == 0) {
        NSLog(@"[FIXED_ROTATION] skipped by default; set VROID_FORCE_FIXED_ROTATION=1 to force");
        return;
    }

    _rotationNode.eulerAngles = [self vroidFixedLookRotation];
    NSLog(@"[FIXED_ROTATION] applied x=-1.567 y=6.298 z=0.000");'''

if fixed in s and "skipped by default; set VROID_FORCE_FIXED_ROTATION=1" not in s:
    s = s.replace(fixed, fixed_replacement)
    print("patched: fixed rotation opt-in")
else:
    print("skip/warn: fixed rotation patch not applied or already present")

main.write_text(s)
PY

echo ""
echo "== Sanity =="
grep -nE "RENDER_RESTORE|pointOfView|disabled by face camera|vroidApplyFaceCameraFixForContainer|protecting avatar" "$MAIN" | head -120 || true

echo ""
echo "== Build =="
bash "$PROJECT/build.sh"

echo ""
echo "== Run clean instance =="
pkill -f VroidOverlay || true
sleep 1

rm -f "$HOME/Library/Application Support/VroidOverlay/overlay_debug.log"
rm -f /tmp/vroid_render_restore.log

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
"$PROJECT/build/VroidOverlay.app/Contents/MacOS/VroidOverlay" 2>&1 | tee /tmp/vroid_render_restore.log
