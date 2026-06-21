#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
MAIN="$PROJECT/Sources/VroidOverlay/main.m"
BACKUP="$PROJECT/backups_investigate_3d_visibility_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$BACKUP"
cp "$MAIN" "$BACKUP/main.m.backup"

echo "== Patch investigation logs for 3D visibility =="
echo "Backup: $BACKUP"

python3 - <<'PY'
from pathlib import Path
import re

main = Path("/Users/inma/Documents/Vroid/Sources/VroidOverlay/main.m")
s = main.read_text()

if "vroidInvestigationDump3DState" in s:
    print("Investigation patch already present")
    main.write_text(s)
    raise SystemExit(0)

# Add helper method before @end of the main implementation.
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

        NSView *content = w ? [w contentView] : nil;
        NSLog(@"[INVESTIGATE_3D] content=%@ hidden=%d alpha=%.3f frame=%@ subviews=%lu",
              content,
              content ? [content isHidden] : 0,
              content ? [content alphaValue] : -1.0,
              content ? NSStringFromRect([content frame]) : @"nil",
              content ? (unsigned long)[[content subviews] count] : 0);

        NSUInteger idx = 0;
        for (NSView *v in [content subviews]) {
            NSLog(@"[INVESTIGATE_3D] subview[%lu]=%@ class=%@ hidden=%d alpha=%.3f frame=%@ layer=%@",
                  (unsigned long)idx,
                  v,
                  NSStringFromClass([v class]),
                  [v isHidden],
                  [v alphaValue],
                  NSStringFromRect([v frame]),
                  [v layer]);
            idx++;
        }

        NSArray *ivars = @[@"_sceneView", @"sceneView", @"_scnView", @"_avatarView", @"_modelView"];
        for (NSString *name in ivars) {
            @try {
                id value = [self valueForKey:name];
                if (value) {
                    NSLog(@"[INVESTIGATE_3D] ivar %@=%@ class=%@", name, value, NSStringFromClass([value class]));
                    if ([value isKindOfClass:[NSView class]]) {
                        NSView *vv = (NSView *)value;
                        NSLog(@"[INVESTIGATE_3D] ivarView %@ hidden=%d alpha=%.3f frame=%@ superview=%@",
                              name, [vv isHidden], [vv alphaValue], NSStringFromRect([vv frame]), [vv superview]);
                    }
                    if ([value respondsToSelector:@selector(scene)]) {
                        id scene = [value valueForKey:@"scene"];
                        NSLog(@"[INVESTIGATE_3D] %@ scene=%@", name, scene);
                    }
                    if ([value respondsToSelector:@selector(pointOfView)]) {
                        id pov = [value valueForKey:@"pointOfView"];
                        NSLog(@"[INVESTIGATE_3D] %@ pointOfView=%@", name, pov);
                    }
                }
            } @catch (NSException *e) {
            }
        }

        NSArray *nodeNames = @[@"_containerNode", @"_modelNode", @"_avatarNode", @"_rootModelNode", @"_rotationNode", @"_floatNode"];
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
                }
            } @catch (NSException *e) {
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[INVESTIGATE_3D] exception=%@ reason=%@", [e name], [e reason]);
    }
}
'''

# Insert helper before the final @end.
last_end = s.rfind("\n@end")
if last_end == -1:
    raise SystemExit("Could not find @end in main.m")
s = s[:last_end] + "\n" + helper + "\n" + s[last_end:]

# Add delayed calls after app launch if possible.
patterns = [
    r'(- \(void\)applicationDidFinishLaunching:\(NSNotification \*\)notification \{\n)',
    r'(- \(void\)applicationDidFinishLaunching:\(NSNotification \*\)aNotification \{\n)',
]
inserted = False
for pat in patterns:
    m = re.search(pat, s)
    if m:
        pos = m.end()
        injection = r'''
    NSLog(@"[INVESTIGATE_3D] applicationDidFinishLaunching entered");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self vroidInvestigationDump3DState:@"after-launch-1s"];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self vroidInvestigationDump3DState:@"after-launch-3s"];
    });
'''
        s = s[:pos] + injection + s[pos:]
        inserted = True
        break

if not inserted:
    print("WARN: applicationDidFinishLaunching not found. Adding investigation method only.")

# Add explicit dumps around known 3D operations if those calls exist.
known_calls = [
    "[self centerAndFitNode:container];",
    "[self vroidApplyFaceCameraFixForContainer:container];",
    "[self vroidApplyTexturedVisibleFixToContainer:container];",
    "[self vroidRuntimeRepairLoadedContainer:container];",
    "[self vroidApplyFloatAnimationToNode:_floatNode];",
]
for call in known_calls:
    if call in s:
        s = s.replace(call, call + f'\n    [self vroidInvestigationDump3DState:@"after {call.replace(chr(34), "")}"];')

main.write_text(s)
print("patched", main)
PY

echo ""
echo "== Build =="
if [ -x "$PROJECT/build.sh" ]; then
  "$PROJECT/build.sh"
else
  echo "No build.sh found. Trying make..."
  make
fi

echo ""
echo "== Kill duplicate VroidOverlay =="
pkill -f VroidOverlay || true
sleep 1

echo ""
echo "== Clear old overlay debug =="
rm -f "$HOME/Library/Application Support/VroidOverlay/overlay_debug.log"
rm -f /tmp/vroid_3d_investigation_live.log

echo ""
echo "== Run app with investigation flags =="
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
