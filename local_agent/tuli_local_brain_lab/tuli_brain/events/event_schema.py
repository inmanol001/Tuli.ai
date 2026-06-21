from __future__ import annotations

import json
from dataclasses import dataclass, field, asdict
from typing import Any, Dict, Mapping, Optional


EVENT_SEVERITIES = ("debug", "info", "warning", "error")


@dataclass(frozen=True)
class EventRecord:
    """Single append-only JSONL event."""

    event_id: Optional[str]
    ts: str
    session_id: str
    turn_id: str
    event_type: str
    source: str
    severity: str = "info"
    payload: Mapping[str, Any] = field(default_factory=dict)
    model_used: Optional[str] = None
    command_name: Optional[str] = None
    action_type: Optional[str] = None
    mode: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        data = asdict(self)
        data["payload"] = dict(self.payload)
        return data

    def to_json_line(self) -> str:
        return json.dumps(self.to_dict(), ensure_ascii=False, separators=(",", ":"))
