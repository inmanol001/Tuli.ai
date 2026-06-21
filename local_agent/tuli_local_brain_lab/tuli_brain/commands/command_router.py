from __future__ import annotations

from dataclasses import dataclass, asdict
from typing import Any, Dict, Optional

from .command_parser import parse_command
from .command_registry import DEFAULT_COMMAND_REGISTRY, CommandRegistry
from .command_types import CommandRoutingDecision, ParsedCommand
from .permission_guard import PermissionDecision, evaluate_permission
from ..modes.mode_router import choose_mode, mode_command_decision
from ..modes.mode_types import ModeDecision


@dataclass(frozen=True)
class CommandRouteResult:
    """High-level routing decision for one user input."""

    parsed: ParsedCommand
    permission: PermissionDecision
    mode: ModeDecision
    routing: CommandRoutingDecision

    def to_dict(self) -> Dict[str, Any]:
        return {
            "parsed": self.parsed.to_dict(),
            "permission": self.permission.to_dict(),
            "mode": self.mode.to_dict(),
            "routing": self.routing.to_dict(),
        }

    @property
    def command_name(self) -> Optional[str]:
        return self.parsed.command_name

    @property
    def requires_confirmation(self) -> bool:
        return self.permission.status in {"confirm", "deny"} or self.parsed.requires_confirmation

    @property
    def is_command(self) -> bool:
        return self.parsed.is_command


def route_user_text(
    user_text: str,
    *,
    registry: CommandRegistry = DEFAULT_COMMAND_REGISTRY,
) -> CommandRouteResult:
    parsed = parse_command(user_text, registry=registry)
    permission = evaluate_permission(parsed)
    mode = choose_mode(parsed, permission=permission, registry=registry)
    routing = mode_command_decision(parsed, permission=permission, registry=registry)
    return CommandRouteResult(
        parsed=parsed,
        permission=permission,
        mode=mode,
        routing=routing,
    )


def route_parsed_command(
    parsed: ParsedCommand,
    *,
    registry: CommandRegistry = DEFAULT_COMMAND_REGISTRY,
) -> CommandRouteResult:
    permission = evaluate_permission(parsed)
    mode = choose_mode(parsed, permission=permission, registry=registry)
    routing = mode_command_decision(parsed, permission=permission, registry=registry)
    return CommandRouteResult(
        parsed=parsed,
        permission=permission,
        mode=mode,
        routing=routing,
    )


def requires_confirmation(user_text: str, *, registry: CommandRegistry = DEFAULT_COMMAND_REGISTRY) -> bool:
    return route_user_text(user_text, registry=registry).requires_confirmation


def route_summary(result: CommandRouteResult) -> Dict[str, Any]:
    return {
        "command_name": result.command_name,
        "route": result.routing.route,
        "mode": result.mode.resolved_mode,
        "risk": result.routing.risk,
        "status": result.permission.status,
        "requires_confirmation": result.requires_confirmation,
        "reason": result.routing.reason,
    }


def route_label(user_text: str, *, registry: CommandRegistry = DEFAULT_COMMAND_REGISTRY) -> str:
    result = route_user_text(user_text, registry=registry)
    if not result.is_command:
        return "chat"
    return result.routing.route

