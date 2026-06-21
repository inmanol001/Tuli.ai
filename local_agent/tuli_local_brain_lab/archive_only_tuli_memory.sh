#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
LAB="$PROJECT/local_agent/tuli_local_brain_lab"
APP_SUPPORT="$HOME/Library/Application Support/VroidOverlay"
RUNTIME="$APP_SUPPORT/local_agent_runtime"
STAMP="$(date +%Y%m%d_%H%M%S)"
ARCHIVE="$LAB/memory_archive_only_$STAMP"

mkdir -p "$ARCHIVE/app_support" "$ARCHIVE/project_local_agent" "$ARCHIVE/runtime"

move_if_exists() {
  local src="$1"
  local dst_dir="$2"
  if [ -e "$src" ]; then
    mv "$src" "$dst_dir/"
  fi
}

# Active memory/context files from Application Support.
move_if_exists "$APP_SUPPORT/conversation_memory.json" "$ARCHIVE/app_support"
move_if_exists "$APP_SUPPORT/local_events.jsonl" "$ARCHIVE/app_support"
move_if_exists "$APP_SUPPORT/openclaw_stream.jsonl" "$ARCHIVE/app_support"
move_if_exists "$APP_SUPPORT/speech_trace.jsonl" "$ARCHIVE/app_support"

# Keep tasks available for now; they are user data, not conversation memory.
# Archive a copy for audit without removing it from active use.
if [ -e "$APP_SUPPORT/tuli_tasks.json" ]; then
  cp -p "$APP_SUPPORT/tuli_tasks.json" "$ARCHIVE/app_support/"
fi

# Active local agent state can contain contaminated recent lines/actions.
move_if_exists "$PROJECT/local_agent/agent_state.json" "$ARCHIVE/project_local_agent"
move_if_exists "$PROJECT/local_agent/logs/openclaw_stream.jsonl" "$ARCHIVE/project_local_agent"

# Runtime copy used by the installed LaunchAgent.
move_if_exists "$RUNTIME/agent_state.json" "$ARCHIVE/runtime"
move_if_exists "$RUNTIME/logs/openclaw_stream.jsonl" "$ARCHIVE/runtime"

cat > "$ARCHIVE/MANIFEST.md" <<EOF
# Tuli Memory Archive Only

Created: $STAMP

This archive contains the previous active Tuli memory/context files. No replacement memory was created.

## Moved Out Of Active Use

- $APP_SUPPORT/conversation_memory.json
- $APP_SUPPORT/local_events.jsonl
- $APP_SUPPORT/openclaw_stream.jsonl
- $APP_SUPPORT/speech_trace.jsonl
- $PROJECT/local_agent/agent_state.json
- $PROJECT/local_agent/logs/openclaw_stream.jsonl
- $RUNTIME/agent_state.json
- $RUNTIME/logs/openclaw_stream.jsonl

## Copied For Audit Only

- $APP_SUPPORT/tuli_tasks.json

## Rule

Do not import these files automatically into the new Tuli brain. If anything is migrated later, review it manually and copy only trusted facts.
EOF

cat > "$LAB/MEMORY_ARCHIVE_ONLY_ACTIVE.md" <<EOF
# Active Memory Archive

Current archive: \`$ARCHIVE\`

The contaminated memory/context files were moved out of active use.

No new memory seed was created.
No replacement \`conversation_memory.json\` was created.
No replacement \`agent_state.json\` was created.

Tasks were copied for audit but left active.
EOF

echo "$ARCHIVE"
