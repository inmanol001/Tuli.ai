#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
REPO="$PROJECT/kokoro-fastapi"
OUT="$PROJECT/kokoro_manual_debug_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$OUT"

echo "== Kokoro Manual Investigation ==" | tee "$OUT/README.txt"
echo "Project: $PROJECT" | tee -a "$OUT/README.txt"
echo "Repo: $REPO" | tee -a "$OUT/README.txt"
echo "Date: $(date)" | tee -a "$OUT/README.txt"
echo "" | tee -a "$OUT/README.txt"

echo "== 1. System ==" | tee "$OUT/system.txt"
{
  uname -a
  sw_vers || true
  echo "SHELL=$SHELL"
  echo "PATH=$PATH"
  date
  arch
} >> "$OUT/system.txt" 2>&1 || true

echo "== 2. Commands ==" | tee "$OUT/commands.txt"
{
  echo "---- python ----"
  which python || true
  which python3 || true
  python3 --version || true

  echo ""
  echo "---- uv ----"
  which uv || true
  uv --version || true

  echo ""
  echo "---- git ----"
  which git || true
  git --version || true

  echo ""
  echo "---- curl ----"
  which curl || true
  curl --version | head -5 || true
} >> "$OUT/commands.txt" 2>&1 || true

echo "== 3. Repo existence/tree ==" | tee "$OUT/repo_tree.txt"
{
  if [ -d "$REPO" ]; then
    echo "REPO_EXISTS=1"
    ls -lah "$REPO"
    echo ""
    echo "---- maxdepth 2 ----"
    find "$REPO" -maxdepth 2 -type f -o -type d | sort
  else
    echo "REPO_EXISTS=0"
  fi
} >> "$OUT/repo_tree.txt" 2>&1 || true

echo "== 4. Git status ==" | tee "$OUT/git_status.txt"
{
  if [ -d "$REPO/.git" ]; then
    cd "$REPO"
    git remote -v || true
    git status --short || true
    git branch --show-current || true
    git rev-parse HEAD || true
  else
    echo "NO_GIT_REPO"
  fi
} >> "$OUT/git_status.txt" 2>&1 || true

echo "== 5. Venv inspection ==" | tee "$OUT/venv.txt"
{
  if [ -d "$REPO/.venv" ]; then
    echo "VENV_EXISTS=1"
    ls -lah "$REPO/.venv"
    echo ""
    echo "---- python ----"
    "$REPO/.venv/bin/python" --version || true
    "$REPO/.venv/bin/python" -c "import sys; print(sys.executable); print(sys.version)" || true

    echo ""
    echo "---- pip ----"
    "$REPO/.venv/bin/python" -m pip --version || true

    echo ""
    echo "---- first 200 packages ----"
    "$REPO/.venv/bin/python" -m pip list | head -200 || true
  else
    echo "VENV_EXISTS=0"
  fi
} >> "$OUT/venv.txt" 2>&1 || true

echo "== 6. Python import tests ==" | tee "$OUT/import_tests.txt"
{
  if [ -x "$REPO/.venv/bin/python" ]; then
    PY="$REPO/.venv/bin/python"

    echo "---- torch ----"
    "$PY" - <<'PYTEST' || true
try:
    import torch
    print("torch OK", torch.__version__)
    print("mps available:", hasattr(torch.backends, "mps") and torch.backends.mps.is_available())
    print("cuda available:", torch.cuda.is_available() if hasattr(torch, "cuda") else False)
except Exception as e:
    print("torch FAIL:", repr(e))
PYTEST

    echo ""
    echo "---- torchaudio ----"
    "$PY" - <<'PYTEST' || true
try:
    import torchaudio
    print("torchaudio OK", torchaudio.__version__)
except Exception as e:
    print("torchaudio FAIL:", repr(e))
PYTEST

    echo ""
    echo "---- fastapi/uvicorn ----"
    "$PY" - <<'PYTEST' || true
for name in ["fastapi", "uvicorn", "pydantic", "numpy", "soundfile", "kokoro"]:
    try:
        mod = __import__(name)
        print(name, "OK", getattr(mod, "__version__", "no_version"))
    except Exception as e:
        print(name, "FAIL", repr(e))
PYTEST

  else
    echo "NO_VENV_PYTHON"
  fi
} >> "$OUT/import_tests.txt" 2>&1 || true

echo "== 7. Project metadata ==" | tee "$OUT/project_metadata.txt"
{
  if [ -d "$REPO" ]; then
    cd "$REPO"

    for f in pyproject.toml requirements.txt requirements*.txt uv.lock README.md start-gpu_mac.sh start-cpu.sh docker-compose.yml; do
      echo ""
      echo "======== $f ========"
      if [ -f "$f" ]; then
        sed -n '1,220p' "$f"
      else
        echo "MISSING"
      fi
    done
  fi
} >> "$OUT/project_metadata.txt" 2>&1 || true

echo "== 8. Start scripts details ==" | tee "$OUT/start_scripts.txt"
{
  if [ -d "$REPO" ]; then
    cd "$REPO"

    echo "---- scripts ----"
    ls -lah start* *.sh 2>/dev/null || true

    for f in start-gpu_mac.sh start-cpu.sh start.sh; do
      echo ""
      echo "======== $f ========"
      if [ -f "$f" ]; then
        nl -ba "$f" | sed -n '1,240p'
      else
        echo "MISSING"
      fi
    done
  fi
} >> "$OUT/start_scripts.txt" 2>&1 || true

echo "== 9. Search likely app/server entrypoints ==" | tee "$OUT/entrypoints_search.txt"
{
  if [ -d "$REPO" ]; then
    cd "$REPO"

    grep -RIn \
      --exclude-dir=.git \
      --exclude-dir=.venv \
      --exclude-dir=__pycache__ \
      -E "FastAPI\\(|uvicorn|app =|def main|if __name__|@app\\.|APIRouter|/v1/audio/speech|openai|audio/speech|generate|kokoro" \
      . > "$OUT/entrypoints_search.txt" 2>/dev/null || true
  fi
} >> "$OUT/entrypoints_search.extra.txt" 2>&1 || true

echo "== 10. Ports/processes ==" | tee "$OUT/processes_ports.txt"
{
  echo "---- Kokoro/python processes ----"
  ps aux | grep -iE "kokoro|uvicorn|fastapi|python|start-gpu|start-cpu" | grep -v grep || true

  echo ""
  echo "---- likely ports ----"
  for port in 8000 8880 5000 3000 7860; do
    echo "---- port $port ----"
    lsof -nP -iTCP:$port -sTCP:LISTEN || true
  done
} >> "$OUT/processes_ports.txt" 2>&1 || true

echo "== 11. Network quick check ==" | tee "$OUT/network.txt"
{
  echo "---- pypi simple ----"
  curl -I --max-time 8 https://pypi.org/simple/ || true

  echo ""
  echo "---- github ----"
  curl -I --max-time 8 https://github.com/remsky/Kokoro-FastAPI || true

  echo ""
  echo "---- huggingface ----"
  curl -I --max-time 8 https://huggingface.co || true
} >> "$OUT/network.txt" 2>&1 || true

echo "== 12. Local server probe ==" | tee "$OUT/server_probe.txt"
{
  for port in 8880 8000 5000 7860; do
    echo ""
    echo "==== Probe port $port ===="
    curl -sS --max-time 2 "http://127.0.0.1:$port/" || true
    echo ""
    curl -sS --max-time 2 "http://127.0.0.1:$port/docs" | head -40 || true
    echo ""
    curl -sS --max-time 2 "http://127.0.0.1:$port/v1/audio/speech" || true
    echo ""
  done
} >> "$OUT/server_probe.txt" 2>&1 || true

echo "== 13. Attempt dry commands only ==" | tee "$OUT/dry_commands.txt"
{
  if [ -x "$REPO/.venv/bin/python" ]; then
    cd "$REPO"
    PY="$REPO/.venv/bin/python"

    echo "---- python -m pip check ----"
    "$PY" -m pip check || true

    echo ""
    echo "---- python files at root ----"
    find . -maxdepth 3 -type f -name "*.py" | sort | head -120

    echo ""
    echo "---- possible modules ----"
    find . -maxdepth 4 -type f \( -name "main.py" -o -name "api.py" -o -name "app.py" -o -name "server.py" \) | sort
  fi
} >> "$OUT/dry_commands.txt" 2>&1 || true

echo "== 14. Manual next-step candidates ==" | tee "$OUT/next_step_candidates.txt"
{
  echo "Possible repair paths, do not run yet:"
  echo ""
  echo "A) Finish editable install:"
  echo "cd '$REPO'"
  echo ". .venv/bin/activate"
  echo "uv pip install -e . --reinstall"
  echo ""
  echo "B) Try CPU start:"
  echo "cd '$REPO'"
  echo ". .venv/bin/activate"
  echo "./start-cpu.sh"
  echo ""
  echo "C) Try Mac MPS start:"
  echo "cd '$REPO'"
  echo ". .venv/bin/activate"
  echo "./start-gpu_mac.sh"
  echo ""
  echo "D) If uv got stuck, use pip directly:"
  echo "cd '$REPO'"
  echo ". .venv/bin/activate"
  echo "python -m pip install -U pip setuptools wheel"
  echo "python -m pip install -e ."
} >> "$OUT/next_step_candidates.txt"

zip -qr "$OUT.zip" "$OUT"

echo ""
echo "INVESTIGACIÓN COMPLETA."
echo "Carpeta: $OUT"
echo "ZIP: $OUT.zip"
echo ""
echo "Archivos clave para revisar:"
echo "1) $OUT/venv.txt"
echo "2) $OUT/import_tests.txt"
echo "3) $OUT/project_metadata.txt"
echo "4) $OUT/start_scripts.txt"
echo "5) $OUT/entrypoints_search.txt"
echo "6) $OUT/processes_ports.txt"
echo "7) $OUT/server_probe.txt"
echo "8) $OUT/dry_commands.txt"
echo ""
echo "Copiando ruta del ZIP al portapapeles..."
echo "$OUT.zip" | pbcopy
echo "Ruta copiada: $OUT.zip"
