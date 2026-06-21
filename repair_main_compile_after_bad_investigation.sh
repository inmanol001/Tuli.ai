#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
MAIN="$PROJECT/Sources/VroidOverlay/main.m"
BACKUP_NOW="$PROJECT/backups_repair_main_compile_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$BACKUP_NOW"
cp "$MAIN" "$BACKUP_NOW/main.m.broken_before_repair"

echo "== Repair main.m compile after bad investigation patch =="
echo "Backup current broken file: $BACKUP_NOW/main.m.broken_before_repair"

echo ""
echo "== 1. Restore from latest investigation backup if available =="
BACKUP_SOURCE="$(find "$PROJECT" -maxdepth 1 -type d -name 'backups_investigate_3d_visibility_*' -print | sort | tail -1 || true)"

if [ -n "$BACKUP_SOURCE" ] && [ -f "$BACKUP_SOURCE/main.m.backup" ]; then
  echo "Restoring from: $BACKUP_SOURCE/main.m.backup"
  cp "$BACKUP_SOURCE/main.m.backup" "$MAIN"
else
  echo "No investigation backup found. Cleaning current file manually."
fi

echo ""
echo "== 2. Remove any leftover investigation patch artifacts =="
python3 - <<'PY'
from pathlib import Path
import re

main = Path("/Users/inma/Documents/Vroid/Sources/VroidOverlay/main.m")
s = main.read_text()

# Remove declaration line if present.
s = s.replace("- (void)vroidInvestigationDump3DState:(NSString *)label;\n", "")

# Remove calls inserted after visual operations.
s = re.sub(
    r'\n\s*\[self vroidInvestigationDump3DState:@"[^"]*"\];',
    '',
    s
)

# Remove method implementation if present.
s = re.sub(
    r'\n- \(void\)vroidInvestigationDump3DState:\(NSString \*\)label \{.*?\n\}\n(?=\n- \(|\n@end|\n\+ \()',
    '\n',
    s,
    flags=re.S
)

main.write_text(s)
print("cleaned investigation artifacts")
PY

echo ""
echo "== 3. Add missing _cameraNode ivar if code uses it =="
python3 - <<'PY'
from pathlib import Path
import re

main = Path("/Users/inma/Documents/Vroid/Sources/VroidOverlay/main.m")
s = main.read_text()

uses_camera_node = "_cameraNode" in s
declares_camera_node = re.search(r'SCNNode\s*\*\s*_cameraNode\s*;', s) is not None

if uses_camera_node and not declares_camera_node:
    print("Adding ivar: SCNNode *_cameraNode;")

    # Preferred: insert inside @implementation OverlaySceneView { ... ivar block.
    pattern = r'(@implementation\s+OverlaySceneView\s*\{\n)'
    m = re.search(pattern, s)
    if not m:
        raise SystemExit("Could not find @implementation OverlaySceneView { ivar block")

    insert_pos = m.end()
    s = s[:insert_pos] + "    SCNNode *_cameraNode;\n" + s[insert_pos:]
else:
    print("No _cameraNode ivar patch needed")

main.write_text(s)
PY

echo ""
echo "== 4. Quick source sanity =="
grep -n "vroidInvestigationDump3DState" "$MAIN" || echo "OK: no investigation method/calls left"
grep -n "SCNNode \\*_cameraNode" "$MAIN" || true

echo ""
echo "== 5. Build =="
bash "$PROJECT/build.sh"

echo ""
echo "== Build OK =="
echo "Backup folder: $BACKUP_NOW"
