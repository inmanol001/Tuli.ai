"""Command types and routing primitives for Tuli."""

from .command_types import (
    COMMAND_RISKS,
    COMMAND_ROUTES,
    COMMAND_STATUSES,
    CommandError,
    CommandExecutionResult,
    CommandRoutingDecision,
    CommandSpec,
    ParsedCommand,
)
from .command_registry import DEFAULT_COMMAND_REGISTRY, CommandRegistry
from .command_parser import command_name_or_none, is_low_confidence, parse_command, parse_many
from .command_router import CommandRouteResult, requires_confirmation, route_label, route_parsed_command, route_summary, route_user_text
from .permission_guard import PermissionDecision, evaluate_permission, permission_error

__all__ = [
    "COMMAND_RISKS",
    "COMMAND_ROUTES",
    "COMMAND_STATUSES",
    "CommandError",
    "CommandExecutionResult",
    "CommandRoutingDecision",
    "CommandSpec",
    "CommandRegistry",
    "DEFAULT_COMMAND_REGISTRY",
    "command_name_or_none",
    "is_low_confidence",
    "CommandRouteResult",
    "PermissionDecision",
    "evaluate_permission",
    "permission_error",
    "requires_confirmation",
    "route_label",
    "route_parsed_command",
    "route_summary",
    "route_user_text",
    "parse_command",
    "parse_many",
    "ParsedCommand",
]
