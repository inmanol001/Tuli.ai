from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, Iterable, List, Optional

from .tool_types import ToolSpec


def _tool(
    name: str,
    *,
    category: str,
    description: str,
    aliases: tuple[str, ...] = (),
    input_schema: Optional[dict] = None,
    risk_level: str = "safe",
    requires_confirmation: bool = False,
    executor_ref: str = "",
    enabled: bool = True,
    debug_command: str | None = None,
) -> ToolSpec:
    return ToolSpec(
        name=name,
        category=category,
        description=description,
        aliases=aliases,
        input_schema=input_schema or {},
        risk_level=risk_level,
        requires_confirmation=requires_confirmation,
        executor_ref=executor_ref,
        enabled=enabled,
        debug_command=debug_command,
    )


DEFAULT_TOOL_SPECS: tuple[ToolSpec, ...] = (
    _tool("system.status", category="system", description="Inspect current Tuli runtime status.", aliases=("status",), executor_ref="command:status", debug_command="/status"),
    _tool("system.debug", category="system", description="Inspect local debug paths and runtime debug state.", aliases=("debug",), executor_ref="command:debug", debug_command="/debug"),
    _tool("system.clear", category="system", description="Clear visible chat state.", aliases=("clear",), executor_ref="command:clear", debug_command="/clear"),
    _tool("system.pause", category="system", description="Pause background activity.", aliases=("pause",), executor_ref="command:pause", debug_command="/pause"),
    _tool("system.resume", category="system", description="Resume background activity.", aliases=("resume",), executor_ref="command:resume", debug_command="/resume"),
    _tool("memory.inspect", category="memory", description="Inspect memory counts and session summary state.", aliases=("memory",), executor_ref="command:memory", debug_command="/memory"),
    _tool("memory.remember", category="memory", description="Store a memory entry.", aliases=("remember",), input_schema={"text": "string"}, risk_level="low_risk", executor_ref="command:remember"),
    _tool("memory.forget", category="memory", description="Forget a memory entry.", aliases=("forget",), input_schema={"query": "string"}, risk_level="medium_risk", requires_confirmation=True, executor_ref="command:forget"),
    _tool("memory.summarize", category="memory", description="Summarize memory or context.", aliases=("summarize",), executor_ref="command:summarize"),
    _tool("model.inspect", category="model", description="Inspect the active model.", aliases=("model.inspect",), executor_ref="command:model", debug_command="/model"),
    _tool("model.switch", category="model", description="Switch the active model.", aliases=("model.switch",), input_schema={"model": "string"}, risk_level="low_risk", executor_ref="command:model"),
    _tool("mode.instant", category="mode", description="Force instant mode.", aliases=("instant",), executor_ref="command:instant", debug_command="/instant"),
    _tool("mode.thinking", category="mode", description="Force thinking mode.", aliases=("thinking",), executor_ref="command:thinking", debug_command="/thinking"),
    _tool("voice.speak_toggle", category="voice", description="Enable or disable speech for a turn.", aliases=("speak",), input_schema={"state": "string"}, executor_ref="command:speak"),
    _tool("avatar.bubble_show", category="avatar", description="Show a speech bubble on the avatar.", aliases=("bubble",), input_schema={"text": "string"}, executor_ref="action:bubble_show"),
    _tool("avatar.emotion_hint", category="avatar", description="Hint an avatar emotion.", aliases=("emotion",), input_schema={"emotion": "string"}, executor_ref="action:emotion_hint"),
    _tool("macos.permissions_check", category="macos_observation", description="Check macOS permissions used by Tuli.", aliases=("permissions",), executor_ref="command:permissions", debug_command="/permissions"),
    _tool("macos.observe_frontmost", category="macos_observation", description="Observe the frontmost macOS app and window.", aliases=("macos",), executor_ref="command:macos", debug_command="/macos"),
    _tool("macos.visible_windows", category="macos_observation", description="List visible macOS windows.", aliases=("windows",), executor_ref="command:windows", debug_command="/windows"),
    _tool("macos.list_apps", category="macos_observation", description="List known macOS application names.", aliases=("apps",), executor_ref="command:apps", debug_command="/apps"),
    _tool("macos.open_app", category="macos_action", description="Open a macOS application by name.", aliases=("open",), input_schema={"app_name": "string"}, executor_ref="command:open"),
    _tool("macos.focus_app", category="macos_action", description="Focus a macOS application.", aliases=("focus_app",), input_schema={"app_name": "string"}, risk_level="low_risk", executor_ref="", enabled=False),
    _tool("macos.minimize_app", category="macos_action", description="Minimize the frontmost or selected app window.", aliases=("minimize_app",), input_schema={"app_name": "string"}, risk_level="low_risk", executor_ref="", enabled=False),
    _tool("window.native_tiling", category="window_layout", description="Run native macOS window tiling on the frontmost window.", aliases=("window.native",), input_schema={"action": "string"}, executor_ref="command:window.native"),
    _tool("layout.status", category="window_layout", description="Read current layout state.", aliases=("layout.status",), executor_ref="command:layout.status", debug_command="/layout status"),
    _tool("layout.preview", category="window_layout", description="Preview current layout plan.", aliases=("layout.preview",), executor_ref="command:layout.preview", debug_command="/layout preview"),
    _tool("layout.split", category="window_layout", description="Build a split layout plan.", aliases=("layout.split",), executor_ref="command:layout.split", debug_command="/layout split"),
    _tool("layout.clear", category="window_layout", description="Clear layout state.", aliases=("layout.clear",), executor_ref="command:layout.clear", debug_command="/layout clear"),
    _tool("space.status", category="space", description="Read basic macOS Spaces status.", aliases=("space.status",), executor_ref="command:space.status", debug_command="/space status"),
    _tool("space.next", category="space", description="Switch to the next macOS Space.", aliases=("space.next",), executor_ref="command:space.next", debug_command="/space next"),
    _tool("space.previous", category="space", description="Switch to the previous macOS Space.", aliases=("space.previous",), executor_ref="command:space.previous", debug_command="/space previous"),
    _tool("space.mission_control", category="space", description="Open Mission Control.", aliases=("space.mission-control",), executor_ref="command:space.mission-control", debug_command="/space mission-control"),
    _tool("space.switch_desktop_number", category="space", description="Switch to a direct desktop number via Mission Control shortcut.", aliases=("space.desktop",), input_schema={"number": "integer"}, executor_ref="command:space.desktop"),
)


@dataclass
class ToolCatalog:
    tools: Dict[str, ToolSpec] = field(default_factory=dict)
    aliases: Dict[str, str] = field(default_factory=dict)

    @classmethod
    def with_defaults(cls) -> "ToolCatalog":
        catalog = cls()
        for spec in DEFAULT_TOOL_SPECS:
            catalog.register(spec)
        return catalog

    def register(self, tool_spec: ToolSpec) -> None:
        self.tools[tool_spec.name] = tool_spec
        self.aliases[tool_spec.name] = tool_spec.name
        for alias in tool_spec.aliases:
            self.aliases[alias] = tool_spec.name

    def get(self, name: str) -> Optional[ToolSpec]:
        canonical = self.find_by_alias(name)
        if canonical is None:
            return None
        return self.tools.get(canonical)

    def has(self, name: str) -> bool:
        return self.get(name) is not None

    def list(self) -> List[ToolSpec]:
        return sorted(self.tools.values(), key=lambda tool: (tool.category, tool.name))

    def by_category(self, category: str) -> List[ToolSpec]:
        return [tool for tool in self.list() if tool.category == category]

    def find_by_alias(self, alias: str) -> Optional[str]:
        cleaned = str(alias or "").strip()
        if not cleaned:
            return None
        return self.aliases.get(cleaned)

    def enabled_tools(self) -> List[ToolSpec]:
        return [tool for tool in self.list() if tool.enabled]

    def to_dict(self) -> Dict[str, object]:
        return {
            "tools": [tool.to_dict() for tool in self.list()],
            "aliases": dict(self.aliases),
        }


DEFAULT_TOOL_CATALOG = ToolCatalog.with_defaults()
