#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
MAIN="$PROJECT/Sources/VroidOverlay/main.m"
BACKUP="$PROJECT/backups_hide_ui_gizmo_$(date +%Y%m%d_%H%M%S)"

echo "== Hide Vroid Rotation Panel + Gizmo =="
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
import re

main = Path("/Users/inma/Documents/Vroid/Sources/VroidOverlay/main.m")
text = main.read_text()

helpers = r'''

#pragma mark - VROID Hide Rotation UI / Gizmo

- (BOOL)vroidShowControlsEnabled {
    NSString *value = [[[NSProcessInfo processInfo] environment] objectForKey:@"VROID_SHOW_CONTROLS"];
    if (!value) return NO;
    value = [value lowercaseString];

    return [value isEqualToString:@"1"] ||
           [value isEqualToString:@"true"] ||
           [value isEqualToString:@"yes"] ||
           [value isEqualToString:@"on"];
}

- (BOOL)vroidShowGizmoEnabled {
    NSString *value = [[[NSProcessInfo processInfo] environment] objectForKey:@"VROID_SHOW_GIZMO"];
    if (!value) return NO;
    value = [value lowercaseString];

    return [value isEqualToString:@"1"] ||
           [value isEqualToString:@"true"] ||
           [value isEqualToString:@"yes"] ||
           [value isEqualToString:@"on"];
}

- (BOOL)vroidViewContainsSceneView:(NSView *)view {
    if (!view) return NO;

    if ([view isKindOfClass:[SCNView class]]) {
        return YES;
    }

    for (NSView *child in view.subviews) {
        if ([self vroidViewContainsSceneView:child]) {
            return YES;
        }
    }

    return NO;
}

- (void)vroidHideRotationPanelInView:(NSView *)view {
    if (!view) return;

    if ([self vroidShowControlsEnabled]) {
        NSLog(@"[HIDE_UI] VROID_SHOW_CONTROLS=1 active; controls visible");
        return;
    }

    for (NSView *child in [view.subviews copy]) {
        if ([child isKindOfClass:[SCNView class]]) {
            child.hidden = NO;
            continue;
        }

        BOOL childContainsScene = [self vroidViewContainsSceneView:child];

        if (childContainsScene) {
            [self vroidHideRotationPanelInView:child];
        } else {
            child.hidden = YES;
            child.alphaValue = 0.0;
            NSLog(@"[HIDE_UI] hidden overlay/control view: %@", child);
        }
    }
}

- (void)vroidHideAxesGizmo {
    if ([self vroidShowGizmoEnabled]) {
        NSLog(@"[HIDE_GIZMO] VROID_SHOW_GIZMO=1 active; gizmo visible");
        return;
    }

    if (_axesNode) {
        _axesNode.hidden = YES;
        _axesNode.opacity = 0.0;
        [_axesNode removeFromParentNode];
        NSLog(@"[HIDE_GIZMO] axes/gizmo node removed");
    }

    NSArray<SCNNode *> *rootChildren = [self.scene.rootNode.childNodes copy];
    for (SCNNode *node in rootChildren) {
        NSString *name = node.name ?: @"";
        NSString *lower = [name lowercaseString];

        if ([lower containsString:@"axis"] ||
            [lower containsString:@"axes"] ||
            [lower containsString:@"gizmo"] ||
            [lower containsString:@"debug_bounds"]) {
            node.hidden = YES;
            node.opacity = 0.0;
            [node removeFromParentNode];
            NSLog(@"[HIDE_GIZMO] removed node by name: %@", name);
        }
    }
}

- (void)vroidApplyCleanOverlayMode {
    [self vroidHideAxesGizmo];

    NSWindow *window = self.window;
    if (window && window.contentView) {
        [self vroidHideRotationPanelInView:window.contentView];
    }

    NSLog(@"[CLEAN_UI] rotation panel and gizmo hidden");
}

'''

# Insert helpers.
if "vroidApplyCleanOverlayMode" not in text:
    marker = "- (void)centerAndFitNode:(SCNNode *)node"
    if marker in text:
        text = text.replace(marker, helpers + "\n" + marker, 1)
    else:
        idx = text.rfind("@end")
        if idx == -1:
            raise SystemExit("No encontré lugar para insertar helpers.")
        text = text[:idx] + helpers + "\n" + text[idx:]

# Hide axes immediately after creation/addition when possible.
axis_hooks = [
    "[scene.rootNode addChildNode:_axesNode];",
    "[self.scene.rootNode addChildNode:_axesNode];",
    "[_rotationNode addChildNode:_axesNode];",
]

for hook in axis_hooks:
    if hook in text and "[self vroidHideAxesGizmo];" not in text[text.find(hook):text.find(hook)+300]:
        text = text.replace(
            hook,
            hook + "\n        [self vroidHideAxesGizmo];",
            1
        )
        break

# Hook clean UI after window/content creation.
# Try common AppKit show points.
hooks = [
    "[window makeKeyAndOrderFront:nil];",
    "[self.window makeKeyAndOrderFront:nil];",
    "[_window makeKeyAndOrderFront:nil];",
    "[window center];",
    "[_window center];",
]

inserted = False
if "[self vroidApplyCleanOverlayMode];" not in text:
    for hook in hooks:
        if hook in text:
            text = text.replace(
                hook,
                hook + "\n    [self vroidApplyCleanOverlayMode];",
                1
            )
            inserted = True
            break

# Fallback: call clean UI after model loading hooks if no window hook found.
if "[self vroidApplyCleanOverlayMode];" not in text:
    fallback_hooks = [
        "[self vroidApplyFixedLookRotation];",
        "[self vroidApplyFaceCameraFixForContainer:container];",
        "[self vroidApplyTexturedVisibleFixToContainer:container];",
        "[self vroidRuntimeRepairLoadedContainer:container];",
        "[self centerAndFitNode:container];",
    ]

    for hook in fallback_hooks:
        if hook in text:
            text = text.replace(
                hook,
                hook + "\n    [self vroidApplyCleanOverlayMode];",
                1
            )
            inserted = True
            break

if "[self vroidApplyCleanOverlayMode];" not in text:
    print("WARNING: no encontré un hook claro para ejecutar vroidApplyCleanOverlayMode automáticamente.")
    print("El método fue insertado, pero quizá haya que llamarlo manualmente en main.m.")

main.write_text(text)
print("main.m patched OK")
PY

echo ""
echo "== Verificando cambios =="
grep -n "vroidApplyCleanOverlayMode\|vroidHideAxesGizmo\|vroidHideRotationPanelInView\|VROID_SHOW_CONTROLS\|VROID_SHOW_GIZMO" "$MAIN" || true

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
echo "Prueba normal, panel y gizmo ocultos:"
echo "./build/VroidOverlay.app/Contents/MacOS/VroidOverlay"
echo ""
echo "Si quieres mostrar temporalmente el panel:"
echo "VROID_SHOW_CONTROLS=1 ./build/VroidOverlay.app/Contents/MacOS/VroidOverlay"
echo ""
echo "Si quieres mostrar temporalmente el gizmo:"
echo "VROID_SHOW_GIZMO=1 ./build/VroidOverlay.app/Contents/MacOS/VroidOverlay"
echo ""
echo "Si quieres mostrar ambos:"
echo "VROID_SHOW_CONTROLS=1 VROID_SHOW_GIZMO=1 ./build/VroidOverlay.app/Contents/MacOS/VroidOverlay"
echo ""
echo "Restaurar si algo falla:"
echo "cp '$BACKUP/main.m.backup' '$MAIN'"
