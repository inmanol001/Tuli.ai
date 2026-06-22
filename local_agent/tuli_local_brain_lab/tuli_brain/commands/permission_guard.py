from __future__ import annotations

from dataclasses import dataclass, asdict
from typing import Any, Dict, Mapping, Optional

from .command_types import COMMAND_RISKS, CommandError, ParsedCommand


PERMISSION_STATUSES = ("allow", "confirm", "deny")

_HIGH_RISK_COMMANDS = {
    "forget",
    "export",
}

_CONFIRMATION_KEYWORDS = {
    "delete",
    "remove",
    "borrar",
    "eliminar",
    "clear",
    "wipe",
    "overwrite",
    "write_file",
    "edit_file",
    "shell",
    "execute_shell",
    "screenshot",
    "click",
    "type_text",
}

_ALWAYS_SAFE_COMMANDS = {
    "help",
    "status",
    "debug",
    "open",
    "instant",
    "thinking",
    "speak",
    "memory",
    "remember",
    "summarize",
    "pause",
    "resume",
    "permissions",
    "windows",
    "layout",
    "space",
}


@dataclass(frozen=True)
class PermissionDecision:
    """Outcome of evaluating whether a command may run."""

    status: str
    reason: str
    command_name: Optional[str] = None
    risk: str = "safe"
    requires_confirmation: bool = False
    blocked: bool = False
    source: str = "permission_guard"

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


def _risk_from_parsed(parsed: ParsedCommand) -> str:
    if parsed.danger_level in COMMAND_RISKS:
        return parsed.danger_level
    return "safe"


def _looks_sensitive_command(name: str) -> bool:
    lowered = name.lower()
    if lowered in _ALWAYS_SAFE_COMMANDS:
        return False
    if lowered in _HIGH_RISK_COMMANDS:
        return True
    return any(keyword in lowered for keyword in _CONFIRMATION_KEYWORDS)


def evaluate_permission(parsed: ParsedCommand) -> PermissionDecision:
    """Return a simple allow / confirm / deny decision for a parsed command."""

    if not parsed.is_command or not parsed.command_name:
        return PermissionDecision(
            status="allow",
            reason="natural language chat",
            command_name=None,
            risk="safe",
            requires_confirmation=False,
            blocked=False,
        )

    risk = _risk_from_parsed(parsed)
    command_name = parsed.command_name
    requires_confirmation = bool(parsed.requires_confirmation)

    if risk == "blocked":
        return PermissionDecision(
            status="deny",
            reason="command is blocked by policy",
            command_name=command_name,
            risk=risk,
            requires_confirmation=False,
            blocked=True,
        )

    if requires_confirmation or _looks_sensitive_command(command_name):
        return PermissionDecision(
            status="confirm",
            reason="command requires confirmation",
            command_name=command_name,
            risk=risk if risk != "safe" else "medium_risk",
            requires_confirmation=True,
            blocked=False,
        )

    return PermissionDecision(
        status="allow",
        reason="safe command",
        command_name=command_name,
        risk=risk,
        requires_confirmation=False,
        blocked=False,
    )


def permission_error(decision: PermissionDecision) -> CommandError:
    """Convert a permission decision into a structured error."""

    return CommandError(
        error_type="permission_denied",
        message=decision.reason,
        source=decision.source,
        recoverable=decision.status == "confirm",
        context=decision.to_dict(),
    )
