#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
MAIN="$PROJECT/Sources/VroidOverlay/main.m"
OUT="$PROJECT/rescue_main_compile_$(date +%Y%m%d_%H%M%S)"
CANDIDATES="$OUT/candidates"
LOGS="$OUT/logs"

mkdir -p "$CANDIDATES" "$LOGS"

echo "== Rescue last compilable main.m =="
echo "OUT=$OUT"

cp "$MAIN" "$OUT/main.m.current_broken"

echo ""
echo "== 1. Collect backup candidates =="

n=0

add_candidate() {
  local src="$1"
  local label="$2"
  if [ -f "$src" ]; then
    n=$((n+1))
    local dst="$CANDIDATES/$(printf '%03d' "$n")_${label}.m"
    cp "$src" "$dst"
    echo "$dst <= $src"
  fi
}

# Most useful backups first: newest first.
while IFS= read -r f; do
  safe="$(echo "$f" | sed 's#/#_#g' | sed 's#[^A-Za-z0-9_.-]#_#g')"
  add_candidate "$f" "$safe"
done < <(
  find "$PROJECT" -maxdepth 3 -type f \
    \( -name "main.m.backup" -o -name "main.m.before*" -o -name "main.m.current*" -o -name "main.m.broken*" \) \
    -print | sort -r
)

# Git HEAD candidate if available.
if git -C "$PROJECT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if git -C "$PROJECT" show HEAD:Sources/VroidOverlay/main.m > "$CANDIDATES/000_git_HEAD_main.m" 2>/dev/null; then
    echo "$CANDIDATES/000_git_HEAD_main.m <= git HEAD"
  fi
fi

echo ""
echo "Candidates:"
ls -lh "$CANDIDATES" || true

echo ""
echo "== 2. Test compile each candidate =="

SUCCESS=""

# Try newest backup first, but keep git HEAD as fallback.
for candidate in $(find "$CANDIDATES" -type f -name "*.m" | sort -r); do
  base="$(basename "$candidate")"
  log="$LOGS/$base.build.log"

  echo ""
  echo "---- Testing $base ----"

  cp "$candidate" "$MAIN"

  if bash "$PROJECT/build.sh" > "$log" 2>&1; then
    echo "BUILD OK: $base"
    SUCCESS="$candidate"
    break
  else
    echo "BUILD FAIL: $base"
    tail -30 "$log" || true
  fi
done

echo ""
echo "== 3. Result =="

if [ -z "$SUCCESS" ]; then
  echo "ERROR: ningún candidato compiló."
  echo "Restaurando main.m roto original para no perderlo."
  cp "$OUT/main.m.current_broken" "$MAIN"
  echo ""
  echo "Logs en: $LOGS"
  echo "Pega:"
  echo "  ls -lh \"$CANDIDATES\""
  echo "  tail -80 \"$LOGS\"/*.log"
  exit 1
fi

cp "$SUCCESS" "$MAIN"

echo "Restored compilable main:"
echo "$SUCCESS"
echo "$SUCCESS" > "$OUT/success_candidate.txt"

echo ""
echo "== 4. Final build =="
bash "$PROJECT/build.sh" | tee "$OUT/final_build.log"

echo ""
echo "== 5. Sanity: suspicious broken fragments =="
grep -nE "vroidInvestigationDump3DState|vroidEmergencyForce|notifyRotationChanged|vroidPreviewSnapshotNode|Runtime Repair Helpers|previewScene|_cameraNode" "$MAIN" \
  > "$OUT/suspicious_refs.txt" || true

cat "$OUT/suspicious_refs.txt"

echo ""
echo "== DONE =="
echo "Current main.m is now the last compilable candidate."
echo "Output: $OUT"
