from __future__ import annotations

from dataclasses import dataclass, asdict
from typing import Any, Dict, Optional


MODE_STATUSES = ("auto", "instant", "thinking")
MODE_ROUTES = ("fast_chat", "simple_command", "mac_action", "dev_task", "workflow", "memory_analysis")
MODE_DEBUG_LEVELS = ("minimal", "full")


@dataclass(frozen=True)
class ModeDecision:
    """Final routing choice for a Tuli turn."""

    requested_mode: str = "auto"
    resolved_mode: str = "instant"
    route: str = "fast_chat"
    debug_level: str = "minimal"
    reason: str = ""
    latency_ms: Optional[int] = None

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)
