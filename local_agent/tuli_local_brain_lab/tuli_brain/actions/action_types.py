from __future__ import annotations

from dataclasses import dataclass, field, asdict
from typing import Any, Dict, Mapping, Optional, Tuple


ACTION_STATUSES = ("requested", "confirmed", "executing", "completed", "failed", "declined")
ACTION_TYPES = (
    "bubble_show",
    "bubble_update",
    "emotion_hint",
    "voice_request",
    "voice_started",
    "voice_finished",
    "speech_start",
    "speech_end",
    "memory_store_fact",
    "memory_store_summary",
    "debug_snapshot",
    "activity_note",
    "status_update",
    "error",
)


@dataclass(frozen=True)
class ActionRequest:
    """A normalized action emitted by the brain."""

    type: str
    payload: Mapping[str, Any] = field(default_factory=dict)
    status: str = "requested"
    requires_confirmation: bool = False
    source: str = "brain"
    turn_id: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        return {
            "type": self.type,
            "payload": dict(self.payload),
            "status": self.status,
            "requires_confirmation": self.requires_confirmation,
            "source": self.source,
            "turn_id": self.turn_id,
        }


@dataclass(frozen=True)
class ActionResult:
    """Outcome of executing one action."""

    ok: bool
    type: str
    status: str = "completed"
    output: Mapping[str, Any] = field(default_factory=dict)
    duration_ms: Optional[int] = None
    error: Optional[Mapping[str, Any]] = None

    def to_dict(self) -> Dict[str, Any]:
        return {
            "ok": self.ok,
            "type": self.type,
            "status": self.status,
            "output": dict(self.output),
            "duration_ms": self.duration_ms,
            "error": dict(self.error) if self.error is not None else None,
        }
