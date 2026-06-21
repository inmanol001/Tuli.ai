#!/usr/bin/env bash
set -euo pipefail

REPO="/Users/inma/Documents/Vroid/kokoro-fastapi"
MODEL_DIR="$REPO/api/src/models/v1_0"
MODEL="$MODEL_DIR/kokoro-v1_0.pth"
CONFIG="$MODEL_DIR/config.json"
BACKUP="$REPO/corrupt_model_backup_$(date +%Y%m%d_%H%M%S)"

echo "== Repair corrupt Kokoro model =="
echo "Repo: $REPO"
echo "Model: $MODEL"
echo "Backup: $BACKUP"

cd "$REPO"
mkdir -p "$MODEL_DIR"
mkdir -p "$BACKUP"

echo ""
echo "== 1. Stop Kokoro server if running =="
pkill -f "uvicorn api.src.main:app" 2>/dev/null || true
pkill -f "api.src.main:app" 2>/dev/null || true
sleep 1

echo ""
echo "== 2. Current model file =="
ls -lh "$MODEL_DIR" || true

echo ""
echo "== 3. Backup corrupt model/config =="
if [ -f "$MODEL" ]; then
  cp "$MODEL" "$BACKUP/kokoro-v1_0.pth.corrupt"
  mv "$MODEL" "$MODEL.corrupt.$(date +%Y%m%d_%H%M%S)"
fi

if [ -f "$CONFIG" ]; then
  cp "$CONFIG" "$BACKUP/config.json.backup"
fi

echo ""
echo "== 4. Download fresh model/config =="
uv run --no-sync python docker/scripts/download_model.py --output api/src/models/v1_0

echo ""
echo "== 5. Verify downloaded files =="
ls -lh "$MODEL" "$CONFIG"

echo ""
echo "== 6. Deep verify with torch.load =="
uv run --no-sync python - <<'PY'
from pathlib import Path
import json
import torch

model = Path("api/src/models/v1_0/kokoro-v1_0.pth")
config = Path("api/src/models/v1_0/config.json")

print("model exists:", model.exists())
print("model size:", model.stat().st_size if model.exists() else None)
print("config exists:", config.exists())

with config.open() as f:
    json.load(f)
print("config JSON OK")

obj = torch.load(model, map_location="cpu", weights_only=True)
print("torch.load OK")
print("top-level type:", type(obj))
if hasattr(obj, "keys"):
    keys = list(obj.keys())
    print("top-level keys sample:", keys[:10])
PY

echo ""
echo "== 7. Start Kokoro server =="
export PATH="/opt/homebrew/bin:$HOME/.local/bin:$PATH"
export PYTORCH_ENABLE_MPS_FALLBACK=1
export USE_GPU=true
export USE_ONNX=false
export DEVICE_TYPE=mps
export PYTHONPATH="$REPO:$REPO/api"
export MODEL_DIR="src/models"
export VOICES_DIR="src/voices/v1_0"
export WEB_PLAYER_PATH="$REPO/web"

echo ""
echo "Starting on http://127.0.0.1:8880"
echo "Deja esta terminal abierta."
echo ""

uv run --no-sync python -m uvicorn api.src.main:app \
  --host 127.0.0.1 \
  --port 8880 \
  --log-level debug
