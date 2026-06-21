from __future__ import annotations

from dataclasses import dataclass, asdict, field
from typing import Any, Dict, Mapping, Optional, Tuple


ACTIVITY_KINDS = (
    "turn",
    "app_focus",
    "window_focus",
    "speech",
    "system",
    "note",
)

ACTIVITY_SEVERITIES = ("debug", "info", "warning", "error")
ACTIVITY_PRIVACY_LEVELS = ("coarse", "summary", "manual")


@dataclass(frozen=True)
class ActivityRecord:
    """Privacy-conscious local activity record."""

    activity_id: str
    ts: str
    session_id: str
    source: str
    kind: str
    summary: str
    severity: str = "info"
    privacy_level: str = "coarse"
    app_name: Optional[str] = None
    window_title: Optional[str] = None
    turn_id: Optional[str] = None
    command_name: Optional[str] = None
    route: Optional[str] = None
    model_used: Optional[str] = None
    tags: Tuple[str, ...] = ()
    metadata: Mapping[str, Any] = field(default_factory=dict)

    def to_dict(self) -> Dict[str, Any]:
        data = asdict(self)
        data["tags"] = list(self.tags)
        data["metadata"] = dict(self.metadata)
        return data


@dataclass(frozen=True)
class ActivitySummary:
    """Compact summary for recent local activity."""

    text: str
    session_id: str
    source: str
    activity_ids: Tuple[str, ...] = ()
    recent_kinds: Tuple[str, ...] = ()

    def to_dict(self) -> Dict[str, Any]:
        data = asdict(self)
        data["activity_ids"] = list(self.activity_ids)
        data["recent_kinds"] = list(self.recent_kinds)
        return data


@dataclass(frozen=True)
class ActivityWriteResult:
    """Result of writing activity records."""

    path: str
    written_count: int
    dropped_count: int = 0

    def to_dict(self) -> Dict[str, Any]:
        return {
            "path": self.path,
            "written_count": self.written_count,
            "dropped_count": self.dropped_count,
        }
