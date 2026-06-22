from __future__ import annotations

from dataclasses import asdict, dataclass
from typing import Any, Dict, List, Mapping, Optional


@dataclass(frozen=True)
class TokenContextTelemetry:
    model_role: str
    model: str
    num_ctx: int
    num_predict: int
    keep_alive: str
    message_count: int
    total_chars: int
    approx_prompt_tokens: int
    actual_prompt_tokens: Optional[int] = None
    actual_output_tokens: Optional[int] = None
    prompt_eval_duration: Optional[int] = None
    eval_duration: Optional[int] = None
    total_duration: Optional[int] = None
    context_percent_estimated: float = 0.0
    context_percent_actual: Optional[float] = None
    phase: str = "before"
    error: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


def estimate_tokens_from_text(text: str) -> int:
    clean = str(text or "")
    chars_estimate = len(clean) // 4
    word_count = len(clean.split())
    return max(1, chars_estimate, word_count)


def estimate_messages_tokens(messages: List[Mapping[str, Any]]) -> int:
    total = 0
    for message in messages:
        content = str(message.get("content") or "")
        total += estimate_tokens_from_text(content)
    return total


def build_token_telemetry(
    *,
    model_role: str,
    model: str,
    num_ctx: int,
    num_predict: int,
    keep_alive: str,
    messages: List[Mapping[str, Any]],
    phase: str,
    actual_prompt_tokens: Optional[int] = None,
    actual_output_tokens: Optional[int] = None,
    prompt_eval_duration: Optional[int] = None,
    eval_duration: Optional[int] = None,
    total_duration: Optional[int] = None,
    error: Optional[str] = None,
) -> TokenContextTelemetry:
    total_chars = sum(len(str(message.get("content") or "")) for message in messages)
    approx_prompt_tokens = estimate_messages_tokens(messages)
    context_percent_estimated = round((approx_prompt_tokens / max(1, num_ctx)) * 100.0, 1)
    context_percent_actual = None
    if actual_prompt_tokens is not None:
        context_percent_actual = round((actual_prompt_tokens / max(1, num_ctx)) * 100.0, 1)
    return TokenContextTelemetry(
        model_role=model_role,
        model=model,
        num_ctx=num_ctx,
        num_predict=num_predict,
        keep_alive=keep_alive,
        message_count=len(messages),
        total_chars=total_chars,
        approx_prompt_tokens=approx_prompt_tokens,
        actual_prompt_tokens=actual_prompt_tokens,
        actual_output_tokens=actual_output_tokens,
        prompt_eval_duration=prompt_eval_duration,
        eval_duration=eval_duration,
        total_duration=total_duration,
        context_percent_estimated=context_percent_estimated,
        context_percent_actual=context_percent_actual,
        phase=phase,
        error=error,
    )


def telemetry_to_event(telemetry: TokenContextTelemetry) -> Dict[str, Any]:
    payload = telemetry.to_dict()
    payload["type"] = "token_context_update"
    return payload
