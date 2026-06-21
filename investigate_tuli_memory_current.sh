#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
APP_SUPPORT="$HOME/Library/Application Support/VroidOverlay"
RUNTIME="$APP_SUPPORT/local_agent_runtime"
MAIN="$PROJECT/Sources/VroidOverlay/main.m"
OUT="$PROJECT/tuli_memory_current_debug_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$OUT"

echo "== Investigando memoria actual de Tuli =="
echo "OUT: $OUT"

{
  echo "---- App Support memory files ----"
  find "$APP_SUPPORT" -maxdepth 4 -type f \
    \( -iname "*memory*" -o -iname "*state*" -o -iname "*task*" -o -iname "*todo*" -o -iname "*.json" -o -iname "*.jsonl" \) \
    -print 2>/dev/null | sort

  echo ""
  echo "---- Project memory/task files ----"
  find "$PROJECT" -maxdepth 5 -type f \
    \( -iname "*memory*" -o -iname "*state*" -o -iname "*task*" -o -iname "*todo*" -o -iname "*.json" -o -iname "*.jsonl" \) \
    -not -path "$PROJECT/kokoro-fastapi/.venv/*" \
    -not -path "$PROJECT/build/*" \
    -not -path "$PROJECT/.git/*" \
    -print 2>/dev/null | sort
} > "$OUT/memory_files_found.txt" 2>&1

{
  FILE="$APP_SUPPORT/conversation_memory.json"
  echo "FILE=$FILE"
  if [ -f "$FILE" ]; then
    python3 - <<PY
import json
from pathlib import Path
p = Path("$FILE")
print("exists:", p.exists())
print("size:", p.stat().st_size)
try:
    data = json.loads(p.read_text())
    print("json: OK")
    print("top keys:", list(data.keys()))
    for k in ["short_term", "medium_term", "long_term", "pinned_facts"]:
        v = data.get(k)
        print(f"{k}: type={type(v).__name__} count={len(v) if isinstance(v, list) else 'n/a'}")
    print()
    print(json.dumps(data, ensure_ascii=False, indent=2))
except Exception as e:
    print("json: FAIL", repr(e))
    print(p.read_text(errors="replace")[:5000])
PY
  else
    echo "MISSING"
  fi
} > "$OUT/app_conversation_memory.txt" 2>&1

{
  FILE="$RUNTIME/agent_state.json"
  echo "FILE=$FILE"
  if [ -f "$FILE" ]; then
    python3 - <<PY
import json
from pathlib import Path
p = Path("$FILE")
print("exists:", p.exists())
print("size:", p.stat().st_size)
try:
    data = json.loads(p.read_text())
    print("json: OK")
    print("top keys:", list(data.keys()))
    print("recent_lines:", len(data.get("recent_lines", []) or []))
    print("recent_actions:", len(data.get("recent_actions", []) or []))
    print("pinned_facts:", len(data.get("pinned_facts", []) or []))
    print()
    print(json.dumps(data, ensure_ascii=False, indent=2))
except Exception as e:
    print("json: FAIL", repr(e))
    print(p.read_text(errors="replace")[:5000])
PY
  else
    echo "MISSING"
  fi
} > "$OUT/runtime_agent_state.txt" 2>&1

{
  FILE="$RUNTIME/personality.yaml"
  echo "FILE=$FILE"
  if [ -f "$FILE" ]; then
    cat "$FILE"
  else
    echo "MISSING"
  fi
} > "$OUT/runtime_personality.txt" 2>&1

{
  echo "---- main.m memory refs ----"
  if [ -f "$MAIN" ]; then
    grep -nE "conversation_memory|short_term|medium_term|long_term|pinned|memory|remember|recuerd|vroidLoadConversation|vroidSaveConversation|vroidAppendConversation|vroidChatMessagesForUserPrompt|system|prompt|Tuli|Luma|José|Jose|todo|task|tasks" "$MAIN" || true

    echo ""
    echo "---- main.m likely memory area 2600-3300 ----"
    nl -ba "$MAIN" | sed -n '2600,3300p'
  else
    echo "MISSING $MAIN"
  fi
} > "$OUT/main_memory_prompt_refs.txt" 2>&1

{
  DAEMON="$RUNTIME/vroid_agent_daemon.py"
  echo "DAEMON=$DAEMON"
  if [ -f "$DAEMON" ]; then
    grep -nE "memory|state|agent_state|personality|pinned|recent_lines|recent_actions|prompt|system|context|summary|load|save|remember|todo|task|tasks|jsonl|conversation|Tuli|Luma|José|Jose" "$DAEMON" || true

    echo ""
    echo "---- daemon 1-260 ----"
    nl -ba "$DAEMON" | sed -n '1,260p'

    echo ""
    echo "---- daemon 260-520 ----"
    nl -ba "$DAEMON" | sed -n '260,520p'

    echo ""
    echo "---- daemon 520-760 ----"
    nl -ba "$DAEMON" | sed -n '520,760p'
  else
    echo "MISSING"
  fi
} > "$OUT/daemon_memory_prompt_refs.txt" 2>&1

{
  echo "---- local_agent python files ----"
  find "$PROJECT/local_agent" -maxdepth 2 -type f -name "*.py" -print 2>/dev/null | sort | while read -r f; do
    echo ""
    echo "======== $f ========"
    grep -nE "memory|task|todo|state|json|jsonl|add_task|list_tasks|complete|blocked|doing|done|pinned|summary" "$f" || true
  done

  echo ""
  echo "---- runtime python files ----"
  find "$RUNTIME" -maxdepth 2 -type f -name "*.py" -print 2>/dev/null | sort | while read -r f; do
    echo ""
    echo "======== $f ========"
    grep -nE "memory|task|todo|state|json|jsonl|add_task|list_tasks|complete|blocked|doing|done|pinned|summary" "$f" || true
  done
} > "$OUT/python_memory_task_refs.txt" 2>&1

{
  for f in \
    "$APP_SUPPORT/tuli_tasks.json" \
    "$APP_SUPPORT/todo_tasks.json" \
    "$APP_SUPPORT/tasks.json" \
    "$RUNTIME/tuli_tasks.json" \
    "$PROJECT/local_agent/tuli_tasks.json" \
    "$PROJECT/tuli_tasks.json"
  do
    echo ""
    echo "======== $f ========"
    if [ -f "$f" ]; then
      python3 - <<PY
import json
from pathlib import Path
p=Path("$f")
print("size:", p.stat().st_size)
try:
    data=json.loads(p.read_text())
    print("json: OK")
    print(json.dumps(data, ensure_ascii=False, indent=2))
except Exception as e:
    print("json: FAIL", repr(e))
    print(p.read_text(errors="replace")[:5000])
PY
    else
      echo "MISSING"
    fi
  done
} > "$OUT/tasks_files.txt" 2>&1

{
  echo "---- agent.log ----"
  tail -180 "$RUNTIME/logs/agent.log" 2>/dev/null || true

  echo ""
  echo "---- overlay_debug.log ----"
  tail -220 "$APP_SUPPORT/overlay_debug.log" 2>/dev/null || true

  echo ""
  echo "---- bridge_debug.log ----"
  tail -180 "$APP_SUPPORT/bridge_debug.log" 2>/dev/null || true

  echo ""
  echo "---- openclaw_stream.jsonl ----"
  tail -120 "$APP_SUPPORT/openclaw_stream.jsonl" 2>/dev/null || true
} > "$OUT/recent_logs_streams.txt" 2>&1

python3 - <<PY > "$OUT/verdict.txt"
import json
from pathlib import Path

project = Path("/Users/inma/Documents/Vroid")
app = Path.home() / "Library/Application Support/VroidOverlay"
runtime = app / "local_agent_runtime"
main = project / "Sources/VroidOverlay/main.m"

def load_json(p):
    try:
        return json.loads(p.read_text())
    except Exception:
        return None

conv = load_json(app / "conversation_memory.json")
state = load_json(runtime / "agent_state.json")

task_candidates = [
    app / "tuli_tasks.json",
    app / "todo_tasks.json",
    app / "tasks.json",
    runtime / "tuli_tasks.json",
    project / "local_agent/tuli_tasks.json",
    project / "tuli_tasks.json",
]
existing_tasks = [p for p in task_candidates if p.exists()]

main_text = main.read_text(errors="replace") if main.exists() else ""
daemon_file = runtime / "vroid_agent_daemon.py"
daemon_text = daemon_file.read_text(errors="replace") if daemon_file.exists() else ""

print("Tuli Memory Current Verdict")
print()

if conv is None:
    print("- App conversation_memory.json: missing or invalid.")
else:
    print("- App conversation_memory.json: OK")
    for k in ["short_term", "medium_term", "long_term", "pinned_facts"]:
        v = conv.get(k)
        print(f"  {k}: {len(v) if isinstance(v, list) else 'not-list'}")

if state is None:
    print("- Runtime agent_state.json: missing or invalid.")
else:
    print("- Runtime agent_state.json: OK")
    print("  recent_lines:", len(state.get("recent_lines", []) or []))
    print("  recent_actions:", len(state.get("recent_actions", []) or []))
    print("  pinned_facts:", len(state.get("pinned_facts", []) or []))
    print("  current_mood:", state.get("current_mood"))
    print("  last_spoke_at:", state.get("last_spoke_at"))

print()
print("- Task files found:", len(existing_tasks))
for p in existing_tasks:
    print("  ", p)

print()
print("- main.m uses conversation memory:", "conversation_memory" in main_text)
print("- main.m has vroidChatMessagesForUserPrompt:", "vroidChatMessagesForUserPrompt" in main_text)
print("- daemon uses agent_state:", "agent_state" in daemon_text or "AGENT_STATE" in daemon_text)
print("- daemon uses pinned_facts:", "pinned_facts" in daemon_text)
print("- daemon uses task/todo code:", any(x in daemon_text.lower() for x in ["tuli_tasks", "todo", "tasks_store", "load_task_summary"]))

print()
bad_terms = ["Luma", "José", "Jose", "20 de julio", "Independencia de México", "Never call yourself Tuli"]
bad_found = []
for name, text in [
    ("conversation_memory", json.dumps(conv, ensure_ascii=False) if conv else ""),
    ("agent_state", json.dumps(state, ensure_ascii=False) if state else ""),
    ("main.m", main_text),
    ("daemon", daemon_text),
]:
    for term in bad_terms:
        if term.lower() in text.lower():
            bad_found.append((name, term))

if bad_found:
    print("- Poison terms found:")
    for name, term in bad_found:
        print(f"  {name}: {term}")
else:
    print("- No known poison terms found in core memory/code scan.")

print()
print("Folder:", Path("$OUT"))
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
