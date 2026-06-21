#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
REPO="$PROJECT/kokoro-fastapi"
LOG_DIR="$PROJECT/kokoro_logs"
LOG_FILE="$LOG_DIR/kokoro_start_$(date +%Y%m%d_%H%M%S).log"

mkdir -p "$LOG_DIR"

echo "== Repair and Start Kokoro-FastAPI =="
echo "Repo: $REPO"
echo "Log: $LOG_FILE"

if [ ! -d "$REPO" ]; then
  echo "ERROR: no existe $REPO"
  exit 1
fi

cd "$REPO"

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
echo "== 1. Deteniendo procesos viejos de Kokoro =="
pkill -f "uvicorn api.src.main:app" 2>/dev/null || true
pkill -f "start-gpu_mac.sh" 2>/dev/null || true
sleep 1

echo ""
echo "== 2. Verificando uv =="
if ! command -v uv >/dev/null 2>&1; then
  echo "ERROR: uv no está disponible."
  echo "Instala con: brew install uv"
  exit 1
fi

uv --version

echo ""
echo "== 3. Rehaciendo entorno virtual limpio =="
rm -rf .venv
uv venv .venv --python 3.10

echo ""
echo "== 4. Instalando Kokoro-FastAPI editable =="
# Usamos uv. No dependemos de pip dentro del venv.
uv pip install -e .

echo ""
echo "== 5. Verificando imports principales =="
uv run --no-sync python - <<'PY'
required = ["fastapi", "uvicorn", "pydantic", "numpy", "soundfile", "kokoro", "torch"]
optional = ["torchaudio"]

for name in required:
    try:
        mod = __import__(name)
        print(name, "OK", getattr(mod, "__version__", "no_version"))
    except Exception as e:
        print(name, "FAIL", repr(e))
        raise

for name in optional:
    try:
        mod = __import__(name)
        print(name, "OK optional", getattr(mod, "__version__", "no_version"))
    except Exception as e:
        print(name, "SKIP optional", repr(e))

import torch
print("mps available:", hasattr(torch.backends, "mps") and torch.backends.mps.is_available())
PY

echo ""
echo "== 6. Descargando modelo Kokoro si falta =="
if [ -s "api/src/models/v1_0/kokoro-v1_0.pth" ] && [ -s "api/src/models/v1_0/config.json" ]; then
  echo "Modelo Kokoro ya existe en api/src/models/v1_0. Saltando descarga."
else
  uv run --no-sync python docker/scripts/download_model.py --output api/src/models/v1_0
fi

echo ""
echo "== 7. Arrancando Kokoro en http://127.0.0.1:8880 =="
echo "Deja esta terminal abierta."
echo ""

uv run --no-sync uvicorn api.src.main:app \
  --host 127.0.0.1 \
  --port 8880 \
  2>&1 | tee "$LOG_FILE"
