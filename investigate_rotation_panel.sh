#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
MAIN="$PROJECT/Sources/VroidOverlay/main.m"
OUT="$PROJECT/rotation_panel_investigation_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$OUT"

echo "== Rotation Panel Investigation ==" | tee "$OUT/README.txt"
echo "Project: $PROJECT" | tee -a "$OUT/README.txt"
echo "Main: $MAIN" | tee -a "$OUT/README.txt"
echo "Date: $(date)" | tee -a "$OUT/README.txt"

if [ ! -f "$MAIN" ]; then
  echo "ERROR: no existe $MAIN" | tee -a "$OUT/README.txt"
  exit 1
fi

echo ""
echo "== 1. Buscando código AppKit/UI relacionado ==" | tee "$OUT/ui_code_search.txt"

grep -RIn \
  --exclude-dir=.git \
  --exclude-dir=.build \
  --exclude-dir=build \
  --exclude-dir=backups_scenekit_fix_* \
  --exclude-dir=backups_camera_face_* \
  --exclude-dir=backups_fixed_rotation_* \
  --exclude-dir=backups_hide_ui_gizmo_* \
  -E "NSWindow|NSPanel|NSView|NSViewController|NSSlider|NSTextField|NSButton|NSStackView|NSGridView|NSBox|NSVisualEffectView|contentView|addSubview|subviews|makeKeyAndOrderFront|orderFront|rotation|Rotation|Rotación|X|Y|Z|slider|Slider|label|Label|panel|Panel|overlay|Overlay|control|Control" \
  "$PROJECT/Sources" "$PROJECT"/*.m "$PROJECT"/*.mm "$PROJECT"/*.swift "$PROJECT"/*.h 2>/dev/null \
  > "$OUT/ui_code_search.txt" || true

echo "== 2. Buscando creación de ventanas/paneles ==" | tee "$OUT/window_panel_search.txt"

grep -RIn \
  --exclude-dir=.git \
  --exclude-dir=.build \
  --exclude-dir=build \
  -E "alloc.*NSWindow|NSWindow.*alloc|initWithContentRect|styleMask|NSPanel|floatingPanel|utilityWindow|titled|closable|resizable|borderless|setLevel|level|setOpaque|backgroundColor|hasShadow|title|setTitle|contentView|setContentView" \
  "$PROJECT/Sources" "$PROJECT"/*.m "$PROJECT"/*.mm "$PROJECT"/*.swift "$PROJECT"/*.h 2>/dev/null \
  > "$OUT/window_panel_search.txt" || true

echo "== 3. Buscando controles de rotación específicos ==" | tee "$OUT/rotation_control_search.txt"

grep -RIn \
  --exclude-dir=.git \
  --exclude-dir=.build \
  --exclude-dir=build \
  -E "_rotationNode|eulerAngles|rotation|Rotation|rotate|Rotate|mouseDragged|mouseDown|scrollWheel|NSEvent|NSSlider|slider|xSlider|ySlider|zSlider|angle|degrees|radians|setDoubleValue|doubleValue|target|action" \
  "$PROJECT/Sources" "$PROJECT"/*.m "$PROJECT"/*.mm "$PROJECT"/*.swift "$PROJECT"/*.h 2>/dev/null \
  > "$OUT/rotation_control_search.txt" || true

echo "== 4. Extrayendo main.m completo con números de línea ==" | tee "$OUT/main_numbered.m"
nl -ba "$MAIN" > "$OUT/main_numbered.m"

echo "== 5. Creando script temporal para introspección runtime ==" | tee "$OUT/runtime_probe_patch.txt"

cat > "$OUT/runtime_probe_patch.txt" <<'TXT'
Este bloque se puede insertar temporalmente en main.m para imprimir la jerarquía de ventanas y vistas en runtime.

Métodos Objective-C sugeridos:

- (void)vroidProbeViewTree:(NSView *)view indent:(NSUInteger)indent {
    if (!view) return;

    NSMutableString *pad = [NSMutableString string];
    for (NSUInteger i = 0; i < indent; i++) [pad appendString:@"  "];

    NSString *text = @"";
    if ([view respondsToSelector:@selector(stringValue)]) {
        text = [(id)view stringValue] ?: @"";
    }

    NSLog(@"%@VIEW class=%@ hidden=%d alpha=%.3f frame=%@ text='%@' subviews=%lu",
          pad,
          NSStringFromClass(view.class),
          view.hidden,
          view.alphaValue,
          NSStringFromRect(view.frame),
          text,
          (unsigned long)view.subviews.count);

    for (NSView *child in view.subviews) {
        [self vroidProbeViewTree:child indent:indent + 1];
    }
}

- (void)vroidProbeWindowsAndViews {
    NSLog(@"[PANEL_PROBE] windows count=%lu", (unsigned long)NSApp.windows.count);

    NSInteger idx = 0;
    for (NSWindow *w in NSApp.windows) {
        NSLog(@"[PANEL_PROBE] WINDOW[%ld] class=%@ title='%@' visible=%d key=%d main=%d level=%ld frame=%@ contentView=%@",
              (long)idx,
              NSStringFromClass(w.class),
              w.title ?: @"",
              w.visible,
              w.keyWindow,
              w.mainWindow,
              (long)w.level,
              NSStringFromRect(w.frame),
              NSStringFromClass(w.contentView.class));

        [self vroidProbeViewTree:w.contentView indent:1];
        idx++;
    }
}

Llamar después de crear la ventana y después de cargar el modelo:

dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    [self vroidProbeWindowsAndViews];
});

TXT

echo "== 6. Generando patch automático reversible para introspección runtime ==" | tee "$OUT/apply_runtime_probe.sh"

cat > "$OUT/apply_runtime_probe.sh" <<'PATCH'
#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
MAIN="$PROJECT/Sources/VroidOverlay/main.m"
BACKUP="$PROJECT/backups_runtime_panel_probe_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$BACKUP"
cp "$MAIN" "$BACKUP/main.m.backup"

python3 <<'PY'
from pathlib import Path

main = Path("/Users/inma/Documents/Vroid/Sources/VroidOverlay/main.m")
text = main.read_text()

helpers = r'''

#pragma mark - VROID Runtime Panel Probe

- (void)vroidProbeViewTree:(NSView *)view indent:(NSUInteger)indent {
    if (!view) return;

    NSMutableString *pad = [NSMutableString string];
    for (NSUInteger i = 0; i < indent; i++) {
        [pad appendString:@"  "];
    }

    NSString *textValue = @"";
    if ([view respondsToSelector:@selector(stringValue)]) {
        @try {
            textValue = [(id)view stringValue] ?: @"";
        } @catch (__unused NSException *e) {
            textValue = @"<stringValue-error>";
        }
    }

    NSLog(@"%@VIEW class=%@ hidden=%d alpha=%.3f frame=%@ text='%@' subviews=%lu",
          pad,
          NSStringFromClass(view.class),
          view.hidden,
          view.alphaValue,
          NSStringFromRect(view.frame),
          textValue,
          (unsigned long)view.subviews.count);

    for (NSView *child in view.subviews) {
        [self vroidProbeViewTree:child indent:indent + 1];
    }
}

- (void)vroidProbeWindowsAndViews {
    NSLog(@"[PANEL_PROBE] windows count=%lu", (unsigned long)NSApp.windows.count);

    NSInteger idx = 0;
    for (NSWindow *w in NSApp.windows) {
        NSLog(@"[PANEL_PROBE] WINDOW[%ld] class=%@ title='%@' visible=%d key=%d main=%d level=%ld frame=%@ contentView=%@",
              (long)idx,
              NSStringFromClass(w.class),
              w.title ?: @"",
              w.visible,
              w.keyWindow,
              w.mainWindow,
              (long)w.level,
              NSStringFromRect(w.frame),
              NSStringFromClass(w.contentView.class));

        [self vroidProbeViewTree:w.contentView indent:1];
        idx++;
    }
}

- (void)vroidSchedulePanelProbe {
    NSLog(@"[PANEL_PROBE] scheduling runtime window/view probe");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self vroidProbeWindowsAndViews];
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self vroidProbeWindowsAndViews];
    });
}

'''

if "vroidProbeWindowsAndViews" not in text:
    marker = "- (void)centerAndFitNode:(SCNNode *)node"
    if marker in text:
        text = text.replace(marker, helpers + "\n" + marker, 1)
    else:
        idx = text.rfind("@end")
        if idx == -1:
            raise SystemExit("No encontré lugar para insertar runtime probe.")
        text = text[:idx] + helpers + "\n" + text[idx:]

# Hook into likely points.
if "[self vroidSchedulePanelProbe];" not in text:
    hooks = [
        "[window makeKeyAndOrderFront:nil];",
        "[self.window makeKeyAndOrderFront:nil];",
        "[_window makeKeyAndOrderFront:nil];",
        "[self vroidApplyCleanOverlayMode];",
        "[self vroidApplyFixedLookRotation];",
        "[self vroidApplyFaceCameraFixForContainer:container];",
    ]

    inserted = False
    for hook in hooks:
        if hook in text:
            text = text.replace(hook, hook + "\n    [self vroidSchedulePanelProbe];", 1)
            inserted = True
            break

    if not inserted:
        print("WARNING: no encontré hook; inserta manualmente [self vroidSchedulePanelProbe]; después de crear la ventana.")

main.write_text(text)
print("Runtime panel probe inserted.")
PY

cd "$PROJECT"

if [ -x "./build.sh" ]; then
  ./build.sh
else
  bash ./build.sh
fi

echo ""
echo "Probe aplicado."
echo "Ejecuta:"
echo "VROID_DEBUG=1 ./build/VroidOverlay.app/Contents/MacOS/VroidOverlay 2>&1 | tee panel_probe.log"
echo ""
echo "Backup:"
echo "$BACKUP/main.m.backup"
echo ""
echo "Restaurar:"
echo "cp '$BACKUP/main.m.backup' '$MAIN'"
PATCH

chmod +x "$OUT/apply_runtime_probe.sh"

echo "== 7. Resumen rápido ==" | tee "$OUT/quick_summary.txt"
{
  echo "Archivos generados:"
  echo "$OUT/ui_code_search.txt"
  echo "$OUT/window_panel_search.txt"
  echo "$OUT/rotation_control_search.txt"
  echo "$OUT/main_numbered.m"
  echo "$OUT/runtime_probe_patch.txt"
  echo "$OUT/apply_runtime_probe.sh"
  echo ""
  echo "Próximo paso recomendado:"
  echo "1. Revisar los txt."
  echo "2. Ejecutar:"
  echo "   bash '$OUT/apply_runtime_probe.sh'"
  echo "3. Luego correr app con:"
  echo "   cd '$PROJECT'"
  echo "   VROID_DEBUG=1 ./build/VroidOverlay.app/Contents/MacOS/VroidOverlay 2>&1 | tee panel_probe.log"
  echo "4. Subir/pasar panel_probe.log."
} >> "$OUT/quick_summary.txt"

zip -qr "$OUT.zip" "$OUT"

echo ""
echo "INVESTIGACIÓN LISTA."
echo "Carpeta: $OUT"
echo "ZIP: $OUT.zip"
echo ""
echo "Ahora ejecuta el probe runtime:"
echo "bash '$OUT/apply_runtime_probe.sh'"
echo ""
echo "Luego abre con logs:"
echo "cd '$PROJECT'"
echo "VROID_DEBUG=1 ./build/VroidOverlay.app/Contents/MacOS/VroidOverlay 2>&1 | tee panel_probe.log"
echo ""
echo "Después mándame:"
echo "1) $OUT/ui_code_search.txt"
echo "2) $OUT/window_panel_search.txt"
echo "3) $OUT/rotation_control_search.txt"
echo "4) panel_probe.log"
