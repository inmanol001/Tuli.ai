#!/usr/bin/env bash
set -euo pipefail

APP_SUPPORT="$HOME/Library/Application Support/VroidOverlay"
RUNTIME="$APP_SUPPORT/local_agent_runtime"
BACKUP="/Users/inma/Documents/Vroid/backups_clean_memory_now_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$BACKUP"

echo "== Backup =="
cp "$APP_SUPPORT/conversation_memory.json" "$BACKUP/conversation_memory.json.backup" 2>/dev/null || true
cp "$RUNTIME/agent_state.json" "$BACKUP/agent_state.json.backup" 2>/dev/null || true

echo "== Clean app conversation memory =="
cat > "$APP_SUPPORT/conversation_memory.json" <<'JSON'
{
  "updated_at": 0,
  "short_term": [],
  "medium_term": [],
  "long_term": [
    {
      "summary": "The local desktop companion/avatar is named Tuli. Tuli should keep her identity stable."
    },
    {
      "summary": "Previous corrupted conversation memory was cleared because it contained incorrect factual answers."
    }
  ],
  "pinned_facts": [
    "The avatar's name is Tuli.",
    "Tuli is the user's local floating desktop companion.",
    "Tuli should be concise, warm, playful, and non-invasive.",
    "Tuli should not invent facts.",
    "Tuli should say she does not know when context is missing.",
    "Tuli should help the user track tasks, projects, and next actions."
  ]
}
JSON

echo "== Clean runtime state poison =="
python3 - <<'PY'
import json
from pathlib import Path

p = Path.home() / "Library/Application Support/VroidOverlay/local_agent_runtime/agent_state.json"

bad = [
    "20 de julio",
    "Independencia de México",
    "Luma",
    "José",
    "Jose",
    "Never call yourself Tuli"
]

data = {}
if p.exists():
    try:
        data = json.loads(p.read_text())
    except Exception:
        data = {}

data["pinned_facts"] = [
    "The avatar's name is Tuli.",
    "Tuli is a tiny floating desktop companion.",
    "Tuli should speak briefly, warmly, naturally, and with light playfulness.",
    "Tuli should not claim to be the user, a generic assistant, a model, or a system.",
    "Tuli should not invent facts when she does not know something.",
    "Tuli should help the user track tasks, projects, and next actions."
]

def poisoned(x):
    s = json.dumps(x, ensure_ascii=False).lower()
    return any(b.lower() in s for b in bad)

data["recent_lines"] = [
    x for x in data.get("recent_lines", [])
    if isinstance(x, str) and not poisoned(x)
][-30:]

data["recent_actions"] = [
    x for x in data.get("recent_actions", [])
    if not poisoned(x)
][-80:]

p.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
print("cleaned", p)
PY

echo "== Verify =="
grep -RIn "20 de julio\|Independencia de México\|Luma\|José\|Jose\|Never call yourself Tuli" \
  "$APP_SUPPORT/conversation_memory.json" \
  "$RUNTIME/agent_state.json" || echo "OK: no poison in core memory"

echo ""
echo "Backup: $BACKUP"
echo "DONE"
