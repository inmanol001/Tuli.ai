#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
LAB="$PROJECT/local_agent/tuli_local_brain_lab"
APP_SUPPORT="$HOME/Library/Application Support/VroidOverlay"
RUNTIME="$APP_SUPPORT/local_agent_runtime"
STAMP="$(date +%Y%m%d_%H%M%S)"
QUARANTINE="$LAB/memory_quarantine_$STAMP"

mkdir -p "$QUARANTINE/app_support" "$QUARANTINE/project_local_agent" "$QUARANTINE/runtime"

copy_if_exists() {
  local src="$1"
  local dst_dir="$2"
  if [ -e "$src" ]; then
    cp -p "$src" "$dst_dir/"
  fi
}

copy_if_exists "$APP_SUPPORT/conversation_memory.json" "$QUARANTINE/app_support"
copy_if_exists "$APP_SUPPORT/local_events.jsonl" "$QUARANTINE/app_support"
copy_if_exists "$APP_SUPPORT/openclaw_stream.jsonl" "$QUARANTINE/app_support"
copy_if_exists "$APP_SUPPORT/speech_trace.jsonl" "$QUARANTINE/app_support"
copy_if_exists "$APP_SUPPORT/tuli_tasks.json" "$QUARANTINE/app_support"

copy_if_exists "$PROJECT/local_agent/agent_state.json" "$QUARANTINE/project_local_agent"
copy_if_exists "$PROJECT/local_agent/personality.yaml" "$QUARANTINE/project_local_agent"
copy_if_exists "$PROJECT/local_agent/logs/openclaw_stream.jsonl" "$QUARANTINE/project_local_agent"

copy_if_exists "$RUNTIME/agent_state.json" "$QUARANTINE/runtime"
copy_if_exists "$RUNTIME/personality.yaml" "$QUARANTINE/runtime"
copy_if_exists "$RUNTIME/logs/openclaw_stream.jsonl" "$QUARANTINE/runtime"

cat > "$APP_SUPPORT/conversation_memory.json" <<'JSON'
{
  "version": 2,
  "status": "clean_seed_after_quarantine",
  "updated_at": 0,
  "short_term": [],
  "medium_term": [],
  "long_term": [],
  "pinned_facts": [
    "The avatar's name is Tuli.",
    "Tuli is the user's local floating desktop companion.",
    "Tuli should be concise, warm, playful, and non-invasive.",
    "Tuli should not invent facts.",
    "Tuli should say she does not know when context is missing.",
    "Tuli should use local-first memory only."
  ],
  "blocked_previous_memory": true,
  "quarantine_reason": "Previous memory may contain incorrect or contaminated context. It was archived before building the new local brain."
}
JSON

cat > "$PROJECT/local_agent/agent_state.json" <<'JSON'
{
  "started_at": null,
  "last_tick_at": null,
  "last_spoke_at": null,
  "last_gesture_at": null,
  "last_event_at": {},
  "last_greeting_date": null,
  "energy": 0.65,
  "curiosity": 0.55,
  "talkativeness": 0.25,
  "sleepiness": 0.2,
  "current_mood": "neutral",
  "focus_mode": false,
  "daily_event_counts": {},
  "recent_lines": [],
  "recent_actions": [],
  "memory_mode": "conversational",
  "projectmem_brief_cache": {},
  "pinned_facts": [
    "The avatar's name is Tuli.",
    "Tuli is a tiny floating desktop companion.",
    "Tuli should speak briefly, warmly, naturally, and with light playfulness.",
    "Tuli should not claim to be the user, a generic assistant, a model, or a system.",
    "Tuli should not invent facts when she does not know something.",
    "Previous memory was quarantined and must not be used as active context."
  ],
  "blocked_previous_memory": true,
  "quarantine_id": ""
}
JSON

if [ -d "$RUNTIME" ]; then
  cp -p "$PROJECT/local_agent/agent_state.json" "$RUNTIME/agent_state.json"
fi

: > "$APP_SUPPORT/openclaw_stream.jsonl"
: > "$APP_SUPPORT/local_events.jsonl"
if [ -d "$RUNTIME/logs" ]; then
  : > "$RUNTIME/logs/openclaw_stream.jsonl"
fi
if [ -d "$PROJECT/local_agent/logs" ]; then
  : > "$PROJECT/local_agent/logs/openclaw_stream.jsonl"
fi

python3 - "$PROJECT/local_agent/agent_state.json" "$RUNTIME/agent_state.json" "$QUARANTINE" <<'PY'
import json
import sys
from pathlib import Path

project_state = Path(sys.argv[1])
runtime_state = Path(sys.argv[2])
quarantine = Path(sys.argv[3])

for path in [project_state, runtime_state]:
    if path.exists():
        data = json.loads(path.read_text(encoding="utf-8"))
        data["quarantine_id"] = quarantine.name
        path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
PY

cat > "$QUARANTINE/MANIFEST.md" <<EOF
# Tuli Memory Quarantine

Created: $STAMP

This folder contains the previous active Tuli memory/runtime files before the clean local-brain rebuild.

## Quarantined Sources

- $APP_SUPPORT/conversation_memory.json
- $APP_SUPPORT/local_events.jsonl
- $APP_SUPPORT/openclaw_stream.jsonl
- $APP_SUPPORT/speech_trace.jsonl
- $APP_SUPPORT/tuli_tasks.json
- $PROJECT/local_agent/agent_state.json
- $PROJECT/local_agent/personality.yaml
- $PROJECT/local_agent/logs/openclaw_stream.jsonl
- $RUNTIME/agent_state.json
- $RUNTIME/personality.yaml
- $RUNTIME/logs/openclaw_stream.jsonl

## Active Replacement

- Active conversation memory was replaced with a clean seed.
- Active project/runtime agent state was reset to clean recent_lines and recent_actions.
- Active JSONL event streams were truncated so old events cannot replay as new context.

## Rule

Do not import this quarantined memory into the new Tuli local brain automatically. Review manually and migrate only trusted facts.
EOF

cat > "$LAB/MEMORY_QUARANTINE_ACTIVE.md" <<EOF
# Active Memory Quarantine

Current quarantine: \`$QUARANTINE\`

Previous Tuli memory has been hidden from active use. New brain work should start from clean local memory and only manually migrate trusted facts.

Blocked active sources:

- old conversation memory
- old recent lines/actions
- old local event stream
- old speech trace
- old runtime event stream

Allowed seed facts:

- Tuli is the avatar name.
- Tuli is the user's local floating desktop companion.
- Tuli should be concise, warm, playful, and non-invasive.
- Tuli should not invent facts.
- Tuli should use local-first memory only.
EOF

echo "$QUARANTINE"
