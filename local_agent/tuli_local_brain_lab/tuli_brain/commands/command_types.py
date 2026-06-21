from __future__ import annotations

from dataclasses import dataclass, field, asdict
from typing import Any, Dict, Mapping, Optional, Tuple


COMMAND_STATUSES = ("parsed", "routed", "confirmed", "rejected", "executed", "failed")
COMMAND_RISKS = ("safe", "low_risk", "medium_risk", "high_risk", "blocked")
COMMAND_ROUTES = ("fast_chat", "simple_command", "mac_action", "dev_task", "workflow", "fallback")


@dataclass(frozen=True)
class CommandSpec:
    """Canonical command metadata."""

    name: str
    description: str = ""
    aliases: Tuple[str, ...] = ()
    category: str = "general"
    requires_confirmation: bool = False
    risk: str = "safe"
    default_mode: str = "instant"

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True)
class ParsedCommand:
    """Result of turning user text into a structured command."""

    raw_text: str
    is_command: bool
    command_name: Optional[str] = None
    command_args: Tuple[str, ...] = ()
    command_kind: str = "chat"
    confidence: float = 0.0
    parse_reason: str = ""
    requires_confirmation: bool = False
    danger_level: str = "safe"
    requested_mode: str = "auto"

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True)
class CommandRoutingDecision:
    """How Tuli decided to handle a command or user utterance."""

    route: str
    mode: str
    command_name: Optional[str] = None
    risk: str = "safe"
    requires_confirmation: bool = False
    reason: str = ""

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True)
class CommandError:
    """Structured command-level error."""

    error_type: str
    message: str
    source: str = "commands"
    recoverable: bool = True
    context: Mapping[str, Any] = field(default_factory=dict)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "error_type": self.error_type,
            "message": self.message,
            "source": self.source,
            "recoverable": self.recoverable,
            "context": dict(self.context),
        }


@dataclass(frozen=True)
class CommandExecutionResult:
    """Outcome of executing a command or command-like action."""

    ok: bool
    command_name: str
    status: str = "executed"
    output: Mapping[str, Any] = field(default_factory=dict)
    duration_ms: Optional[int] = None
    error: Optional[CommandError] = None

    def to_dict(self) -> Dict[str, Any]:
        data = asdict(self)
        if self.error is not None:
            data["error"] = self.error.to_dict()
        return data
