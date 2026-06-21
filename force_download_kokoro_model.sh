#!/usr/bin/env bash
set -euo pipefail

REPO="/Users/inma/Documents/Vroid/kokoro-fastapi"
MODEL_DIR="$REPO/api/src/models/v1_0"
MODEL="$MODEL_DIR/kokoro-v1_0.pth"
CONFIG="$MODEL_DIR/config.json"
BACKUP="$REPO/model_download_backup_$(date +%Y%m%d_%H%M%S)"
ASSETS_JSON="$BACKUP/github_release_assets.json"

echo "== Force download Kokoro model =="
echo "Repo: $REPO"
echo "Model dir: $MODEL_DIR"
echo "Backup: $BACKUP"

mkdir -p "$MODEL_DIR"
mkdir -p "$BACKUP"

cd "$REPO"

echo ""
echo "== 1. Stop Kokoro server =="
pkill -f "uvicorn api.src.main:app" 2>/dev/null || true
pkill -f "api.src.main:app" 2>/dev/null || true
sleep 1

echo ""
echo "== 2. Backup current corrupt files =="
if [ -f "$MODEL" ]; then
  echo "Backing up existing model:"
  ls -lh "$MODEL"
  mv "$MODEL" "$BACKUP/kokoro-v1_0.pth.old"
fi

if [ -f "$CONFIG" ]; then
  echo "Backing up existing config:"
  ls -lh "$CONFIG"
  cp "$CONFIG" "$BACKUP/config.json.old"
fi

echo ""
echo "== 3. Check network to GitHub =="
curl -I --connect-timeout 15 --max-time 30 https://github.com/ | head -20

echo ""
echo "== 4. Fetch release asset list =="
curl -fL \
  --connect-timeout 20 \
  --max-time 120 \
  --retry 5 \
  --retry-delay 3 \
  "https://api.github.com/repos/remsky/Kokoro-FastAPI/releases/tags/v0.1.4" \
  -o "$ASSETS_JSON"

echo ""
echo "== 5. Extract asset URLs =="
python3 - <<PY
import json
from pathlib import Path

data = json.loads(Path("$ASSETS_JSON").read_text())
assets = data.get("assets", [])

print("Release:", data.get("tag_name"), data.get("name"))
print("Assets found:")
for a in assets:
    print("-", a.get("name"), a.get("size"), a.get("browser_download_url"))

model = None
config = None
for a in assets:
    name = a.get("name", "")
    url = a.get("browser_download_url", "")
    if name == "kokoro-v1_0.pth":
        model = url
    if name == "config.json":
        config = url

# Fallback to known direct URLs from the downloader script.
if not model:
    model = "https://github.com/remsky/Kokoro-FastAPI/releases/download/v0.1.4/kokoro-v1_0.pth"
if not config:
    config = "https://github.com/remsky/Kokoro-FastAPI/releases/download/v0.1.4/config.json"

Path("$BACKUP/model_url.txt").write_text(model + "\\n")
Path("$BACKUP/config_url.txt").write_text(config + "\\n")

print()
print("MODEL_URL=", model)
print("CONFIG_URL=", config)
PY

MODEL_URL="$(cat "$BACKUP/model_url.txt")"
CONFIG_URL="$(cat "$BACKUP/config_url.txt")"

echo ""
echo "== 6. Download config first =="
curl -fL \
  --connect-timeout 30 \
  --max-time 300 \
  --retry 8 \
  --retry-delay 5 \
  --progress-bar \
  "$CONFIG_URL" \
  -o "$CONFIG.part"

mv "$CONFIG.part" "$CONFIG"

echo ""
echo "== 7. Download model with progress =="
echo "URL: $MODEL_URL"
echo "Output: $MODEL"
echo ""
echo "Si se queda aquí, no es Python: es GitHub/CDN/red. Debe mostrar barra de progreso."

curl -fL \
  --connect-timeout 30 \
  --max-time 3600 \
  --retry 10 \
  --retry-delay 5 \
  --retry-all-errors \
  --progress-bar \
  "$MODEL_URL" \
  -o "$MODEL.part"

mv "$MODEL.part" "$MODEL"

echo ""
echo "== 8. File sizes =="
ls -lh "$MODEL" "$CONFIG"

echo ""
echo "== 9. Validate config JSON =="
python3 - <<PY
import json
from pathlib import Path
p = Path("$CONFIG")
json.loads(p.read_text())
print("CONFIG JSON OK")
PY

echo ""
echo "== 10. Validate model with torch.load =="
uv run --no-sync python - <<'PY'
from pathlib import Path
import torch

model = Path("api/src/models/v1_0/kokoro-v1_0.pth")
print("Model:", model)
print("Size:", model.stat().st_size)

obj = torch.load(model, map_location="cpu", weights_only=True)
print("TORCH LOAD OK")
print("Type:", type(obj))

if hasattr(obj, "keys"):
    keys = list(obj.keys())
    print("Keys sample:", keys[:12])
PY

echo ""
echo "== 11. Start Kokoro server =="
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
echo "Starting Kokoro on http://127.0.0.1:8880"
echo "Deja esta terminal abierta."
echo ""

uv run --no-sync python -m uvicorn api.src.main:app \
  --host 127.0.0.1 \
  --port 8880 \
  --log-level debug
