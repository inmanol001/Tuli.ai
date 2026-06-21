from __future__ import annotations

import json
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any, Dict, List, Optional

from ..config import TuliBrainConfig, load_config


DEFAULT_TIMEOUT_SECONDS = 30
DEFAULT_NUM_PREDICT = 300


class OllamaLocalError(RuntimeError):
    """Raised when the local Ollama provider cannot return usable text."""


@dataclass(frozen=True)
class OllamaChatResult:
    text: str
    model: str
    raw: Dict[str, Any]


def build_messages(user_text: str, system_prompt: Optional[str] = None) -> List[Dict[str, str]]:
    clean_text = user_text.strip()
    if not clean_text:
        raise OllamaLocalError("user_text must not be empty")

    system = system_prompt or (
        "You are Tuli, the user's local floating desktop companion. "
        "Reply in English by default, even if the user writes Spanish. "
        "Only switch to Spanish if the user explicitly asks for Spanish. "
        "Be concise, warm, lightly playful, and useful. "
        "Do not claim to be OpenAI, a system, or a generic model. "
        "Do not invent facts when context is missing."
    )
    return [
        {"role": "system", "content": system},
        {"role": "user", "content": clean_text},
    ]


def _post_json(url: str, payload: Dict[str, Any], timeout_seconds: int) -> Dict[str, Any]:
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
            text = response.read().decode("utf-8", errors="replace")
    except urllib.error.URLError as exc:
        raise OllamaLocalError(f"could not reach local Ollama at {url}: {exc}") from exc
    except TimeoutError as exc:
        raise OllamaLocalError(f"local Ollama timed out after {timeout_seconds}s") from exc

    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        raise OllamaLocalError("local Ollama returned invalid JSON") from exc
    if not isinstance(data, dict):
        raise OllamaLocalError("local Ollama returned a non-object JSON payload")
    return data


def _extract_text(data: Dict[str, Any]) -> str:
    message = data.get("message")
    if isinstance(message, dict):
        content = message.get("content")
        if isinstance(content, str) and content.strip():
            return content.strip()

    response = data.get("response")
    if isinstance(response, str) and response.strip():
        return response.strip()

    return ""


def chat(
    user_text: str,
    config: Optional[TuliBrainConfig] = None,
    *,
    system_prompt: Optional[str] = None,
    model: Optional[str] = None,
    timeout_seconds: int = DEFAULT_TIMEOUT_SECONDS,
    num_predict: int = DEFAULT_NUM_PREDICT,
) -> OllamaChatResult:
    cfg = config or load_config()
    payload = {
        "model": (model or cfg.ollama_model).strip() or cfg.ollama_model,
        "messages": build_messages(user_text, system_prompt=system_prompt),
        "stream": False,
        "think": False,
        "options": {
            "temperature": 0.7,
            "top_p": 0.9,
            "num_predict": num_predict,
        },
    }
    raw = _post_json(cfg.ollama_url, payload, timeout_seconds)
    text = _extract_text(raw)
    if not text:
        thinking = raw.get("thinking")
        thinking_len = len(thinking) if isinstance(thinking, str) else 0
        reason = raw.get("done_reason") or raw.get("done")
        raise OllamaLocalError(
            f"local Ollama returned empty text; done={reason!r}; thinking_chars={thinking_len}"
        )
    return OllamaChatResult(text=text, model=payload["model"], raw=raw)
