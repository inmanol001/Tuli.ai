#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
MAIN="$PROJECT/Sources/VroidOverlay/main.m"
BACKUP="$PROJECT/backups_emergency_restore_3d_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$BACKUP"
cp "$MAIN" "$BACKUP/main.m.before_emergency_patch"

echo "== Emergency restore 3D visibility + compile =="
echo "Backup: $BACKUP"

python3 - <<'PY'
from pathlib import Path
import re

main = Path("/Users/inma/Documents/Vroid/Sources/VroidOverlay/main.m")
s = main.read_text()

print("Original size:", len(s))

# 1. Remove investigation declaration/calls/method leftovers.
s = s.replace("- (void)vroidInvestigationDump3DState:(NSString *)label;\n", "")
s = re.sub(r'\n\s*\[self vroidInvestigationDump3DState:@"[^"]*"\];', '', s)

# Remove broken method block if present.
start = s.find("- (void)vroidInvestigationDump3DState:")
if start != -1:
    # Remove until the next Objective-C method or @end after the block.
    next_method = re.search(r'\n[-+] \([^)]+\)', s[start + 10:])
    next_end = s.find("\n@end", start + 10)
    candidates = []
    if next_method:
        candidates.append(start + 10 + next_method.start())
    if next_end != -1:
        candidates.append(next_end)
    if candidates:
        end = min(candidates)
        s = s[:start] + "\n" + s[end:]
        print("Removed investigation method block")
    else:
        print("WARN: found investigation method but could not safely remove full block")

# 2. Add missing _cameraNode ivar if code uses it.
uses_camera_node = "_cameraNode" in s
declares_camera_node = re.search(r'SCNNode\s*\*\s*_cameraNode\s*;', s) is not None

if uses_camera_node and not declares_camera_node:
    m = re.search(r'(@implementation\s+OverlaySceneView\s*\{\n)', s)
    if m:
        s = s[:m.end()] + "    SCNNode *_cameraNode;\n" + s[m.end():]
        print("Added SCNNode *_cameraNode ivar")
    else:
        print("WARN: could not find OverlaySceneView ivar block for _cameraNode")

# 3. Add a safe visibility helper inside OverlaySceneView if not present.
if "vroidEmergencyForce3DVisible" not in s:
    m = re.search(r'(@implementation\s+OverlaySceneView\s*\{[^}]*\}\n)', s, re.S)
    if not m:
        m = re.search(r'(@implementation\s+OverlaySceneView[^\n]*\n)', s)

    if not m:
        raise SystemExit("Could not find @implementation OverlaySceneView")

    helper = r'''
- (void)vroidEmergencyForce3DVisible:(SCNNode *)node {
    if (!node) return;

    node.hidden = NO;
    node.opacity = 1.0;

    if (fabs(node.scale.x) < 0.0001 || fabs(node.scale.y) < 0.0001 || fabs(node.scale.z) < 0.0001) {
        node.scale = SCNVector3Make(1.0, 1.0, 1.0);
        NSLog(@"[EMERGENCY_3D] fixed zero scale on node=%@", node);
    }

    for (SCNNode *child in node.childNodes) {
        [self vroidEmergencyForce3DVisible:child];
    }
}

- (void)vroidEmergencyForceSceneVisible {
    NSLog(@"[EMERGENCY_3D] force scene visible");

    self.hidden = NO;
    self.alphaValue = 1.0;
    self.wantsLayer = YES;

    @try {
        if (_sceneView) {
            _sceneView.hidden = NO;
            _sceneView.alphaValue = 1.0;
            _sceneView.wantsLayer = YES;
            _sceneView.frame = self.bounds;
            NSLog(@"[EMERGENCY_3D] sceneView frame=%@ hidden=%d alpha=%.3f",
                  NSStringFromRect(_sceneView.frame),
                  _sceneView.hidden,
                  _sceneView.alphaValue);
        }
    } @catch (NSException *e) {
        NSLog(@"[EMERGENCY_3D] sceneView exception=%@ %@", e.name, e.reason);
    }

    @try {
        if (_containerNode) {
            [self vroidEmergencyForce3DVisible:_containerNode];
            _containerNode.position = SCNVector3Make(0, 0, 0);
            if (fabs(_containerNode.scale.x) < 0.0001 || fabs(_containerNode.scale.y) < 0.0001 || fabs(_containerNode.scale.z) < 0.0001) {
                _containerNode.scale = SCNVector3Make(1, 1, 1);
            }
            NSLog(@"[EMERGENCY_3D] container hidden=%d opacity=%.3f scale=(%.3f %.3f %.3f) pos=(%.3f %.3f %.3f) children=%lu",
                  _containerNode.hidden,
                  _containerNode.opacity,
                  _containerNode.scale.x, _containerNode.scale.y, _containerNode.scale.z,
                  _containerNode.position.x, _containerNode.position.y, _containerNode.position.z,
                  (unsigned long)_containerNode.childNodes.count);
        } else {
            NSLog(@"[EMERGENCY_3D] container is nil");
        }
    } @catch (NSException *e) {
        NSLog(@"[EMERGENCY_3D] container exception=%@ %@", e.name, e.reason);
    }

    @try {
        if (_cameraNode && _cameraNode.camera) {
            _cameraNode.hidden = NO;
            _cameraNode.opacity = 1.0;
            _cameraNode.position = SCNVector3Make(0.0, 0.0, 8.0);
            _cameraNode.eulerAngles = SCNVector3Make(0.0, 0.0, 0.0);
            _cameraNode.camera.usesOrthographicProjection = NO;
            _cameraNode.camera.fieldOfView = 35.0;
            _cameraNode.camera.zNear = 0.001;
            _cameraNode.camera.zFar = 200.0;
            NSLog(@"[EMERGENCY_3D] camera pos=(%.3f %.3f %.3f) fov=%.3f",
                  _cameraNode.position.x,
                  _cameraNode.position.y,
                  _cameraNode.position.z,
                  _cameraNode.camera.fieldOfView);
        } else {
            NSLog(@"[EMERGENCY_3D] camera missing or nil");
        }
    } @catch (NSException *e) {
        NSLog(@"[EMERGENCY_3D] camera exception=%@ %@", e.name, e.reason);
    }
}

'''
    s = s[:m.end()] + helper + s[m.end():]
    print("Added emergency visibility helper")

# 4. Inject emergency force after model setup calls.
targets = [
    "[self centerAndFitNode:container];",
    "[self vroidApplyFaceCameraFixForContainer:container];",
    "[self vroidApplyTexturedVisibleFixToContainer:container];",
    "[self vroidRuntimeRepairLoadedContainer:container];",
    "[self vroidApplyFloatAnimationToNode:_floatNode];",
]

injected = False
for t in targets:
    if t in s and "[self vroidEmergencyForceSceneVisible];" not in s:
        s = s.replace(t, t + "\n    [self vroidEmergencyForceSceneVisible];", 1)
        print("Injected after:", t)
        injected = True
        break

# Also inject into layout if possible so it re-forces after resize.
if "layout" in s and "vroidEmergencyForceSceneVisible" in s:
    # Keep this conservative: only add to setFrameSize if it exists.
    if "- (void)setFrameSize:" in s and "emergency-frame-size" not in s:
        s = re.sub(
            r'(- \(void\)setFrameSize:\(NSSize\)newSize\s*\{\n\s*\[super setFrameSize:newSize\];)',
            r'\1\n    [self vroidEmergencyForceSceneVisible]; // emergency-frame-size',
            s,
            count=1
        )

# 5. Ensure no broken investigation refs remain.
if "vroidInvestigationDump3DState" in s:
    print("WARN: investigation text still present")
else:
    print("OK: no investigation refs")

main.write_text(s)
print("New size:", len(s))
PY

echo ""
echo "== Source sanity =="
grep -n "vroidInvestigationDump3DState" "$MAIN" || echo "OK: no investigation refs"
grep -n "vroidEmergencyForceSceneVisible" "$MAIN" | head -20 || true
grep -n "SCNNode \\*_cameraNode" "$MAIN" || true

echo ""
echo "== Build =="
bash "$PROJECT/build.sh"

echo ""
echo "== Kill duplicate app instances =="
pkill -f VroidOverlay || true
sleep 1

echo ""
echo "== Clear logs =="
rm -f "$HOME/Library/Application Support/VroidOverlay/overlay_debug.log"
rm -f /tmp/vroid_emergency_3d.log

echo ""
echo "== Run app =="
echo "Deja esta terminal abierta."
echo ""

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
"$PROJECT/build/VroidOverlay.app/Contents/MacOS/VroidOverlay" 2>&1 | tee /tmp/vroid_emergency_3d.log
