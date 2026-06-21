#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_SUPPORT="${HOME}/Library/Application Support/VroidOverlay"
RUNTIME_DIR="${APP_SUPPORT}/local_agent_runtime"

mkdir -p "${RUNTIME_DIR}"
mkdir -p "${RUNTIME_DIR}/logs"

rsync -a \
  --delete \
  --exclude 'logs/' \
  --exclude 'agent_state.json' \
  --exclude '__pycache__/' \
  --exclude '.DS_Store' \
  "${SCRIPT_DIR}/" "${RUNTIME_DIR}/"

install -m 755 "${PROJECT_DIR}/openclaw_vroid_bridge.py" "${APP_SUPPORT}/openclaw_vroid_bridge.py"
install -m 755 "${PROJECT_DIR}/openclaw_vroid_bridge.py" "${RUNTIME_DIR}/openclaw_vroid_bridge.py"

touch "${RUNTIME_DIR}/logs/.gitkeep"

printf 'Synced runtime to %s\n' "${RUNTIME_DIR}"
