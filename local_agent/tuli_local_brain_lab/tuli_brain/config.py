from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Dict


APP_SUPPORT = Path.home() / "Library" / "Application Support" / "VroidOverlay"
WORKSPACE_SUPPORT = Path(__file__).resolve().parents[3] / ".tuli_app_support"


@dataclass(frozen=True)
class TuliBrainConfig:
    ollama_url: str = "http://127.0.0.1:11434/api/chat"
    ollama_model: str = "qwen3:1.7b"
    kokoro_url: str = "http://127.0.0.1:8880/v1/audio/speech"
    kokoro_voice: str = "af_bella"
    speech_output_dir: str = str(APP_SUPPORT / "speech_tmp")
    event_stream_path: str = str(APP_SUPPORT / "openclaw_stream.jsonl")
    request_stream_path: str = str(APP_SUPPORT / "tuli_requests.jsonl")
    response_stream_path: str = str(APP_SUPPORT / "tuli_responses.jsonl")
    memory_db_path: str = str(APP_SUPPORT / "tuli_brain.sqlite3")
    memory_jsonl_path: str = str(APP_SUPPORT / "tuli_memory.jsonl")

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)

    def to_json(self) -> str:
        return json.dumps(self.to_dict(), ensure_ascii=False, indent=2)


def _env_value(name: str, default: str) -> str:
    value = os.environ.get(name, "").strip()
    return value if value else default


def _resolve_app_support_dir() -> Path:
    override = os.environ.get("TULI_APP_SUPPORT_DIR", "").strip()
    if override:
        return Path(override).expanduser()

    if APP_SUPPORT.exists() and os.access(APP_SUPPORT, os.W_OK):
        return APP_SUPPORT

    if APP_SUPPORT.parent.exists() and os.access(APP_SUPPORT.parent, os.W_OK):
        return APP_SUPPORT

    return WORKSPACE_SUPPORT


def load_config() -> TuliBrainConfig:
    defaults = TuliBrainConfig()
    app_support = _resolve_app_support_dir()
    return TuliBrainConfig(
        ollama_url=_env_value("TULI_OLLAMA_URL", defaults.ollama_url),
        ollama_model=_env_value("TULI_OLLAMA_MODEL", defaults.ollama_model),
        kokoro_url=_env_value("TULI_KOKORO_URL", defaults.kokoro_url),
        kokoro_voice=_env_value("TULI_KOKORO_VOICE", defaults.kokoro_voice),
        speech_output_dir=_env_value("TULI_SPEECH_OUTPUT_DIR", str(app_support / "speech_tmp")),
        event_stream_path=_env_value("TULI_EVENT_STREAM_PATH", str(app_support / "openclaw_stream.jsonl")),
        request_stream_path=_env_value("TULI_REQUEST_STREAM_PATH", str(app_support / "tuli_requests.jsonl")),
        response_stream_path=_env_value("TULI_RESPONSE_STREAM_PATH", str(app_support / "tuli_responses.jsonl")),
        memory_db_path=_env_value("TULI_MEMORY_DB_PATH", str(app_support / "tuli_brain.sqlite3")),
        memory_jsonl_path=_env_value("TULI_MEMORY_JSONL_PATH", str(app_support / "tuli_memory.jsonl")),
    )


def main() -> int:
    print(load_config().to_json())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
