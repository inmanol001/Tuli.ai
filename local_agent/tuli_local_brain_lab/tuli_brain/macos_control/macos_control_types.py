from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Any, Dict, Mapping, Optional


MACOS_CONTROL_STATUS = ("ok", "degraded", "unavailable", "error")
MACOS_OBSERVATION_LEVELS = ("safe", "coarse", "manual")


@dataclass(frozen=True)
class MacOSObservation:
    """Coarse snapshot of the currently focused macOS state."""

    observation_id: str
    observed_at: str
    source: str
    status: str = "ok"
    privacy_level: str = "safe"
    app_name: Optional[str] = None
    bundle_id: Optional[str] = None
    window_title: Optional[str] = None
    is_frontmost: bool = True
    notes: Optional[str] = None
    metadata: Mapping[str, Any] = field(default_factory=dict)

    def to_dict(self) -> Dict[str, Any]:
        data = asdict(self)
        data["metadata"] = dict(self.metadata)
        return data


@dataclass(frozen=True)
class MacOSControlResult:
    """Result of a macOS observation or safe control step."""

    ok: bool
    operation: str
    observation: Optional[MacOSObservation] = None
    status: str = "ok"
    error: Optional[Mapping[str, Any]] = None

    def to_dict(self) -> Dict[str, Any]:
        return {
            "ok": self.ok,
            "operation": self.operation,
            "observation": self.observation.to_dict() if self.observation is not None else None,
            "status": self.status,
            "error": dict(self.error) if self.error is not None else None,
        }
