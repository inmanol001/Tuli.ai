#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
MAIN="$PROJECT/Sources/VroidOverlay/main.m"
BACKUP="$PROJECT/backups_force_hide_rotation_window_$(date +%Y%m%d_%H%M%S)"

echo "== Force Hide Rotation Window =="
echo "Main: $MAIN"

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

main = Path("/Users/inma/Documents/Vroid/Sources/VroidOverlay/main.m")
text = main.read_text()

helpers = r'''

#pragma mark - VROID Force Hide Rotation Window

- (BOOL)vroidShowRotationPanelEnabled {
    NSString *value = [[[NSProcessInfo processInfo] environment] objectForKey:@"VROID_SHOW_ROTATION_PANEL"];
    if (!value) return NO;

    value = [value lowercaseString];

    return [value isEqualToString:@"1"] ||
           [value isEqualToString:@"true"] ||
           [value isEqualToString:@"yes"] ||
           [value isEqualToString:@"on"];
}

- (BOOL)vroidWindowLooksLikeRotationPanel:(NSWindow *)window {
    if (!window) return NO;

    NSString *title = window.title ?: @"";
    NSString *lowerTitle = [title lowercaseString];

    if ([lowerTitle containsString:@"rotation"] ||
        [lowerTitle containsString:@"rotacion"] ||
        [lowerTitle containsString:@"rotación"]) {
        return YES;
    }

    NSView *content = window.contentView;
    if (!content) return NO;

    NSString *viewDescription = [[content description] lowercaseString];

    if ([viewDescription containsString:@"rotation"] ||
        [viewDescription containsString:@"rotacion"] ||
        [viewDescription containsString:@"rotación"]) {
        return YES;
    }

    return NO;
}

- (void)vroidForceHideRotationPanelWindow {
    if ([self vroidShowRotationPanelEnabled]) {
        NSLog(@"[ROTATION_PANEL] visible because VROID_SHOW_ROTATION_PANEL=1");
        return;
    }

    NSArray<NSWindow *> *windows = [NSApp.windows copy];

    for (NSWindow *window in windows) {
        if ([self vroidWindowLooksLikeRotationPanel:window]) {
            NSLog(@"[ROTATION_PANEL] hiding window title='%@' class=%@",
                  window.title ?: @"",
                  NSStringFromClass(window.class));

            [window orderOut:nil];
            [window close];
        }
    }
}

- (void)vroidScheduleForceHideRotationPanelWindow {
    if ([self vroidShowRotationPanelEnabled]) {
        NSLog(@"[ROTATION_PANEL] not hiding; VROID_SHOW_ROTATION_PANEL=1");
        return;
    }

    // Ejecutar varias veces porque el panel puede crearse después de abrir la app.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self vroidForceHideRotationPanelWindow];
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self vroidForceHideRotationPanelWindow];
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.50 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self vroidForceHideRotationPanelWindow];
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.00 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self vroidForceHideRotationPanelWindow];
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.00 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self vroidForceHideRotationPanelWindow];
    });
}

'''

if "vroidScheduleForceHideRotationPanelWindow" not in text:
    marker = "- (void)centerAndFitNode:(SCNNode *)node"
    if marker in text:
        text = text.replace(marker, helpers + "\n" + marker, 1)
    else:
        idx = text.rfind("@end")
        if idx == -1:
            raise SystemExit("No encontré lugar para insertar helpers.")
        text = text[:idx] + helpers + "\n" + text[idx:]

# Hook after likely window/model setup points.
if "[self vroidScheduleForceHideRotationPanelWindow];" not in text:
    hooks = [
        "[window makeKeyAndOrderFront:nil];",
        "[self.window makeKeyAndOrderFront:nil];",
        "[_window makeKeyAndOrderFront:nil];",
        "[self vroidApplyFixedLookRotation];",
        "[self vroidApplyFaceCameraFixForContainer:container];",
        "[self vroidApplyTexturedVisibleFixToContainer:container];",
        "[self vroidApplyCleanOverlayMode];",
        "[self centerAndFitNode:container];",
    ]

    inserted = False
    for hook in hooks:
        if hook in text:
            text = text.replace(
                hook,
                hook + "\n    [self vroidScheduleForceHideRotationPanelWindow];",
                1
            )
            inserted = True
            break

    if not inserted:
        raise SystemExit("No encontré hook para llamar vroidScheduleForceHideRotationPanelWindow.")

main.write_text(text)
print("main.m patched OK")
PY

echo ""
echo "== Verificando cambios =="
grep -n "vroidScheduleForceHideRotationPanelWindow\|vroidForceHideRotationPanelWindow\|VROID_SHOW_ROTATION_PANEL" "$MAIN" || true

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
echo "Abre normal, panel oculto:"
echo "./build/VroidOverlay.app/Contents/MacOS/VroidOverlay"
echo ""
echo "Mostrar temporalmente el panel si lo necesitas:"
echo "VROID_SHOW_ROTATION_PANEL=1 ./build/VroidOverlay.app/Contents/MacOS/VroidOverlay"
echo ""
echo "Restaurar si algo falla:"
echo "cp '$BACKUP/main.m.backup' '$MAIN'"
