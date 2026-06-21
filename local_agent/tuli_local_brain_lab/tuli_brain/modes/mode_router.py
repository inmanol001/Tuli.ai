from __future__ import annotations

from typing import Optional

from ..commands.command_registry import DEFAULT_COMMAND_REGISTRY, CommandRegistry
from ..commands.command_types import CommandRoutingDecision, ParsedCommand
from ..commands.permission_guard import PermissionDecision
from .mode_types import MODE_DEBUG_LEVELS, MODE_ROUTES, MODE_STATUSES, ModeDecision


_THINKING_ROUTES = {"dev_task", "workflow", "memory_analysis", "mac_action"}
_THINKING_COMMANDS = {"debug", "summarize", "forget", "export"}


def resolve_route(
    parsed: ParsedCommand,
    registry: CommandRegistry = DEFAULT_COMMAND_REGISTRY,
) -> str:
    if not parsed.is_command or not parsed.command_name:
        return "fast_chat"
    spec = registry.get(parsed.command_name)
    if spec is not None:
        return registry.route_for(spec.name)

    kind = (parsed.command_kind or "").lower()
    if kind in {"debug"}:
        return "workflow"
    if kind in {"memory"}:
        return "memory_analysis"
    if kind in {"mode", "info", "session", "voice"}:
        return "simple_command"
    return "fallback"


def _normalize_requested_mode(requested_mode: Optional[str]) -> str:
    requested = (requested_mode or "auto").strip().lower()
    if requested in MODE_STATUSES:
        return requested
    return "auto"


def choose_mode(
    parsed: ParsedCommand,
    *,
    permission: Optional[PermissionDecision] = None,
    registry: CommandRegistry = DEFAULT_COMMAND_REGISTRY,
) -> ModeDecision:
    requested_mode = _normalize_requested_mode(parsed.requested_mode)
    route = resolve_route(parsed, registry=registry)
    command_name = parsed.command_name or ""

    if permission is not None and permission.status in {"confirm", "deny"}:
        return ModeDecision(
            requested_mode=requested_mode,
            resolved_mode="thinking",
            route=route,
            debug_level="full",
            reason=f"permission status requires deeper handling: {permission.status}",
        )

    if requested_mode in {"instant", "thinking"}:
        debug_level = "minimal" if requested_mode == "instant" else "full"
        return ModeDecision(
            requested_mode=requested_mode,
            resolved_mode=requested_mode,
            route=route,
            debug_level=debug_level,
            reason="manual override",
        )

    if route in _THINKING_ROUTES or command_name in _THINKING_COMMANDS:
        return ModeDecision(
            requested_mode=requested_mode,
            resolved_mode="thinking",
            route=route,
            debug_level="full",
            reason="route requires deeper reasoning",
        )

    if parsed.command_kind in {"memory"} and parsed.command_name not in {"remember"}:
        return ModeDecision(
            requested_mode=requested_mode,
            resolved_mode="thinking",
            route=route,
            debug_level="full",
            reason="memory analysis benefits from deeper reasoning",
        )

    if parsed.is_command and parsed.command_name in registry.commands:
        spec = registry.get(parsed.command_name)
        resolved_mode = spec.default_mode if spec is not None else "instant"
        debug_level = "minimal" if resolved_mode == "instant" else "full"
        return ModeDecision(
            requested_mode=requested_mode,
            resolved_mode=resolved_mode,
            route=route,
            debug_level=debug_level,
            reason="command default mode",
        )

    if parsed.is_command and parsed.confidence >= 0.8:
        return ModeDecision(
            requested_mode=requested_mode,
            resolved_mode="instant",
            route=route,
            debug_level="minimal",
            reason="high-confidence simple command",
        )

    return ModeDecision(
        requested_mode=requested_mode,
        resolved_mode="instant",
        route=route,
        debug_level="minimal",
        reason="default fast path",
    )


def should_force_thinking(
    parsed: ParsedCommand,
    permission: Optional[PermissionDecision] = None,
    registry: CommandRegistry = DEFAULT_COMMAND_REGISTRY,
) -> bool:
    return choose_mode(parsed, permission=permission, registry=registry).resolved_mode == "thinking"


def mode_to_command_route(mode: str) -> str:
    normalized = (mode or "instant").strip().lower()
    if normalized == "thinking":
        return "workflow"
    return "fast_chat"


def mode_command_decision(
    parsed: ParsedCommand,
    *,
    permission: Optional[PermissionDecision] = None,
    registry: CommandRegistry = DEFAULT_COMMAND_REGISTRY,
) -> CommandRoutingDecision:
    mode_decision = choose_mode(parsed, permission=permission, registry=registry)
    return CommandRoutingDecision(
        route=mode_decision.route,
        mode=mode_decision.resolved_mode,
        command_name=parsed.command_name,
        risk=parsed.danger_level,
        requires_confirmation=parsed.requires_confirmation,
        reason=mode_decision.reason,
    )

