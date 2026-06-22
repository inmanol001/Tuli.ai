from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Any, Dict, Mapping, Optional, Tuple


@dataclass(frozen=True)
class ToolSpec:
    name: str
    category: str
    description: str
    aliases: Tuple[str, ...] = ()
    input_schema: Mapping[str, Any] = field(default_factory=dict)
    risk_level: str = "safe"
    requires_confirmation: bool = False
    executor_ref: str = ""
    enabled: bool = True
    debug_command: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        data = asdict(self)
        data["input_schema"] = dict(self.input_schema)
        return data


@dataclass(frozen=True)
class ToolCall:
    tool_name: str
    arguments: Mapping[str, Any] = field(default_factory=dict)
    source_text: str = ""
    confidence: float = 0.0
    requires_confirmation: bool = False
    response_text: str = ""
    bubble_text: str = ""
    console_text: str = ""

    def to_dict(self) -> Dict[str, Any]:
        data = asdict(self)
        data["arguments"] = dict(self.arguments)
        return data


@dataclass(frozen=True)
class ToolResult:
    success: bool
    tool_name: str
    arguments: Mapping[str, Any] = field(default_factory=dict)
    result_text: str = ""
    bubble_text: str = ""
    console_text: str = ""
    event_payload: Optional[Mapping[str, Any]] = None
    error: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        data = asdict(self)
        data["arguments"] = dict(self.arguments)
        if self.event_payload is not None:
            data["event_payload"] = dict(self.event_payload)
        return data
