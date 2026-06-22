from __future__ import annotations

import os
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, Mapping

from ..config import load_config
from ..layout import LayoutManager
from ..macos_control import MacOSControl, NativeWindowTiling, SpaceControl, check_macos_permissions, format_native_tiling_result, format_permissions_report, format_space_control_result, format_space_status_result, format_window_report, list_known_applications, probe_visible_windows
from ..memory.sqlite_memory import SQLiteMemoryStore
from .tool_catalog import DEFAULT_TOOL_CATALOG, ToolCatalog
from .tool_types import ToolCall, ToolResult


_WINDOW_BUBBLE_TEXT = {
    "right": "Moving this window to the right.",
    "left": "Moving this window to the left.",
    "fill": "Filling this window.",
    "center": "Centering this window.",
    "quarters": "Arranging windows into quarters.",
    "top-left": "Moving this window to the top left.",
    "top-right": "Moving this window to the top right.",
    "bottom-left": "Moving this window to the bottom left.",
    "bottom-right": "Moving this window to the bottom right.",
    "return": "Restoring the previous window size.",
    "top": "Moving this window to the top.",
    "bottom": "Moving this window to the bottom.",
    "left-right": "Arranging this window across left and right.",
}

_SPACE_BUBBLE_TEXT = {
    "space.next": "Switching to the next desktop.",
    "space.previous": "Returning to the previous desktop.",
    "space.mission_control": "Opening Mission Control.",
    "space.status": "Checking desktop spaces.",
}


@dataclass
class ToolExecutor:
    catalog: ToolCatalog = DEFAULT_TOOL_CATALOG
    _handlers: Dict[str, Callable[[ToolCall], ToolResult]] = field(init=False, repr=False)

    def __post_init__(self) -> None:
        self._handlers = {
            "system.status": self._execute_system_status,
            "system.debug": self._execute_system_debug,
            "system.clear": self._execute_system_clear,
            "system.pause": self._execute_system_pause,
            "system.resume": self._execute_system_resume,
            "memory.inspect": self._execute_memory_inspect,
            "memory.remember": self._execute_memory_remember,
            "memory.summarize": self._execute_memory_summarize,
            "model.inspect": self._execute_model_inspect,
            "model.switch": self._execute_model_switch,
            "mode.instant": self._execute_mode_instant,
            "mode.thinking": self._execute_mode_thinking,
            "voice.speak_toggle": self._execute_voice_speak_toggle,
            "avatar.bubble_show": self._execute_avatar_bubble_show,
            "avatar.emotion_hint": self._execute_avatar_emotion_hint,
            "macos.permissions_check": self._execute_macos_permissions_check,
            "macos.observe_frontmost": self._execute_macos_observe_frontmost,
            "macos.visible_windows": self._execute_macos_visible_windows,
            "macos.list_apps": self._execute_macos_list_apps,
            "macos.open_app": self._execute_macos_open_app,
            "window.native_tiling": self._execute_window_native_tiling,
            "layout.status": self._execute_layout_status,
            "layout.preview": self._execute_layout_preview,
            "layout.split": self._execute_layout_split,
            "layout.clear": self._execute_layout_clear,
            "space.status": self._execute_space_status,
            "space.next": self._execute_space_next,
            "space.previous": self._execute_space_previous,
            "space.mission_control": self._execute_space_mission_control,
            "space.switch_desktop_number": self._execute_space_switch_desktop_number,
        }

    def execute(self, tool_call: ToolCall) -> ToolResult:
        tool_spec = self.catalog.get(tool_call.tool_name)
        if tool_spec is None:
            return ToolResult(
                success=False,
                tool_name=tool_call.tool_name,
                arguments=tool_call.arguments,
                result_text="Tool execution blocked.",
                bubble_text="I could not find that tool.",
                console_text=f"Unknown tool: {tool_call.tool_name}",
                error=f"unknown tool: {tool_call.tool_name}",
            )

        if not tool_spec.enabled:
            return self._result(
                False,
                tool_spec.name,
                tool_call.arguments,
                bubble_text=f"{tool_spec.name} is not available.",
                console_text=f"Tool disabled: {tool_spec.name}",
                error=f"tool disabled: {tool_spec.name}",
            )

        if tool_spec.requires_confirmation or tool_call.requires_confirmation:
            return self._result(
                False,
                tool_spec.name,
                tool_call.arguments,
                bubble_text="I need confirmation before using that tool.",
                console_text=f"Tool requires confirmation: {tool_spec.name}",
                error=f"confirmation required: {tool_spec.name}",
            )

        missing_argument = self._missing_required_argument(tool_spec.name, tool_spec.input_schema, tool_call.arguments)
        if missing_argument is not None:
            return self._result(
                False,
                tool_spec.name,
                tool_call.arguments,
                bubble_text="That tool is missing a required detail.",
                console_text=f"Missing required argument '{missing_argument}' for {tool_spec.name}",
                error=f"missing argument: {missing_argument}",
            )

        handler = self._handlers.get(tool_spec.name)
        if handler is None:
            return self._result(
                False,
                tool_spec.name,
                tool_call.arguments,
                bubble_text=f"{tool_spec.name} is not wired yet.",
                console_text=f"No executor implemented for {tool_spec.name} ({tool_spec.executor_ref})",
                error=f"executor not implemented: {tool_spec.executor_ref or tool_spec.name}",
            )

        try:
            return handler(tool_call)
        except Exception as exc:
            return self._result(
                False,
                tool_spec.name,
                tool_call.arguments,
                bubble_text="That tool failed safely.",
                console_text=f"Tool execution failed for {tool_spec.name}: {exc}",
                error=str(exc),
            )

    def _missing_required_argument(self, tool_name: str, input_schema: Mapping[str, Any], arguments: Mapping[str, Any]) -> str | None:
        if tool_name in {"voice.speak_toggle"}:
            return None
        for key in input_schema.keys():
            value = arguments.get(key)
            if value is None:
                return str(key)
            if isinstance(value, str) and not value.strip():
                return str(key)
        return None

    def _memory_store(self) -> SQLiteMemoryStore:
        config = load_config()
        store = SQLiteMemoryStore(config.memory_db_path)
        store.initialize()
        return store

    def _result(
        self,
        success: bool,
        tool_name: str,
        arguments: Mapping[str, Any],
        *,
        bubble_text: str,
        console_text: str,
        event_payload: Mapping[str, Any] | None = None,
        error: str | None = None,
    ) -> ToolResult:
        return ToolResult(
            success=success,
            tool_name=tool_name,
            arguments=dict(arguments),
            result_text=console_text,
            bubble_text=bubble_text,
            console_text=console_text,
            event_payload=dict(event_payload) if event_payload is not None else None,
            error=error,
        )

    def _execute_system_status(self, tool_call: ToolCall) -> ToolResult:
        config = load_config()
        memory_store = self._memory_store()
        console = (
            "System status:\n"
            f"- base_model: {config.ollama_model}\n"
            f"- memories: {memory_store.count()}\n"
            f"- sessions: {memory_store.count_sessions()}"
        )
        return self._result(True, "system.status", tool_call.arguments, bubble_text="Tuli is active.", console_text=console)

    def _execute_system_debug(self, tool_call: ToolCall) -> ToolResult:
        config = load_config()
        console = (
            "System debug:\n"
            f"- debug_store_path: {config.debug_store_path}\n"
            f"- event_stream_path: {config.event_stream_path}"
        )
        return self._result(True, "system.debug", tool_call.arguments, bubble_text="Opening debug state.", console_text=console)

    def _execute_system_clear(self, tool_call: ToolCall) -> ToolResult:
        return self._result(True, "system.clear", tool_call.arguments, bubble_text="Clearing visible chat state.", console_text="clear requested")

    def _execute_system_pause(self, tool_call: ToolCall) -> ToolResult:
        return self._result(True, "system.pause", tool_call.arguments, bubble_text="Pausing background activity.", console_text="pause requested")

    def _execute_system_resume(self, tool_call: ToolCall) -> ToolResult:
        return self._result(True, "system.resume", tool_call.arguments, bubble_text="Resuming background activity.", console_text="resume requested")

    def _execute_memory_inspect(self, tool_call: ToolCall) -> ToolResult:
        store = self._memory_store()
        console = (
            "Memory inspect:\n"
            f"- count: {store.count()}\n"
            f"- sessions: {store.count_sessions()}\n"
            f"- summaries: {store.count_session_summaries()}"
        )
        return self._result(True, "memory.inspect", tool_call.arguments, bubble_text="Checking memory.", console_text=console)

    def _execute_memory_remember(self, tool_call: ToolCall) -> ToolResult:
        store = self._memory_store()
        text = str(tool_call.arguments.get("text") or "").strip()
        session_id = os.environ.get("TULI_SESSION_ID", "local_session").strip() or "local_session"
        item = store.add_memory(
            kind="episodic",
            text=text,
            source="tools.memory.remember",
            importance=0.6,
            confidence=max(0.0, min(1.0, float(tool_call.confidence or 0.8))),
            tags=("tool", "remember"),
            session_id=session_id,
        )
        console = (
            "Memory stored:\n"
            f"- id: {item.id}\n"
            f"- kind: {item.kind}\n"
            f"- text: {item.text}"
        )
        return self._result(True, "memory.remember", tool_call.arguments, bubble_text="I'll remember that.", console_text=console)

    def _execute_memory_summarize(self, tool_call: ToolCall) -> ToolResult:
        return self._result(True, "memory.summarize", tool_call.arguments, bubble_text="Preparing summary.", console_text="memory summarize flow is pending")

    def _execute_model_inspect(self, tool_call: ToolCall) -> ToolResult:
        config = load_config()
        console = f"Model inspect:\n- current_model: {config.ollama_model}"
        return self._result(True, "model.inspect", tool_call.arguments, bubble_text="Checking the current model.", console_text=console)

    def _execute_model_switch(self, tool_call: ToolCall) -> ToolResult:
        requested_model = str(tool_call.arguments.get("model") or "").strip()
        console = (
            "Model switch pending:\n"
            f"- requested_model: {requested_model}\n"
            "- note: persistent model switching is not wired yet."
        )
        return self._result(True, "model.switch", tool_call.arguments, bubble_text="Preparing model switch.", console_text=console)

    def _execute_mode_instant(self, tool_call: ToolCall) -> ToolResult:
        return self._result(True, "mode.instant", tool_call.arguments, bubble_text="Instant mode enabled.", console_text="Mode: instant")

    def _execute_mode_thinking(self, tool_call: ToolCall) -> ToolResult:
        return self._result(True, "mode.thinking", tool_call.arguments, bubble_text="Thinking mode enabled.", console_text="Mode: thinking")

    def _execute_voice_speak_toggle(self, tool_call: ToolCall) -> ToolResult:
        state = str(tool_call.arguments.get("state") or "on").strip().lower()
        normalized = "off" if state in {"off", "false", "0", "no", "mute"} else "on"
        bubble = "Voice enabled." if normalized == "on" else "Voice disabled."
        console = f"Voice speak toggle:\n- state: {normalized}\n- note: no persistent global toggle was changed."
        return self._result(True, "voice.speak_toggle", tool_call.arguments, bubble_text=bubble, console_text=console)

    def _execute_avatar_bubble_show(self, tool_call: ToolCall) -> ToolResult:
        text = str(tool_call.arguments.get("text") or "").strip()
        payload = {"type": "bubble_show", "text": text}
        return self._result(True, "avatar.bubble_show", tool_call.arguments, bubble_text=text or "Showing bubble.", console_text=f"Avatar bubble event prepared:\n- text: {text}", event_payload=payload)

    def _execute_avatar_emotion_hint(self, tool_call: ToolCall) -> ToolResult:
        emotion = str(tool_call.arguments.get("emotion") or "").strip() or "neutral"
        payload = {"type": "emotion_hint", "emotion": emotion}
        return self._result(True, "avatar.emotion_hint", tool_call.arguments, bubble_text=f"Showing emotion {emotion}.", console_text=f"Avatar emotion event prepared:\n- emotion: {emotion}", event_payload=payload)

    def _execute_macos_permissions_check(self, tool_call: ToolCall) -> ToolResult:
        result = check_macos_permissions()
        return self._result(True, "macos.permissions_check", tool_call.arguments, bubble_text="Checking macOS permissions.", console_text=format_permissions_report(result), event_payload=result.to_dict())

    def _execute_macos_observe_frontmost(self, tool_call: ToolCall) -> ToolResult:
        result = MacOSControl().snapshot()
        success = bool(result.ok)
        observation = result.observation.to_dict() if result.observation is not None else None
        bubble = "Checking the active app." if success else "I could not check the active app."
        console = (
            f"Observed macOS:\n- app_name: {result.observation.app_name or 'unknown'}\n- window_title: {result.observation.window_title or 'unknown'}"
            if success and result.observation is not None
            else f"macOS observe failed:\n- error: {(result.error or {}).get('message', 'unknown error')}"
        )
        return self._result(success, "macos.observe_frontmost", tool_call.arguments, bubble_text=bubble, console_text=console, event_payload=observation, error=None if success else (result.error or {}).get("message"))

    def _execute_macos_visible_windows(self, tool_call: ToolCall) -> ToolResult:
        result = probe_visible_windows()
        return self._result(result.ok, "macos.visible_windows", tool_call.arguments, bubble_text="Checking visible windows.", console_text=format_window_report(result), event_payload=result.to_dict(), error=None if result.ok else str((result.error or {}).get("message", "window probe failed")))

    def _execute_macos_list_apps(self, tool_call: ToolCall) -> ToolResult:
        apps = list_known_applications()
        console = "Known macOS apps:\n- " + "\n- ".join(apps)
        return self._result(True, "macos.list_apps", tool_call.arguments, bubble_text="Checking available apps.", console_text=console, event_payload={"known_apps": apps})

    def _execute_macos_open_app(self, tool_call: ToolCall) -> ToolResult:
        app_name = str(tool_call.arguments.get("app_name") or "").strip()
        result = MacOSControl().open_application(app_name)
        success = bool(result.ok)
        bubble = f"Opening {app_name}." if success else f"I could not open {app_name}."
        console = (
            f"Open app:\n- app_name: {app_name}\n- status: ok"
            if success
            else f"Open app failed:\n- app_name: {app_name}\n- error: {(result.error or {}).get('message', 'unknown error')}"
        )
        return self._result(success, "macos.open_app", tool_call.arguments, bubble_text=bubble, console_text=console, event_payload=result.to_dict(), error=None if success else (result.error or {}).get("message"))

    def _execute_window_native_tiling(self, tool_call: ToolCall) -> ToolResult:
        action = str(tool_call.arguments.get("action") or "").strip().lower()
        result = NativeWindowTiling().apply(action)
        bubble = _WINDOW_BUBBLE_TEXT.get(action, "Moving this window.")
        if not result.success:
            bubble = "I could not rearrange that window."
        return self._result(result.success, "window.native_tiling", tool_call.arguments, bubble_text=bubble, console_text=format_native_tiling_result(result), event_payload=result.to_dict(), error=result.reason if not result.success else None)

    def _execute_layout_status(self, tool_call: ToolCall) -> ToolResult:
        manager = LayoutManager()
        state = manager.status()
        return self._result(True, "layout.status", tool_call.arguments, bubble_text="Checking layout status.", console_text=manager.format_status(state), event_payload=state.to_dict())

    def _execute_layout_preview(self, tool_call: ToolCall) -> ToolResult:
        manager = LayoutManager()
        plan = manager.preview()
        return self._result(True, "layout.preview", tool_call.arguments, bubble_text="Preparing layout preview.", console_text=manager.format_preview(plan), event_payload=plan.to_dict())

    def _execute_layout_split(self, tool_call: ToolCall) -> ToolResult:
        manager = LayoutManager()
        plan = manager.split()
        return self._result(True, "layout.split", tool_call.arguments, bubble_text="Preparing split layout.", console_text=manager.format_plan(plan, title="Layout split"), event_payload=plan.to_dict())

    def _execute_layout_clear(self, tool_call: ToolCall) -> ToolResult:
        manager = LayoutManager()
        state = manager.clear()
        console = "Layout cleared.\n" + manager.format_status(state)
        return self._result(True, "layout.clear", tool_call.arguments, bubble_text="Clearing layout state.", console_text=console, event_payload=state.to_dict())

    def _execute_space_status(self, tool_call: ToolCall) -> ToolResult:
        result = SpaceControl().status()
        return self._result(result.success, "space.status", tool_call.arguments, bubble_text=_SPACE_BUBBLE_TEXT["space.status"], console_text=format_space_status_result(result), event_payload=result.to_dict(), error=result.reason if not result.success else None)

    def _execute_space_next(self, tool_call: ToolCall) -> ToolResult:
        result = SpaceControl().next_space()
        return self._result(result.success, "space.next", tool_call.arguments, bubble_text=_SPACE_BUBBLE_TEXT["space.next"] if result.success else "I could not switch desktops.", console_text=format_space_control_result(result), event_payload=result.to_dict(), error=result.reason if not result.success else None)

    def _execute_space_previous(self, tool_call: ToolCall) -> ToolResult:
        result = SpaceControl().previous_space()
        return self._result(result.success, "space.previous", tool_call.arguments, bubble_text=_SPACE_BUBBLE_TEXT["space.previous"] if result.success else "I could not return to the previous desktop.", console_text=format_space_control_result(result), event_payload=result.to_dict(), error=result.reason if not result.success else None)

    def _execute_space_mission_control(self, tool_call: ToolCall) -> ToolResult:
        result = SpaceControl().mission_control()
        return self._result(result.success, "space.mission_control", tool_call.arguments, bubble_text=_SPACE_BUBBLE_TEXT["space.mission_control"] if result.success else "I could not open Mission Control.", console_text=format_space_control_result(result), event_payload=result.to_dict(), error=result.reason if not result.success else None)

    def _execute_space_switch_desktop_number(self, tool_call: ToolCall) -> ToolResult:
        number = int(tool_call.arguments.get("number"))
        result = SpaceControl().switch_to_desktop(number)
        bubble = f"Switching to desktop {number}." if result.success else f"I could not switch to desktop {number}."
        return self._result(result.success, "space.switch_desktop_number", tool_call.arguments, bubble_text=bubble, console_text=format_space_control_result(result), event_payload=result.to_dict(), error=result.reason if not result.success else None)
