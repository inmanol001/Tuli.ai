#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
OUT="$PROJECT/vroid_build_method_debug_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$OUT"

echo "== Investigando método real de build =="
echo "OUT=$OUT"

{
  echo "---- root files ----"
  ls -la "$PROJECT"

  echo ""
  echo "---- build dir ----"
  find "$PROJECT/build" -maxdepth 5 -print 2>/dev/null | sort | sed -n '1,240p'

  echo ""
  echo "---- possible build files ----"
  find "$PROJECT" -maxdepth 5 \
    \( -iname "build.sh" \
    -o -iname "rebuild*.sh" \
    -o -iname "compile*.sh" \
    -o -iname "run*.sh" \
    -o -iname "Makefile" \
    -o -iname "*.xcodeproj" \
    -o -iname "project.pbxproj" \
    -o -iname "*.xcworkspace" \
    -o -iname "Package.swift" \
    -o -iname "*.m" \
    -o -iname "*.mm" \
    -o -iname "*.swift" \) \
    -not -path "$PROJECT/kokoro-fastapi/.venv/*" \
    -not -path "$PROJECT/.git/*" \
    -print | sort

  echo ""
  echo "---- clang/xcodebuild references ----"
  grep -RInE "clang|xcrun|xcodebuild|VroidOverlay.app|SceneKit|Foundation|AppKit|main.m|AI.usdc|Contents/MacOS|Contents/Resources" \
    "$PROJECT" \
    --exclude-dir=.git \
    --exclude-dir=.venv \
    --exclude-dir=kokoro-fastapi \
    --exclude="*.zip" \
    --exclude="*.usdc" \
    2>/dev/null | head -500 || true

  echo ""
  echo "---- app executable info ----"
  APP="$PROJECT/build/VroidOverlay.app"
  ls -lh "$APP/Contents/MacOS/" 2>/dev/null || true
  file "$APP/Contents/MacOS/VroidOverlay" 2>/dev/null || true
  otool -L "$APP/Contents/MacOS/VroidOverlay" 2>/dev/null || true

  echo ""
  echo "---- app bundle resources ----"
  find "$APP/Contents" -maxdepth 4 -type f -print 2>/dev/null | sort | sed -n '1,260p'

  echo ""
  echo "---- recent backups from failed patch ----"
  find "$PROJECT" -maxdepth 1 -type d -name "backups_investigate_3d_visibility_*" -print | sort
} > "$OUT/report.txt" 2>&1

{
  echo "Build Method Verdict"
  echo ""
  if [ -f "$PROJECT/build.sh" ]; then
    echo "- build.sh exists"
  else
    echo "- build.sh missing"
  fi

  if [ -f "$PROJECT/Makefile" ]; then
    echo "- Makefile exists"
  else
    echo "- Makefile missing"
  fi

  if find "$PROJECT" -maxdepth 4 -name "*.xcodeproj" | grep -q .; then
    echo "- xcodeproj exists"
  else
    echo "- xcodeproj missing"
  fi

  if [ -f "$PROJECT/build/VroidOverlay.app/Contents/MacOS/VroidOverlay" ]; then
    echo "- built app executable exists"
  else
    echo "- built app executable missing"
  fi

  echo ""
  echo "Important:"
  echo "$OUT/report.txt"
} > "$OUT/verdict.txt"

zip -qr "$OUT.zip" "$OUT"

echo ""
echo "== DONE =="
echo "Folder: $OUT"
echo "ZIP: $OUT.zip"
echo ""
cat "$OUT/verdict.txt"
echo "$OUT.zip" | pbcopy
