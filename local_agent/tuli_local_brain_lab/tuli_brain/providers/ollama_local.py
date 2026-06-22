from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any, Dict, List, Optional

from ..config import TuliBrainConfig, load_config
from ..debug.token_telemetry import build_token_telemetry
from ..events.token_events import emit_token_context_update


DEFAULT_TIMEOUT_SECONDS = 30
DEFAULT_NUM_PREDICT = 300


class OllamaLocalError(RuntimeError):
    """Raised when the local Ollama provider cannot return usable text."""


@dataclass(frozen=True)
class OllamaChatResult:
    text: str
    model: str
    raw: Dict[str, Any]


def _trace_enabled() -> bool:
    return os.environ.get("TULI_TRACE_LLM", "").strip() == "1" or os.environ.get("TULI_TRACE", "").strip() == "1"


def _trace_payload(model: str, payload: Dict[str, Any]) -> None:
    if not _trace_enabled():
        return
    messages = payload.get("messages") if isinstance(payload.get("messages"), list) else []
    total_chars = sum(len(str(message.get("content") or "")) for message in messages if isinstance(message, dict))
    approx_tokens = max(1, total_chars // 4) if total_chars else 0
    options = payload.get("options") if isinstance(payload.get("options"), dict) else {}
    print(f"[TULI LLM TRACE] model: {model}")
    print(f"[TULI LLM TRACE] num_ctx: {options.get('num_ctx')}")
    print(f"[TULI LLM TRACE] num_predict: {options.get('num_predict')}")
    print(f"[TULI LLM TRACE] keep_alive: {payload.get('keep_alive')}")
    print(f"[TULI LLM TRACE] message_count: {len(messages)}")
    print(f"[TULI LLM TRACE] total_chars: {total_chars}")
    print(f"[TULI LLM TRACE] approx_tokens: {approx_tokens}")


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


def chat_raw_messages(
    messages: List[Dict[str, str]],
    config: Optional[TuliBrainConfig] = None,
    *,
    model: Optional[str] = None,
    url: Optional[str] = None,
    timeout_seconds: int = DEFAULT_TIMEOUT_SECONDS,
    temperature: float = 0.0,
    top_p: float = 0.8,
    num_predict: Optional[int] = None,
    num_ctx: Optional[int] = None,
    keep_alive: Optional[str] = None,
    model_role: str = "router",
) -> OllamaChatResult:
    cfg = config or load_config()
    resolved_num_ctx = num_ctx or cfg.router_num_ctx
    resolved_num_predict = num_predict if num_predict is not None else cfg.router_num_predict
    resolved_keep_alive = keep_alive or cfg.ollama_keep_alive
    payload = {
        "model": (model or cfg.ollama_model).strip() or cfg.ollama_model,
        "messages": list(messages),
        "stream": False,
        "think": False,
        "options": {
            "temperature": temperature,
            "top_p": top_p,
            "num_ctx": resolved_num_ctx,
            "num_predict": resolved_num_predict,
        },
        "keep_alive": resolved_keep_alive,
    }
    _trace_payload(payload["model"], payload)
    before = build_token_telemetry(
        model_role=model_role,
        model=payload["model"],
        num_ctx=resolved_num_ctx,
        num_predict=resolved_num_predict,
        keep_alive=resolved_keep_alive,
        messages=payload["messages"],
        phase="before",
    )
    emit_token_context_update(cfg, before)
    try:
        raw = _post_json((url or cfg.ollama_url).strip() or cfg.ollama_url, payload, timeout_seconds)
    except Exception as exc:
        error_telemetry = build_token_telemetry(
            model_role=model_role,
            model=payload["model"],
            num_ctx=resolved_num_ctx,
            num_predict=resolved_num_predict,
            keep_alive=resolved_keep_alive,
            messages=payload["messages"],
            phase="error",
            error=str(exc),
        )
        emit_token_context_update(cfg, error_telemetry)
        raise
    text = _extract_text(raw)
    after = build_token_telemetry(
        model_role=model_role,
        model=payload["model"],
        num_ctx=resolved_num_ctx,
        num_predict=resolved_num_predict,
        keep_alive=resolved_keep_alive,
        messages=payload["messages"],
        phase="after",
        actual_prompt_tokens=raw.get("prompt_eval_count"),
        actual_output_tokens=raw.get("eval_count"),
        prompt_eval_duration=raw.get("prompt_eval_duration"),
        eval_duration=raw.get("eval_duration"),
        total_duration=raw.get("total_duration"),
    )
    emit_token_context_update(cfg, after)
    if not text:
        thinking = raw.get("thinking")
        thinking_len = len(thinking) if isinstance(thinking, str) else 0
        reason = raw.get("done_reason") or raw.get("done")
        raise OllamaLocalError(
            f"local Ollama returned empty text; done={reason!r}; thinking_chars={thinking_len}"
        )
    return OllamaChatResult(text=text, model=payload["model"], raw=raw)


def chat(
    user_text: str,
    config: Optional[TuliBrainConfig] = None,
    *,
    system_prompt: Optional[str] = None,
    model: Optional[str] = None,
    timeout_seconds: int = DEFAULT_TIMEOUT_SECONDS,
    num_predict: Optional[int] = None,
) -> OllamaChatResult:
    cfg = config or load_config()
    resolved_num_predict = num_predict if num_predict is not None else cfg.chat_num_predict
    payload = {
        "model": (model or cfg.ollama_model).strip() or cfg.ollama_model,
        "messages": build_messages(user_text, system_prompt=system_prompt),
        "stream": False,
        "think": False,
        "options": {
            "temperature": 0.7,
            "top_p": 0.9,
            "num_ctx": cfg.chat_num_ctx,
            "num_predict": resolved_num_predict,
        },
        "keep_alive": cfg.ollama_keep_alive,
    }
    _trace_payload(payload["model"], payload)
    before = build_token_telemetry(
        model_role="chat",
        model=payload["model"],
        num_ctx=cfg.chat_num_ctx,
        num_predict=resolved_num_predict,
        keep_alive=cfg.ollama_keep_alive,
        messages=payload["messages"],
        phase="before",
    )
    emit_token_context_update(cfg, before)
    try:
        raw = _post_json(cfg.ollama_url, payload, timeout_seconds)
    except Exception as exc:
        error_telemetry = build_token_telemetry(
            model_role="chat",
            model=payload["model"],
            num_ctx=cfg.chat_num_ctx,
            num_predict=resolved_num_predict,
            keep_alive=cfg.ollama_keep_alive,
            messages=payload["messages"],
            phase="error",
            error=str(exc),
        )
        emit_token_context_update(cfg, error_telemetry)
        raise
    text = _extract_text(raw)
    after = build_token_telemetry(
        model_role="chat",
        model=payload["model"],
        num_ctx=cfg.chat_num_ctx,
        num_predict=resolved_num_predict,
        keep_alive=cfg.ollama_keep_alive,
        messages=payload["messages"],
        phase="after",
        actual_prompt_tokens=raw.get("prompt_eval_count"),
        actual_output_tokens=raw.get("eval_count"),
        prompt_eval_duration=raw.get("prompt_eval_duration"),
        eval_duration=raw.get("eval_duration"),
        total_duration=raw.get("total_duration"),
    )
    emit_token_context_update(cfg, after)
    if not text:
        thinking = raw.get("thinking")
        thinking_len = len(thinking) if isinstance(thinking, str) else 0
        reason = raw.get("done_reason") or raw.get("done")
        raise OllamaLocalError(
            f"local Ollama returned empty text; done={reason!r}; thinking_chars={thinking_len}"
        )
    return OllamaChatResult(text=text, model=payload["model"], raw=raw)
