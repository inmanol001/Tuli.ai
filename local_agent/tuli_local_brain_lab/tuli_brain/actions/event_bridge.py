from __future__ import annotations

import json
import uuid
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List

from .action_router import route_actions


EVENT_SCHEMA = "tuli_event.v1"
EVENT_SOURCE = "tuli_brain"


def utc_now() -> str:
    return datetime.utcnow().replace(microsecond=0).isoformat() + "Z"


def make_event_id() -> str:
    return "evt_" + uuid.uuid4().hex[:12]


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


def _build_event(action: Dict[str, Any], *, response_text: str, response_emotion: str) -> Dict[str, Any]:
    return {
        "schema": EVENT_SCHEMA,
        "id": make_event_id(),
        "created_at": utc_now(),
        "source": EVENT_SOURCE,
        "action": action["type"],
        "payload": action["payload"],
        "response": {
            "text": response_text,
            "emotion": response_emotion,
        },
    }


def emit_response_events(response: Dict[str, Any], event_stream_path: str | Path) -> EmitResult:
    path = Path(event_stream_path).expanduser()
    path.parent.mkdir(parents=True, exist_ok=True)

    actions = route_actions(response)
    events = [
        _build_event(
            action,
            response_text=str(response.get("text", "")),
            response_emotion=str(response.get("emotion", "neutral")),
        )
        for action in actions
    ]

    with path.open("a", encoding="utf-8") as stream:
        for event in events:
            stream.write(json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n")

    return EmitResult(
        path=str(path),
        emitted_count=len(events),
        event_ids=[event["id"] for event in events],
    )
