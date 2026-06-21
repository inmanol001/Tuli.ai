#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
MAIN="$PROJECT/Sources/VroidOverlay/main.m"
BACKUP="$PROJECT/backups_manual_mouse_repulsion_v1_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$BACKUP"
cp "$MAIN" "$BACKUP/main.m.before_mouse_repulsion_v1"

echo "== Manual mouse repulsion v1 =="
echo "Backup: $BACKUP"
echo ""
echo "Este patch NO toca:"
echo "- burbuja/dialog"
echo "- SceneKit/modelo"
echo "- cámara"
echo "- Kokoro"
echo "- memoria"
echo ""

python3 - <<'PY'
from pathlib import Path
import re

main = Path("/Users/inma/Documents/Vroid/Sources/VroidOverlay/main.m")
s = main.read_text()

if "TULI_MANUAL_MOUSE_REPULSION_V1" in s:
    print("Mouse repulsion v1 ya está instalado.")
    raise SystemExit(0)

# 1. Add ivars inside OverlaySceneView implementation ivar block.
m = re.search(r'(@implementation OverlaySceneView\s*\{)(.*?)(\n\})', s, re.S)
if not m:
    raise SystemExit("ERROR: no encontré el bloque de ivars de @implementation OverlaySceneView")

ivars = """
    // TULI_MANUAL_MOUSE_REPULSION_V1
    NSTimer *_tuliMouseRepelTimer;
    NSPoint _tuliMouseRepelVelocity;
    BOOL _tuliMouseRepelEnabled;
"""

body = m.group(2)
if "_tuliMouseRepelTimer" not in body:
    s = s[:m.end(2)] + ivars + s[m.end(2):]
    print("added mouse repel ivars")

# 2. Insert methods right after ivar block.
m = re.search(r'@implementation OverlaySceneView\s*\{.*?\n\}', s, re.S)
if not m:
    raise SystemExit("ERROR: no encontré cierre de ivars")

insert_pos = m.end()

methods = r'''

#pragma mark - TULI_MANUAL_MOUSE_REPULSION_V1

- (BOOL)tuliMouseRepelIsEnabled {
    NSString *value = [[[NSProcessInfo processInfo] environment] objectForKey:@"TULI_MOUSE_REPEL"];
    if (value.length == 0) {
        return YES;
    }

    NSString *lower = [value lowercaseString];
    if ([lower isEqualToString:@"0"] ||
        [lower isEqualToString:@"false"] ||
        [lower isEqualToString:@"no"] ||
        [lower isEqualToString:@"off"]) {
        return NO;
    }

    return YES;
}

- (CGFloat)tuliMouseRepelFloatEnv:(NSString *)name defaultValue:(CGFloat)fallback {
    NSString *value = [[[NSProcessInfo processInfo] environment] objectForKey:name];
    if (value.length == 0) {
        return fallback;
    }

    return (CGFloat)[value doubleValue];
}

- (void)tuliStartMouseRepulsion {
    if (_tuliMouseRepelTimer != nil) {
        return;
    }

    _tuliMouseRepelEnabled = [self tuliMouseRepelIsEnabled];
    _tuliMouseRepelVelocity = NSMakePoint(0.0, 0.0);

    if (!_tuliMouseRepelEnabled) {
        NSLog(@"[TULI_REPEL] disabled by TULI_MOUSE_REPEL");
        return;
    }

    __weak typeof(self) weakSelf = self;
    _tuliMouseRepelTimer = [NSTimer scheduledTimerWithTimeInterval:0.035 repeats:YES block:^(NSTimer *timer) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            [timer invalidate];
            return;
        }

        [strongSelf tuliTickMouseRepulsion];
    }];

    [[NSRunLoop mainRunLoop] addTimer:_tuliMouseRepelTimer forMode:NSRunLoopCommonModes];
    NSLog(@"[TULI_REPEL] started");
}

- (void)tuliStopMouseRepulsion {
    if (_tuliMouseRepelTimer != nil) {
        [_tuliMouseRepelTimer invalidate];
        _tuliMouseRepelTimer = nil;
    }

    _tuliMouseRepelVelocity = NSMakePoint(0.0, 0.0);
    NSLog(@"[TULI_REPEL] stopped");
}

- (NSPoint)tuliClampedWindowOrigin:(NSPoint)origin frameSize:(NSSize)size {
    NSScreen *screen = self.window.screen ?: [NSScreen mainScreen];
    if (!screen) {
        return origin;
    }

    NSRect visible = screen.visibleFrame;

    if (origin.x < NSMinX(visible)) {
        origin.x = NSMinX(visible);
    }
    if (origin.y < NSMinY(visible)) {
        origin.y = NSMinY(visible);
    }
    if (origin.x + size.width > NSMaxX(visible)) {
        origin.x = NSMaxX(visible) - size.width;
    }
    if (origin.y + size.height > NSMaxY(visible)) {
        origin.y = NSMaxY(visible) - size.height;
    }

    return origin;
}

- (void)tuliTickMouseRepulsion {
    if (!_tuliMouseRepelEnabled || self.window == nil) {
        return;
    }

    NSWindow *window = self.window;
    NSRect frame = window.frame;
    NSPoint mouse = [NSEvent mouseLocation];

    NSPoint center = NSMakePoint(NSMidX(frame), NSMidY(frame));
    CGFloat dx = center.x - mouse.x;
    CGFloat dy = center.y - mouse.y;
    CGFloat distance = sqrt(dx * dx + dy * dy);

    CGFloat radius = [self tuliMouseRepelFloatEnv:@"TULI_MOUSE_REPEL_RADIUS" defaultValue:210.0];
    CGFloat strength = [self tuliMouseRepelFloatEnv:@"TULI_MOUSE_REPEL_STRENGTH" defaultValue:18.0];
    CGFloat damping = [self tuliMouseRepelFloatEnv:@"TULI_MOUSE_REPEL_DAMPING" defaultValue:0.78];
    CGFloat maxStep = [self tuliMouseRepelFloatEnv:@"TULI_MOUSE_REPEL_MAX_STEP" defaultValue:22.0];

    if (distance < 1.0) {
        distance = 1.0;
        dx = 1.0;
        dy = 0.0;
    }

    if (distance < radius) {
        CGFloat pressure = (radius - distance) / radius;
        CGFloat impulse = strength * pressure * pressure;

        CGFloat nx = dx / distance;
        CGFloat ny = dy / distance;

        _tuliMouseRepelVelocity.x += nx * impulse;
        _tuliMouseRepelVelocity.y += ny * impulse;

        NSLog(@"[TULI_REPEL] mouse close distance=%.1f pressure=%.3f velocity=(%.2f, %.2f)",
              distance,
              pressure,
              _tuliMouseRepelVelocity.x,
              _tuliMouseRepelVelocity.y);
    }

    _tuliMouseRepelVelocity.x *= damping;
    _tuliMouseRepelVelocity.y *= damping;

    if (fabs(_tuliMouseRepelVelocity.x) < 0.05 &&
        fabs(_tuliMouseRepelVelocity.y) < 0.05) {
        return;
    }

    CGFloat stepX = MAX(-maxStep, MIN(maxStep, _tuliMouseRepelVelocity.x));
    CGFloat stepY = MAX(-maxStep, MIN(maxStep, _tuliMouseRepelVelocity.y));

    NSPoint nextOrigin = NSMakePoint(frame.origin.x + stepX, frame.origin.y + stepY);
    nextOrigin = [self tuliClampedWindowOrigin:nextOrigin frameSize:frame.size];

    [window setFrameOrigin:nextOrigin];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];

    if (self.window != nil) {
        [self.window setAcceptsMouseMovedEvents:YES];
        [self tuliStartMouseRepulsion];
    } else {
        [self tuliStopMouseRepulsion];
    }
}

'''

s = s[:insert_pos] + methods + s[insert_pos:]
print("added manual mouse repulsion methods")

main.write_text(s)
PY

echo ""
echo "== Sanity =="
grep -nE "TULI_MANUAL_MOUSE_REPULSION_V1|tuliStartMouseRepulsion|tuliTickMouseRepulsion|viewDidMoveToWindow|TULI_REPEL" "$MAIN" | head -120 || true

echo ""
echo "== Build =="
if bash "$PROJECT/build.sh"; then
  echo ""
  echo "== BUILD OK =="
  echo "Backup:"
  echo "$BACKUP/main.m.before_mouse_repulsion_v1"
else
  echo ""
  echo "== BUILD FAILED: rollback =="
  cp "$BACKUP/main.m.before_mouse_repulsion_v1" "$MAIN"
  bash "$PROJECT/build.sh" || true
  echo "Rollback listo:"
  echo "$BACKUP/main.m.before_mouse_repulsion_v1"
  exit 1
fi
