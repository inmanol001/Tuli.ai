from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Any, Dict, Optional


@dataclass(frozen=True)
class RouterDecision:
    route: str
    tool_name: str = ""
    arguments: Dict[str, Any] = field(default_factory=dict)
    confidence: float = 0.0
    clarification: str = ""
    reason: str = ""
    raw_text: str = ""
    raw_response: str = ""
    error: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)
