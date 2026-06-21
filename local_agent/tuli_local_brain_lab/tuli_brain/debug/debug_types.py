from __future__ import annotations

from dataclasses import dataclass, field, asdict
from typing import Any, Dict, Mapping, Optional, Tuple


DEBUG_LEVELS = ("minimal", "full")


@dataclass(frozen=True)
class DebugSnapshot:
    """Structured record of how Tuli handled a turn."""

    session_id: str
    turn_id: str
    user_text: str
    intent: str
    command: str
    risk: str
    requires_confirmation: bool
    mode: str
    model_used: str
    prompt_final: str
    raw_response: str
    clean_response: str
    actions: Tuple[Mapping[str, Any], ...] = ()
    events: Tuple[str, ...] = ()
    error: Optional[Mapping[str, Any]] = None

    def to_dict(self) -> Dict[str, Any]:
        data = asdict(self)
        data["actions"] = [dict(action) for action in self.actions]
        data["events"] = list(self.events)
        data["error"] = dict(self.error) if self.error is not None else None
        return data
