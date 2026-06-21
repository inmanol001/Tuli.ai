#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
MAIN="$PROJECT/Sources/VroidOverlay/main.m"
BACKUP_SOURCE="$(find "$PROJECT" -maxdepth 1 -type d -name 'backups_investigate_3d_visibility_*' -print | sort | tail -1)"
BACKUP_NOW="$PROJECT/backups_fix_3d_investigation_compile_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$BACKUP_NOW"

echo "== Fix 3D investigation compile patch =="
echo "MAIN=$MAIN"
echo "BACKUP_SOURCE=$BACKUP_SOURCE"
echo "BACKUP_NOW=$BACKUP_NOW"

cp "$MAIN" "$BACKUP_NOW/main.m.before_fix"

echo ""
echo "== 1. Restore original main.m from investigation backup =="
if [ -f "$BACKUP_SOURCE/main.m.backup" ]; then
  cp "$BACKUP_SOURCE/main.m.backup" "$MAIN"
  echo "Restored: $BACKUP_SOURCE/main.m.backup"
else
  echo "ERROR: no main.m.backup found in $BACKUP_SOURCE"
  exit 1
fi

echo ""
echo "== 2. Apply corrected investigation method inside OverlaySceneView =="
python3 - <<'PY'
from pathlib import Path
import re

main = Path("/Users/inma/Documents/Vroid/Sources/VroidOverlay/main.m")
s = main.read_text()

if "vroidInvestigationDump3DState" in s:
    raise SystemExit("Unexpected: investigation method already exists after restore")

# Add method declaration to @interface OverlaySceneView.
m = re.search(r'(@interface\s+OverlaySceneView\b[^\n]*\n)', s)
if not m:
    raise SystemExit("Could not find @interface OverlaySceneView")

insert_pos = m.end()
decl = "- (void)vroidInvestigationDump3DState:(NSString *)label;\n"
s = s[:insert_pos] + decl + s[insert_pos:]

# Find @implementation OverlaySceneView.
m = re.search(r'(@implementation\s+OverlaySceneView\b[^\n]*\n)', s)
if not m:
    raise SystemExit("Could not find @implementation OverlaySceneView")

helper = r'''
- (void)vroidInvestigationDump3DState:(NSString *)label {
    @try {
        NSLog(@"[INVESTIGATE_3D] label=%@", label);

        NSWindow *w = [self window];
        NSLog(@"[INVESTIGATE_3D] window=%@ visible=%d alpha=%.3f frame=%@ level=%ld",
              w,
              w ? [w isVisible] : 0,
              w ? [w alphaValue] : -1.0,
              w ? NSStringFromRect([w frame]) : @"nil",
              w ? (long)[w level] : -999L);

        NSLog(@"[INVESTIGATE_3D] self=%@ class=%@ hidden=%d alpha=%.3f frame=%@ bounds=%@ subviews=%lu superview=%@",
              self,
              NSStringFromClass([self class]),
              [self isHidden],
              [self alphaValue],
              NSStringFromRect([self frame]),
              NSStringFromRect([self bounds]),
              (unsigned long)[[self subviews] count],
              [self superview]);

        NSUInteger idx = 0;
        for (NSView *v in [self subviews]) {
            NSLog(@"[INVESTIGATE_3D] subview[%lu]=%@ class=%@ hidden=%d alpha=%.3f frame=%@ bounds=%@ layer=%@",
                  (unsigned long)idx,
                  v,
                  NSStringFromClass([v class]),
                  [v isHidden],
                  [v alphaValue],
                  NSStringFromRect([v frame]),
                  NSStringFromRect([v bounds]),
                  [v layer]);
            idx++;
        }

        NSArray *viewNames = @[@"_sceneView", @"sceneView", @"_scnView", @"_avatarView", @"_modelView"];
        for (NSString *name in viewNames) {
            @try {
                id value = [self valueForKey:name];
                if (value) {
                    NSLog(@"[INVESTIGATE_3D] viewRef %@=%@ class=%@", name, value, NSStringFromClass([value class]));

                    if ([value isKindOfClass:[NSView class]]) {
                        NSView *vv = (NSView *)value;
                        NSLog(@"[INVESTIGATE_3D] viewRef %@ hidden=%d alpha=%.3f frame=%@ bounds=%@ superview=%@",
                              name, [vv isHidden], [vv alphaValue],
                              NSStringFromRect([vv frame]), NSStringFromRect([vv bounds]), [vv superview]);
                    }

                    if ([value respondsToSelector:@selector(scene)]) {
                        id scene = [value valueForKey:@"scene"];
                        NSLog(@"[INVESTIGATE_3D] viewRef %@ scene=%@", name, scene);
                    }

                    if ([value respondsToSelector:@selector(pointOfView)]) {
                        id pov = [value valueForKey:@"pointOfView"];
                        NSLog(@"[INVESTIGATE_3D] viewRef %@ pointOfView=%@", name, pov);
                    }
                }
            } @catch (NSException *e) {
                NSLog(@"[INVESTIGATE_3D] viewRef %@ exception=%@ reason=%@", name, [e name], [e reason]);
            }
        }

        NSArray *nodeNames = @[@"_containerNode", @"_modelNode", @"_avatarNode", @"_rootModelNode", @"_rotationNode", @"_floatNode", @"_cameraNode"];
        for (NSString *name in nodeNames) {
            @try {
                id value = [self valueForKey:name];
                if (value) {
                    NSLog(@"[INVESTIGATE_3D] node %@=%@ class=%@", name, value, NSStringFromClass([value class]));

                    if ([value respondsToSelector:@selector(isHidden)]) {
                        BOOL hidden = ((BOOL (*)(id, SEL))[value methodForSelector:@selector(isHidden)])(value, @selector(isHidden));
                        NSLog(@"[INVESTIGATE_3D] node %@ hidden=%d", name, hidden);
                    }

                    if ([value respondsToSelector:@selector(opacity)]) {
                        CGFloat opacity = ((CGFloat (*)(id, SEL))[value methodForSelector:@selector(opacity)])(value, @selector(opacity));
                        NSLog(@"[INVESTIGATE_3D] node %@ opacity=%.3f", name, opacity);
                    }

                    if ([value respondsToSelector:@selector(childNodes)]) {
                        NSArray *children = [value valueForKey:@"childNodes"];
                        NSLog(@"[INVESTIGATE_3D] node %@ children=%lu", name, (unsigned long)[children count]);
                    }

                    if ([value respondsToSelector:@selector(position)]) {
                        SCNVector3 p = ((SCNVector3 (*)(id, SEL))[value methodForSelector:@selector(position)])(value, @selector(position));
                        NSLog(@"[INVESTIGATE_3D] node %@ position=(%.4f, %.4f, %.4f)", name, p.x, p.y, p.z);
                    }

                    if ([value respondsToSelector:@selector(scale)]) {
                        SCNVector3 sc = ((SCNVector3 (*)(id, SEL))[value methodForSelector:@selector(scale)])(value, @selector(scale));
                        NSLog(@"[INVESTIGATE_3D] node %@ scale=(%.4f, %.4f, %.4f)", name, sc.x, sc.y, sc.z);
                    }

                    if ([value respondsToSelector:@selector(eulerAngles)]) {
                        SCNVector3 e = ((SCNVector3 (*)(id, SEL))[value methodForSelector:@selector(eulerAngles)])(value, @selector(eulerAngles));
                        NSLog(@"[INVESTIGATE_3D] node %@ euler=(%.4f, %.4f, %.4f)", name, e.x, e.y, e.z);
                    }
                } else {
                    NSLog(@"[INVESTIGATE_3D] node %@=nil", name);
                }
            } @catch (NSException *e) {
                NSLog(@"[INVESTIGATE_3D] node %@ exception=%@ reason=%@", name, [e name], [e reason]);
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[INVESTIGATE_3D] exception=%@ reason=%@", [e name], [e reason]);
    }
}

'''

# Insert helper right after @implementation OverlaySceneView.
pos = m.end()
s = s[:pos] + helper + s[pos:]

# Inject logs after known 3D calls inside OverlaySceneView.
known_calls = [
    "[self vroidRuntimeRepairLoadedContainer:container];",
    "[self vroidApplyTexturedVisibleFixToContainer:container];",
    "[self vroidApplyFaceCameraFixForContainer:container];",
    "[self centerAndFitNode:container];",
    "[self vroidApplyFloatAnimationToNode:_floatNode];",
]

for call in known_calls:
    if call in s:
        label = call.replace('"', '').replace('[self ', '').replace('];', '')
        s = s.replace(call, call + f'\n    [self vroidInvestigationDump3DState:@"after {label}"];')

# Also add a delayed dump in viewDidMoveToWindow if method exists.
if "- (void)viewDidMoveToWindow" in s:
    s = re.sub(
        r'(- \(void\)viewDidMoveToWindow\s*\{\n)',
        r'''\1    [super viewDidMoveToWindow];
    NSLog(@"[INVESTIGATE_3D] viewDidMoveToWindow entered");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self vroidInvestigationDump3DState:@"viewDidMoveToWindow-1s"];
    });
''',
        s,
        count=1
    )

main.write_text(s)
print("patched", main)
PY

echo ""
echo "== 3. Build =="
bash "$PROJECT/build.sh"

echo ""
echo "== 4. Kill duplicate VroidOverlay =="
pkill -f VroidOverlay || true
sleep 1

echo ""
echo "== 5. Clear logs =="
rm -f "$HOME/Library/Application Support/VroidOverlay/overlay_debug.log"
rm -f /tmp/vroid_3d_investigation_live.log

echo ""
echo "== 6. Run app with investigation flags =="
echo "Deja esta terminal abierta 10-15 segundos."
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
"$PROJECT/build/VroidOverlay.app/Contents/MacOS/VroidOverlay" 2>&1 | tee /tmp/vroid_3d_investigation_live.log
