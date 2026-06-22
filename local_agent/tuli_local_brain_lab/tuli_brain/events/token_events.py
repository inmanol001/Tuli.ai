from __future__ import annotations

import os
from pathlib import Path

from ..config import TuliBrainConfig
from ..debug.token_telemetry import TokenContextTelemetry, telemetry_to_event
from .jsonl_writer import append_jsonl_event


def _trace_enabled() -> bool:
    return os.environ.get("TULI_TRACE_TOKENS", "").strip() == "1" or os.environ.get("TULI_TRACE", "").strip() == "1"


def _print_trace(telemetry: TokenContextTelemetry) -> None:
    if not _trace_enabled():
        return
    if telemetry.phase == "before":
        print(
            f"[TULI TOKEN TRACE] role={telemetry.model_role} phase=before "
            f"model={telemetry.model} approx={telemetry.approx_prompt_tokens}/{telemetry.num_ctx} "
            f"{telemetry.context_percent_estimated:.1f}%"
        )
        return
    if telemetry.phase == "after":
        print(
            f"[TULI TOKEN TRACE] role={telemetry.model_role} phase=after "
            f"actual_prompt={telemetry.actual_prompt_tokens} output={telemetry.actual_output_tokens} "
            f"total_duration={telemetry.total_duration}"
        )
        return
    print(
        f"[TULI TOKEN TRACE] role={telemetry.model_role} phase=error "
        f"model={telemetry.model} error={telemetry.error or 'unknown error'}"
    )


def emit_token_context_update(config: TuliBrainConfig, telemetry: TokenContextTelemetry) -> None:
    _print_trace(telemetry)
    try:
        append_jsonl_event(Path(config.event_stream_path).expanduser(), telemetry_to_event(telemetry))
    except Exception:
        return
