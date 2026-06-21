#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
OUT="$PROJECT/tuli_memory_debug_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$OUT"

echo "== Tuli Memory / Personality Investigation ==" | tee "$OUT/README.txt"
echo "Project: $PROJECT" | tee -a "$OUT/README.txt"
echo "Date: $(date)" | tee -a "$OUT/README.txt"
echo "" | tee -a "$OUT/README.txt"

echo "== 1. Project tree relevant ==" | tee "$OUT/project_tree.txt"
find "$PROJECT" \
  -path "$PROJECT/build" -prune -o \
  -path "$PROJECT/.build" -prune -o \
  -path "$PROJECT/kokoro-fastapi/.venv" -prune -o \
  -path "$PROJECT/backups_*" -prune -o \
  -path "$PROJECT/kokoro_manual_debug_*" -prune -o \
  -path "$PROJECT/openclaw_vroid_bridge_debug_*" -prune -o \
  -maxdepth 6 \
  \( -type f -o -type d \) \
  | sed "s#^$PROJECT/##" \
  | sort > "$OUT/project_tree.txt" 2>/dev/null || true

echo "== 2. Memory/state/config files ==" | tee "$OUT/memory_files_found.txt"
find "$PROJECT" "$HOME/Library/Application Support/VroidOverlay" "$HOME/.config" "$HOME/LocalAI" \
  -maxdepth 6 \
  -type f \
  \( \
    -iname "*memory*" -o \
    -iname "*state*" -o \
    -iname "*personality*" -o \
    -iname "*schedule*" -o \
    -iname "*routine*" -o \
    -iname "*mood*" -o \
    -iname "*prompt*" -o \
    -iname "*template*" -o \
    -iname "*agent*.json" -o \
    -iname "*.yaml" -o \
    -iname "*.yml" \
  \) \
  2>/dev/null \
  | sort > "$OUT/memory_files_found.txt" || true

echo "== 3. Copy readable memory/config files ==" | tee "$OUT/copied_files_manifest.txt"
COPY_DIR="$OUT/copied_memory_files"
mkdir -p "$COPY_DIR"

while IFS= read -r f; do
  [ -f "$f" ] || continue

  size="$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null || echo 0)"
  echo "$size bytes | $f" >> "$OUT/copied_files_manifest.txt"

  # Skip huge files
  if [ "$size" -gt 5000000 ]; then
    echo "SKIPPED huge file: $f" >> "$OUT/copied_files_manifest.txt"
    continue
  fi

  safe_name="$(echo "$f" | sed 's#/#__#g' | sed 's#^__##')"
  cp "$f" "$COPY_DIR/$safe_name" 2>/dev/null || true
done < "$OUT/memory_files_found.txt"

echo "== 4. Search code for memory/prompt/model logic ==" | tee "$OUT/code_memory_search.txt"
grep -RIn \
  --exclude-dir=.git \
  --exclude-dir=build \
  --exclude-dir=.build \
  --exclude-dir=.venv \
  --exclude-dir=kokoro-fastapi \
  --exclude-dir="backups_*" \
  --exclude-dir="tuli_memory_debug_*" \
  -E "memory|state|agent_state|personality|prompt|system_prompt|instructions|routine|schedule|mood|emotion|energy|curiosity|talkativeness|recent_lines|last_spoke|last_event|context|history|ollama|qwen|model_name|api/generate|temperature|top_p|num_predict|openclaw|bridge|stream|jsonl|bubble|gesture|speak|speech" \
  "$PROJECT" > "$OUT/code_memory_search.txt" 2>/dev/null || true

echo "== 5. Python files summary ==" | tee "$OUT/python_files_summary.txt"
find "$PROJECT" \
  -path "$PROJECT/build" -prune -o \
  -path "$PROJECT/.build" -prune -o \
  -path "$PROJECT/kokoro-fastapi/.venv" -prune -o \
  -path "$PROJECT/backups_*" -prune -o \
  -type f -name "*.py" \
  -print | sort > "$OUT/python_files_list.txt" 2>/dev/null || true

while IFS= read -r py; do
  echo "" >> "$OUT/python_files_summary.txt"
  echo "======== $py ========" >> "$OUT/python_files_summary.txt"
  wc -l "$py" >> "$OUT/python_files_summary.txt" 2>/dev/null || true
  grep -nE "def |class |if __name__|ollama|prompt|memory|state|personality|schedule|mood|bridge|json|openclaw|send_event" "$py" >> "$OUT/python_files_summary.txt" 2>/dev/null || true
done < "$OUT/python_files_list.txt"

echo "== 6. Local agent folder details ==" | tee "$OUT/local_agent_details.txt"
{
  LA="$PROJECT/local_agent"
  if [ -d "$LA" ]; then
    echo "LOCAL_AGENT_EXISTS=1"
    find "$LA" -maxdepth 4 -type f -print | sort
    echo ""
    echo "---- file previews ----"
    for f in "$LA"/* "$LA"/logs/*; do
      [ -f "$f" ] || continue
      echo ""
      echo "======== $f ========"
      size="$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null || echo 0)"
      echo "SIZE=$size"
      if [ "$size" -lt 200000 ]; then
        sed -n '1,260p' "$f" || true
      else
        echo "Large file, tail:"
        tail -120 "$f" || true
      fi
    done
  else
    echo "LOCAL_AGENT_EXISTS=0"
  fi
} >> "$OUT/local_agent_details.txt" 2>&1 || true

echo "== 7. App support stream/logs ==" | tee "$OUT/app_support.txt"
APP_SUPPORT="$HOME/Library/Application Support/VroidOverlay"
{
  echo "APP_SUPPORT=$APP_SUPPORT"
  if [ -d "$APP_SUPPORT" ]; then
    find "$APP_SUPPORT" -maxdepth 3 -type f -print | sort
    echo ""
    for f in "$APP_SUPPORT"/*; do
      [ -f "$f" ] || continue
      echo ""
      echo "======== $f ========"
      ls -lah "$f" || true
      if [[ "$f" == *.jsonl ]]; then
        echo "---- tail 80 jsonl ----"
        tail -80 "$f" || true
      elif [[ "$f" == *.json ]]; then
        python3 -m json.tool "$f" 2>/dev/null | head -220 || cat "$f" || true
      else
        tail -120 "$f" || true
      fi
    done
  else
    echo "NO_APP_SUPPORT_DIR"
  fi
} >> "$OUT/app_support.txt" 2>&1 || true

echo "== 8. Logs search ==" | tee "$OUT/logs_summary.txt"
find "$PROJECT" "$HOME/Library/Logs" /tmp \
  -maxdepth 5 \
  -type f \
  \( -iname "*tuli*.log" -o -iname "*vroid*.log" -o -iname "*agent*.log" -o -iname "*overlay*.log" -o -iname "*bridge*.log" \) \
  2>/dev/null \
  | sort > "$OUT/log_files_found.txt" || true

while IFS= read -r log; do
  [ -f "$log" ] || continue
  echo "" >> "$OUT/logs_summary.txt"
  echo "======== $log ========" >> "$OUT/logs_summary.txt"
  ls -lah "$log" >> "$OUT/logs_summary.txt" 2>&1 || true
  tail -160 "$log" >> "$OUT/logs_summary.txt" 2>&1 || true
done < "$OUT/log_files_found.txt"

echo "== 9. Process/daemon/launchd status ==" | tee "$OUT/process_launchd.txt"
{
  echo "---- processes ----"
  ps aux | grep -iE "tuli|vroid_agent|local_agent|ollama|qwen|VroidOverlay|openclaw_vroid_bridge|send_event|python" | grep -v grep || true

  echo ""
  echo "---- launch agents matching ----"
  launchctl list | grep -iE "tuli|vroid|localagent|agent" || true

  echo ""
  echo "---- LaunchAgents files ----"
  find "$HOME/Library/LaunchAgents" -maxdepth 1 -type f \
    \( -iname "*tuli*" -o -iname "*vroid*" -o -iname "*localagent*" -o -iname "*agent*" \) \
    -print 2>/dev/null || true

  echo ""
  for f in "$HOME/Library/LaunchAgents"/*tuli* "$HOME/Library/LaunchAgents"/*vroid* "$HOME/Library/LaunchAgents"/*localagent*; do
    [ -f "$f" ] || continue
    echo "======== $f ========"
    cat "$f"
  done
} >> "$OUT/process_launchd.txt" 2>&1 || true

echo "== 10. Ollama/local model status ==" | tee "$OUT/model_status.txt"
{
  echo "---- ollama command ----"
  which ollama || true
  ollama --version || true

  echo ""
  echo "---- ollama ps ----"
  ollama ps || true

  echo ""
  echo "---- ollama list ----"
  ollama list || true

  echo ""
  echo "---- ollama API probe ----"
  curl -sS --max-time 4 http://127.0.0.1:11434/api/tags || true
} >> "$OUT/model_status.txt" 2>&1 || true

echo "== 11. Prompt extraction ==" | tee "$OUT/prompt_extraction.txt"
{
  echo "Searching for long instruction/prompt blocks..."
  grep -RIn \
    --exclude-dir=.git \
    --exclude-dir=build \
    --exclude-dir=.build \
    --exclude-dir=.venv \
    --exclude-dir=kokoro-fastapi \
    --exclude-dir="backups_*" \
    --exclude-dir="tuli_memory_debug_*" \
    -E "You are|Eres|system|System|personality|rules|Do not|Never|Always|Return only|JSON|assistant|companion|Tuli|Luma|OpenClaw|Codex|prompt" \
    "$PROJECT" || true
} >> "$OUT/prompt_extraction.txt" 2>&1 || true

echo "== 12. State JSON validation ==" | tee "$OUT/json_validation.txt"
while IFS= read -r f; do
  [ -f "$f" ] || continue
  case "$f" in
    *.json)
      echo "" >> "$OUT/json_validation.txt"
      echo "======== $f ========" >> "$OUT/json_validation.txt"
      python3 -m json.tool "$f" >/tmp/tuli_json_check.out 2>/tmp/tuli_json_check.err \
        && echo "JSON_OK" >> "$OUT/json_validation.txt" \
        || { echo "JSON_FAIL" >> "$OUT/json_validation.txt"; cat /tmp/tuli_json_check.err >> "$OUT/json_validation.txt"; }
      ;;
    *.jsonl)
      echo "" >> "$OUT/json_validation.txt"
      echo "======== $f ========" >> "$OUT/json_validation.txt"
      python3 - "$f" <<'PY' >> "$OUT/json_validation.txt" 2>&1 || true
import json, sys
p=sys.argv[1]
ok=bad=0
for i,line in enumerate(open(p,encoding="utf-8",errors="replace"),1):
    line=line.strip()
    if not line: continue
    try:
        json.loads(line); ok+=1
    except Exception as e:
        bad+=1
        print("BAD_LINE", i, repr(e), line[:200])
print("JSONL_OK_LINES", ok)
print("JSONL_BAD_LINES", bad)
PY
      ;;
  esac
done < <(find "$PROJECT" "$APP_SUPPORT" -maxdepth 6 -type f \( -iname "*.json" -o -iname "*.jsonl" \) 2>/dev/null | sort)

echo "== 13. Memory health heuristic ==" | tee "$OUT/memory_health.txt"
python3 <<'PY' "$OUT" "$PROJECT" "$APP_SUPPORT" > "$OUT/memory_health.txt" 2>&1
import json, os, sys, re
from pathlib import Path

out = Path(sys.argv[1])
project = Path(sys.argv[2])
app_support = Path(sys.argv[3]).expanduser()

print("TULI MEMORY HEALTH HEURISTIC")
print()

candidate_files = []
for base in [project, app_support]:
    if base.exists():
        for p in base.rglob("*"):
            if p.is_file() and p.suffix.lower() in [".json", ".jsonl", ".yaml", ".yml", ".txt", ".log", ".py"]:
                if any(skip in str(p) for skip in ["kokoro-fastapi/.venv", "build/", ".build/", "backups_"]):
                    continue
                candidate_files.append(p)

print("candidate_files:", len(candidate_files))

signals = {
    "has_agent_state": False,
    "has_personality": False,
    "has_schedules": False,
    "has_recent_lines": False,
    "has_last_spoke": False,
    "mentions_luma": False,
    "mentions_tuli": False,
    "mentions_openclaw_in_local_agent": False,
    "json_errors": [],
    "large_prompts": [],
}

for p in candidate_files:
    name = p.name.lower()
    text = ""
    try:
        if p.stat().st_size < 1000000:
            text = p.read_text(encoding="utf-8", errors="replace")
    except Exception:
        pass

    if "agent_state" in name or "state" in name:
        signals["has_agent_state"] = True
    if "personality" in name:
        signals["has_personality"] = True
    if "schedule" in name or "routine" in name:
        signals["has_schedules"] = True
    if "recent_lines" in text:
        signals["has_recent_lines"] = True
    if "last_spoke" in text:
        signals["has_last_spoke"] = True
    if re.search(r"\bLuma\b", text):
        signals["mentions_luma"] = True
    if re.search(r"\bTuli\b", text):
        signals["mentions_tuli"] = True
    if "local_agent" in str(p) and re.search(r"OpenClaw|openclaw", text):
        signals["mentions_openclaw_in_local_agent"] = True

    if p.suffix.lower() == ".json":
        try:
            json.loads(text)
        except Exception as e:
            signals["json_errors"].append((str(p), repr(e)))

    if len(text) > 12000 and ("You are" in text or "rules" in text.lower() or "prompt" in text.lower()):
        signals["large_prompts"].append((str(p), len(text)))

for k,v in signals.items():
    print(k, "=", v)

print()
print("LIKELY ISSUES:")
if signals["mentions_luma"]:
    print("- Old name Luma still appears. This can confuse personality consistency. Replace with Tuli.")
if signals["mentions_openclaw_in_local_agent"]:
    print("- Local agent still mentions OpenClaw. If this phase should be local-only, isolate it.")
if not signals["has_agent_state"]:
    print("- No clear agent_state file found. Memory may not persist.")
if not signals["has_recent_lines"]:
    print("- No recent_lines tracking found. Model may repeat itself.")
if not signals["has_last_spoke"]:
    print("- No last_spoke tracking found. Timing/cooldown may be broken.")
if signals["json_errors"]:
    print("- Some JSON files are invalid.")
if signals["large_prompts"]:
    print("- Large prompt/instruction files detected; possible instruction bloat.")
PY

zip -qr "$OUT.zip" "$OUT"

echo ""
echo "INVESTIGACIÓN COMPLETA."
echo "Carpeta: $OUT"
echo "ZIP: $OUT.zip"
echo ""
echo "Copiando ruta del ZIP al portapapeles..."
echo "$OUT.zip" | pbcopy
echo "Ruta copiada:"
echo "$OUT.zip"
echo ""
echo "Ahora pega este resumen:"
echo "cat \"$OUT/memory_health.txt\""
