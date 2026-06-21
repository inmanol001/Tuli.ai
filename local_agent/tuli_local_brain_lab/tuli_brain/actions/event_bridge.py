from __future__ import annotations

import os
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional

from ..events.jsonl_writer import write_jsonl_events
from .action_router import route_response_actions


EVENT_SOURCE = "tuli_brain"
DEFAULT_SESSION_ID = "local_session"


def utc_now() -> str:
    return datetime.utcnow().replace(microsecond=0).isoformat() + "Z"


def make_event_id() -> str:
    import uuid

    return "msg_" + uuid.uuid4().hex[:12]


def _session_id() -> str:
    return os.environ.get("TULI_SESSION_ID", DEFAULT_SESSION_ID).strip() or DEFAULT_SESSION_ID


@dataclass(frozen=True)
class EmitResult:
    path: str
    emitted_count: int
    event_ids: List[str]

    def to_dict(self) -> Dict[str, Any]:
        return {
            "path": self.path,
            "emitted_count": self.emitted_count,
            "event_ids": list(self.event_ids),
        }


def _build_event(
    action,
    *,
    response_text: str,
    response_emotion: str,
    turn_id: Optional[str] = None,
    event_id: Optional[str] = None,
) -> Dict[str, Any]:
    message_id = event_id or make_event_id()
    request = action.request
    payload: Dict[str, Any] = {
        "type": request.type,
        "id": message_id,
        "ts": utc_now(),
        "session_id": _session_id(),
        "turn_id": turn_id or request.turn_id or message_id,
        "source": EVENT_SOURCE,
    }

    if request.type in {"bubble_show", "bubble_update", "speech_start", "text_delta"}:
        payload["text"] = str(request.payload.get("text") or response_text)
    if request.type == "emotion_hint":
        payload["emotion"] = str(request.payload.get("emotion") or response_emotion)
        payload["intensity"] = request.payload.get("intensity", 0.7)
    if request.type in {"voice_request", "voice_started", "voice_finished"}:
        voice = request.payload.get("voice")
        if voice is not None:
            payload["voice"] = str(voice)
    if request.type == "speech_start":
        payload["bubble"] = True
    if request.type == "bubble_show":
        payload["bubble"] = True
    if request.payload:
        payload["payload"] = dict(request.payload)

    return payload


def emit_response_events(response: Dict[str, Any], event_stream_path: str | Path) -> EmitResult:
    return emit_response_events_with_turn(response, event_stream_path)


def emit_response_events_with_turn(
    response: Dict[str, Any],
    event_stream_path: str | Path,
    *,
    turn_id: Optional[str] = None,
) -> EmitResult:
    path = Path(event_stream_path).expanduser()
    routed = route_response_actions(response, turn_id=turn_id)
    message_id = make_event_id()
    events = [
        _build_event(
            action,
            response_text=str(response.get("text", "")),
            response_emotion=str(response.get("emotion", "neutral")),
            turn_id=turn_id,
            event_id=message_id,
        )
        for action in routed.actions
    ]
    write_result = write_jsonl_events(path, events)
    return EmitResult(
        path=write_result["path"],
        emitted_count=write_result["written_count"],
        event_ids=[message_id for _ in events],
    )
