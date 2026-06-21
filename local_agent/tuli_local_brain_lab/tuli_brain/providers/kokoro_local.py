from __future__ import annotations

import json
import urllib.error
import urllib.request
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from ..config import TuliBrainConfig, load_config


DEFAULT_TIMEOUT_SECONDS = 45
DEFAULT_RESPONSE_FORMAT = "mp3"
DEFAULT_MODEL = "kokoro"


class KokoroLocalError(RuntimeError):
    """Raised when local Kokoro cannot synthesize usable audio."""


@dataclass(frozen=True)
class KokoroSpeechResult:
    text: str
    voice: str
    audio_path: str
    response_format: str
    bytes_written: int

    def to_dict(self) -> dict:
        return {
            "text": self.text,
            "voice": self.voice,
            "audio_path": self.audio_path,
            "response_format": self.response_format,
            "bytes_written": self.bytes_written,
        }


def _make_audio_path(output_dir: str | Path, response_format: str) -> Path:
    directory = Path(output_dir).expanduser()
    directory.mkdir(parents=True, exist_ok=True)
    suffix = response_format.strip().lower().lstrip(".") or DEFAULT_RESPONSE_FORMAT
    return directory / f"tuli_speech_{uuid.uuid4().hex[:12]}.{suffix}"


def synthesize_speech(
    text: str,
    config: Optional[TuliBrainConfig] = None,
    *,
    voice: Optional[str] = None,
    output_dir: Optional[str | Path] = None,
    response_format: str = DEFAULT_RESPONSE_FORMAT,
    timeout_seconds: int = DEFAULT_TIMEOUT_SECONDS,
) -> KokoroSpeechResult:
    clean_text = text.strip()
    if not clean_text:
        raise KokoroLocalError("speech text must not be empty")

    cfg = config or load_config()
    selected_voice = (voice or cfg.kokoro_voice).strip()
    if not selected_voice:
        raise KokoroLocalError("kokoro voice must not be empty")

    payload = {
        "model": DEFAULT_MODEL,
        "input": clean_text,
        "voice": selected_voice,
        "response_format": response_format,
    }
    request = urllib.request.Request(
        cfg.kokoro_url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json", "Accept": "audio/*"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
            audio = response.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")[:500]
        raise KokoroLocalError(f"local Kokoro HTTP {exc.code}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise KokoroLocalError(f"could not reach local Kokoro at {cfg.kokoro_url}: {exc}") from exc
    except TimeoutError as exc:
        raise KokoroLocalError(f"local Kokoro timed out after {timeout_seconds}s") from exc

    if not audio:
        raise KokoroLocalError("local Kokoro returned empty audio")

    audio_path = _make_audio_path(output_dir or cfg.speech_output_dir, response_format)
    audio_path.write_bytes(audio)

    return KokoroSpeechResult(
        text=clean_text,
        voice=selected_voice,
        audio_path=str(audio_path),
        response_format=response_format,
        bytes_written=len(audio),
    )
