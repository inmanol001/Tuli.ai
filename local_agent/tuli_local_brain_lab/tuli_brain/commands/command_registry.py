from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, Iterable, List, Mapping, Optional, Tuple

from .command_types import COMMAND_RISKS, COMMAND_ROUTES, CommandSpec


def _spec(
    name: str,
    *,
    description: str,
    aliases: Tuple[str, ...] = (),
    category: str = "general",
    requires_confirmation: bool = False,
    risk: str = "safe",
    default_mode: str = "instant",
) -> CommandSpec:
    if risk not in COMMAND_RISKS:
        raise ValueError(f"invalid command risk: {risk}")
    if default_mode not in {"auto", "instant", "thinking"}:
        raise ValueError(f"invalid default mode: {default_mode}")
    return CommandSpec(
        name=name,
        description=description,
        aliases=aliases,
        category=category,
        requires_confirmation=requires_confirmation,
        risk=risk,
        default_mode=default_mode,
    )


DEFAULT_COMMANDS: Tuple[CommandSpec, ...] = (
    _spec("help", description="Show Tuli help and available commands.", aliases=("?",), category="info"),
    _spec("status", description="Show basic Tuli status.", category="info"),
    _spec("clear", description="Clear visible chat state.", category="session"),
    _spec("debug", description="Open or print debug state.", category="debug"),
    _spec("model", description="Inspect or change the active model.", category="model"),
    _spec("macos", description="Safely observe the current macOS frontmost state.", category="system"),
    _spec("apps", description="List recognized macOS apps and note that any installed app can be opened by name.", category="system", default_mode="instant"),
    _spec("open", description="Open any installed macOS app.", aliases=("launch",), category="system", default_mode="instant"),
    _spec("instant", description="Force instant response mode.", category="mode", default_mode="instant"),
    _spec("thinking", description="Force thinking response mode.", category="mode", default_mode="thinking"),
    _spec("speak", description="Enable or disable local speech.", category="voice"),
    _spec("memory", description="Inspect memory state.", category="memory"),
    _spec("remember", description="Store a simple memory entry.", category="memory", risk="low_risk"),
    _spec("forget", description="Remove a memory entry.", category="memory", requires_confirmation=True, risk="medium_risk"),
    _spec("summarize", description="Summarize current context or memory.", category="memory"),
    _spec("pause", description="Pause background activity.", category="session"),
    _spec("resume", description="Resume background activity.", category="session"),
    _spec("export", description="Export local events or debug data.", category="debug", requires_confirmation=True, risk="medium_risk"),
)


@dataclass
class CommandRegistry:
    """Canonical registry of commands available to Tuli."""

    commands: Dict[str, CommandSpec] = field(default_factory=dict)
    aliases: Dict[str, str] = field(default_factory=dict)

    @classmethod
    def with_defaults(cls) -> "CommandRegistry":
        registry = cls()
        for spec in DEFAULT_COMMANDS:
            registry.register(spec)
        return registry

    def register(self, spec: CommandSpec) -> None:
        if spec.risk not in COMMAND_RISKS:
            raise ValueError(f"invalid command risk: {spec.risk}")
        if spec.default_mode not in {"auto", "instant", "thinking"}:
            raise ValueError(f"invalid default mode: {spec.default_mode}")

        self.commands[spec.name] = spec
        for alias in spec.aliases:
            self.aliases[alias] = spec.name

    def get(self, name: str) -> Optional[CommandSpec]:
        canonical = self.resolve_name(name)
        if canonical is None:
            return None
        return self.commands.get(canonical)

    def resolve_name(self, name: str) -> Optional[str]:
        cleaned = name.strip().lstrip("/")
        if not cleaned:
            return None
        if cleaned in self.commands:
            return cleaned
        return self.aliases.get(cleaned)

    def has(self, name: str) -> bool:
        return self.get(name) is not None

    def list(self) -> List[CommandSpec]:
        return sorted(self.commands.values(), key=lambda spec: (spec.category, spec.name))

    def by_category(self, category: str) -> List[CommandSpec]:
        return [spec for spec in self.list() if spec.category == category]

    def route_for(self, command_name: str) -> str:
        spec = self.get(command_name)
        if spec is None:
            return "fallback"
        if spec.category == "model":
            return "fast_chat"
        if spec.category == "mode":
            return "fast_chat"
        if spec.category == "debug":
            return "workflow"
        if spec.category == "system":
            return "simple_command"
        if spec.category == "memory":
            return "memory_analysis"
        if spec.category == "session":
            return "workflow"
        return "simple_command"

    def default_mode_for(self, command_name: str) -> str:
        spec = self.get(command_name)
        return spec.default_mode if spec is not None else "auto"

    def requires_confirmation(self, command_name: str) -> bool:
        spec = self.get(command_name)
        return bool(spec.requires_confirmation) if spec is not None else False

    def risk_for(self, command_name: str) -> str:
        spec = self.get(command_name)
        return spec.risk if spec is not None else "safe"

    def help_text(self) -> List[str]:
        return [f"/{spec.name} - {spec.description}" for spec in self.list()]


DEFAULT_COMMAND_REGISTRY = CommandRegistry.with_defaults()
