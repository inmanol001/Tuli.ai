#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
APP_SUPPORT="$HOME/Library/Application Support/VroidOverlay"
RUNTIME="$APP_SUPPORT/local_agent_runtime"
APP="$PROJECT/build/VroidOverlay.app"
MAIN="$PROJECT/Sources/VroidOverlay/main.m"
OUT="$PROJECT/avatar_3d_disappeared_debug_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$OUT"

echo "== Investigando cabeza/avatar 3D desaparecida =="
echo "OUT=$OUT"

echo ""
echo "== 1. Git status/diff =="
{
  cd "$PROJECT"
  echo "---- git status ----"
  git status --short 2>/dev/null || true

  echo ""
  echo "---- git diff stat ----"
  git diff --stat 2>/dev/null || true

  echo ""
  echo "---- git diff main.m relevant ----"
  git diff -- "$MAIN" 2>/dev/null | grep -nE "SCNView|SCNScene|SCNNode|camera|scale|position|opacity|alpha|hidden|isHidden|geometry|material|lighting|light|usdc|usd|AI.usdc|model|avatar|head|lookAt|allowsTransparency|backgroundColor|clearColor|order|level|collectionBehavior|contentView|wantsLayer|SceneKit|fallback" -C 8 || true

  echo ""
  echo "---- full git diff main.m first 900 lines ----"
  git diff -- "$MAIN" 2>/dev/null | sed -n '1,900p' || true
} > "$OUT/git_diff_3d.txt" 2>&1

echo ""
echo "== 2. Buscar referencias SceneKit/modelo en main.m =="
{
  if [ -f "$MAIN" ]; then
    echo "---- main.m refs ----"
    grep -nE "SCNView|SCNScene|SCNNode|SCNCamera|SCNLight|SCNMaterial|SCNTransaction|SCNAction|camera|pointOfView|scale|position|opacity|alpha|hidden|isHidden|geometry|materials|diffuse|lighting|light|usdc|usd|AI.usdc|model|avatar|head|lookAt|allowsTransparency|backgroundColor|clearColor|makeKey|orderFront|level|collectionBehavior|contentView|wantsLayer|SceneKit|fallback|loadModel|loadAvatar|rootNode|childNodes|boundingBox|pivot" "$MAIN" || true

    echo ""
    echo "---- main.m 1-260 ----"
    nl -ba "$MAIN" | sed -n '1,260p'

    echo ""
    echo "---- main.m 260-620 ----"
    nl -ba "$MAIN" | sed -n '260,620p'

    echo ""
    echo "---- main.m 620-980 ----"
    nl -ba "$MAIN" | sed -n '620,980p'

    echo ""
    echo "---- main.m 980-1360 ----"
    nl -ba "$MAIN" | sed -n '980,1360p'
  else
    echo "MISSING $MAIN"
  fi
} > "$OUT/main_3d_refs.txt" 2>&1

echo ""
echo "== 3. Archivos de modelo 3D y recursos =="
{
  echo "---- project 3D files ----"
  find "$PROJECT" -maxdepth 6 -type f \
    \( -iname "*.usdc" -o -iname "*.usd" -o -iname "*.usdz" -o -iname "*.obj" -o -iname "*.dae" -o -iname "*.scn" -o -iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" \) \
    -not -path "$PROJECT/kokoro-fastapi/.venv/*" \
    -not -path "$PROJECT/.git/*" \
    -print | sort | while read -r f; do
      ls -lh "$f"
    done

  echo ""
  echo "---- app bundle resources ----"
  if [ -d "$APP" ]; then
    find "$APP" -maxdepth 6 -type f \
      \( -iname "*.usdc" -o -iname "*.usd" -o -iname "*.usdz" -o -iname "*.obj" -o -iname "*.dae" -o -iname "*.scn" -o -iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" \) \
      -print | sort | while read -r f; do
        ls -lh "$f"
      done
  else
    echo "MISSING APP: $APP"
  fi

  echo ""
  echo "---- specific AI.usdc locations ----"
  find "$PROJECT" "$APP_SUPPORT" -name "AI.usdc" -print 2>/dev/null | sort | while read -r f; do
    ls -lh "$f"
    file "$f" || true
    shasum -a 256 "$f" || true
  done
} > "$OUT/model_resource_files.txt" 2>&1

echo ""
echo "== 4. Inspección strings de AI.usdc =="
{
  for f in $(find "$PROJECT" "$APP_SUPPORT" -name "AI.usdc" -print 2>/dev/null | sort); do
    echo ""
    echo "======== $f ========"
    ls -lh "$f"
    echo "---- file ----"
    file "$f" || true
    echo "---- first strings ----"
    strings "$f" | head -80 || true
    echo "---- material/model refs ----"
    strings "$f" | grep -iE "material|shader|diffuse|opacity|transparent|texture|png|jpg|prim|mesh|xform|scale|translate|rotate|face|head|body|VRM|usd|metersPerUnit|upAxis" | head -160 || true
  done
} > "$OUT/usdc_strings.txt" 2>&1

echo ""
echo "== 5. Info.plist / bundle / build =="
{
  echo "---- app exists ----"
  ls -ld "$APP" 2>/dev/null || true

  echo ""
  echo "---- executable ----"
  ls -lh "$APP/Contents/MacOS/" 2>/dev/null || true

  echo ""
  echo "---- Info.plist ----"
  if [ -f "$APP/Contents/Info.plist" ]; then
    plutil -p "$APP/Contents/Info.plist" || true
  else
    echo "MISSING Info.plist"
  fi

  echo ""
  echo "---- app bundle tree shallow ----"
  find "$APP" -maxdepth 4 -print 2>/dev/null | sort | sed -n '1,220p'
} > "$OUT/app_bundle_info.txt" 2>&1

echo ""
echo "== 6. Logs recientes avatar/app =="
{
  echo "---- overlay_debug.log ----"
  tail -300 "$APP_SUPPORT/overlay_debug.log" 2>/dev/null || true

  echo ""
  echo "---- bridge_debug.log ----"
  tail -120 "$APP_SUPPORT/bridge_debug.log" 2>/dev/null || true

  echo ""
  echo "---- system unified log VroidOverlay recent ----"
  log show --last 20m --style compact --predicate 'process CONTAINS[c] "VroidOverlay"' 2>/dev/null | tail -260 || true
} > "$OUT/recent_avatar_logs.txt" 2>&1

echo ""
echo "== 7. Procesos / ventanas / permisos =="
{
  echo "---- processes ----"
  ps aux | grep -iE "VroidOverlay|SceneKit|afplay|say|uvicorn|kokoro|python" | grep -v grep || true

  echo ""
  echo "---- launchctl localagent ----"
  launchctl list | grep -iE "vroid|tuli|localagent" || true

  echo ""
  echo "---- windows via osascript ----"
  osascript <<'OSA' 2>/dev/null || true
tell application "System Events"
  repeat with p in (processes whose name contains "VroidOverlay")
    log "PROCESS: " & name of p
    try
      repeat with w in windows of p
        log "WINDOW: " & name of w & " pos=" & position of w & " size=" & size of w
      end repeat
    end try
  end repeat
end tell
OSA
} > "$OUT/process_windows.txt" 2>&1

echo ""
echo "== 8. Compilación seca / errores recientes =="
{
  cd "$PROJECT"

  echo "---- make/build scripts ----"
  find "$PROJECT" -maxdepth 3 -type f \
    \( -iname "Makefile" -o -iname "*.sh" -o -iname "*.xcodeproj" -o -iname "project.pbxproj" \) \
    -not -path "$PROJECT/kokoro-fastapi/.venv/*" \
    -print | sort

  echo ""
  echo "---- clang/xcode strings in scripts ----"
  grep -RInE "clang|xcodebuild|SceneKit|AI.usdc|Resources|Copy|build/VroidOverlay" \
    "$PROJECT" \
    --exclude-dir=.git \
    --exclude-dir=.venv \
    --exclude-dir=kokoro-fastapi \
    --exclude="*.zip" \
    2>/dev/null | head -260 || true
} > "$OUT/build_refs.txt" 2>&1

echo ""
echo "== 9. Veredicto automático =="
python3 - <<PY > "$OUT/verdict.txt"
from pathlib import Path
import re, json

project = Path("/Users/inma/Documents/Vroid")
app_support = Path.home() / "Library/Application Support/VroidOverlay"
app = project / "build/VroidOverlay.app"
main = project / "Sources/VroidOverlay/main.m"

main_text = main.read_text(errors="replace") if main.exists() else ""
overlay_log = (app_support / "overlay_debug.log").read_text(errors="replace") if (app_support / "overlay_debug.log").exists() else ""

models = []
for base in [project, app_support]:
    if base.exists():
        models.extend(base.rglob("AI.usdc"))

app_models = []
if app.exists():
    app_models = list(app.rglob("AI.usdc"))

print("Avatar 3D Disappeared Verdict")
print()

print("- main.m exists:", main.exists())
print("- app exists:", app.exists())
print("- AI.usdc files in project/appsupport:", len(models))
for p in models[:20]:
    try:
        print("  ", p, p.stat().st_size)
    except Exception:
        print("  ", p)

print("- AI.usdc files inside app bundle:", len(app_models))
for p in app_models[:20]:
    try:
        print("  ", p, p.stat().st_size)
    except Exception:
        print("  ", p)

print()
checks = {
    "has SCNView": "SCNView" in main_text,
    "has SCNScene": "SCNScene" in main_text,
    "has SCNNode": "SCNNode" in main_text,
    "has AI.usdc ref": "AI.usdc" in main_text,
    "has opacity/alpha refs": bool(re.search(r"opacity|alpha", main_text, re.I)),
    "has hidden/isHidden refs": bool(re.search(r"hidden|isHidden", main_text)),
    "has scale refs": "scale" in main_text,
    "has camera refs": bool(re.search(r"SCNCamera|pointOfView|camera", main_text)),
    "has clear background": bool(re.search(r"clearColor|allowsTransparency|backgroundColor", main_text)),
}
for k, v in checks.items():
    print(f"- {k}: {v}")

print()
bad_log_terms = ["failed", "error", "exception", "missing", "could not", "unable", "nil", "AI.usdc"]
hits = []
for line in overlay_log.splitlines()[-500:]:
    low = line.lower()
    if any(t in low for t in bad_log_terms):
        hits.append(line)
print("- suspicious overlay log lines:", len(hits))
for line in hits[-40:]:
    print("  ", line)

print()
print("Likely causes to inspect:")
if not app_models:
    print("1. AI.usdc may not be copied into VroidOverlay.app bundle.")
if "AI.usdc" not in main_text:
    print("2. main.m may no longer load AI.usdc explicitly.")
if re.search(r"isHidden\\s*=\\s*YES|hidden\\s*=\\s*YES|opacity\\s*=\\s*0|alphaValue\\s*=\\s*0", main_text):
    print("3. Codex may have hidden the SceneKit view/node or made it transparent.")
if "SCNCamera" not in main_text and "camera" not in main_text:
    print("4. Camera code may be missing or changed.")
print("5. Check git_diff_3d.txt and main_3d_refs.txt for exact Codex changes.")
PY

zip -qr "$OUT.zip" "$OUT"

echo ""
echo "== DONE =="
echo "Folder: $OUT"
echo "ZIP: $OUT.zip"
echo ""
echo "==== VERDICT ===="
cat "$OUT/verdict.txt"
echo ""
echo "$OUT.zip" | pbcopy
echo "Ruta del ZIP copiada al portapapeles."
