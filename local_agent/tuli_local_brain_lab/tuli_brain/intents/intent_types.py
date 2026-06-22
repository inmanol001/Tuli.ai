from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Any, Dict, Mapping, Optional

from ..tools import ToolCall


@dataclass(frozen=True)
class IntentResult:
    intent_name: str
    tool_name: str
    arguments: Mapping[str, Any] = field(default_factory=dict)
    confidence: float = 0.0
    requires_confirmation: bool = False
    response_text: str = ""
    bubble_text: str = ""
    source_text: str = ""
    metadata: Mapping[str, Any] = field(default_factory=dict)
    error: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        data = asdict(self)
        data["arguments"] = dict(self.arguments)
        data["metadata"] = dict(self.metadata)
        return data


@dataclass(frozen=True)
class ActionPlan:
    should_execute: bool
    tool_call: Optional[ToolCall] = None
    requires_confirmation: bool = False
    reason: str = ""
    bubble_text: str = ""
    console_text: str = ""

    def to_dict(self) -> Dict[str, Any]:
        return {
            "should_execute": self.should_execute,
            "tool_call": self.tool_call.to_dict() if self.tool_call is not None else None,
            "requires_confirmation": self.requires_confirmation,
            "reason": self.reason,
            "bubble_text": self.bubble_text,
            "console_text": self.console_text,
        }
