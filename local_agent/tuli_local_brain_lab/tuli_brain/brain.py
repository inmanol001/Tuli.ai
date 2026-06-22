from __future__ import annotations

import json
import os
import uuid
from typing import Any, Dict, List, Optional, Tuple

from .actions import emit_response_events_with_turn, route_response_actions
from .commands import DEFAULT_COMMAND_REGISTRY, route_user_text
from .activity import ActivityWatcher
from .config import load_config
from .debug import DebugStore, make_debug_snapshot
from .intents import ActionPlanner, IntentResolver
from .intents.intent_types import IntentResult
from .macos_control import MacOSControl, NativeWindowTiling, SpaceControl, format_native_tiling_result, format_space_control_result, format_space_status_result, list_known_applications
from .macos_control.mac_window_probe import format_window_report, probe_visible_windows
from .macos_control.permissions_check import check_macos_permissions, format_permissions_report
from .layout import LayoutManager
from .memory.memory_policy import should_store_episodic_turn
from .memory.sqlite_memory import SQLiteMemoryStore
from .models import choose_model
from .persona.context_builder import build_context
from .schemas import make_action, validate_brain_response
from .providers.kokoro_local import KokoroLocalError, synthesize_speech
from .providers.ollama_local import OllamaLocalError, chat as ollama_chat
from .router import AIIntentRouter
from .tools import ToolExecutor


READY_EMOTION = "focused"
FALLBACK_TEXT = "I'm here, but my local model has not responded yet."
DEFAULT_SESSION_ID = "local_session"
MODE_PREFIX_COMMANDS = {"instant", "thinking"}
_LEGACY_WINDOW_BUBBLE_TEXT = {
    "right": "Moving this window to the right.",
    "left": "Moving this window to the left.",
    "fill": "Filling this window.",
    "quarters": "Arranging windows into quarters.",
}
_LEGACY_SPACE_BUBBLE_TEXT = {
    "next": "Switching to the next desktop.",
    "previous": "Returning to the previous desktop.",
    "mission-control": "Opening Mission Control.",
    "status": "Checking desktop spaces.",
}


def _turn_id() -> str:
    return "turn_" + uuid.uuid4().hex[:12]


def _trace_enabled(name: str) -> bool:
    return os.environ.get(name, "").strip() == "1" or os.environ.get("TULI_TRACE", "").strip() == "1"


def _trace_route(route_name: str) -> None:
    if _trace_enabled("TULI_TRACE"):
        print(f"route: {route_name}")


def _extract_mode_prefix(route_result) -> Tuple[Optional[str], str]:
    command_name = route_result.command_name
    args = list(route_result.parsed.command_args or ())
    if command_name in MODE_PREFIX_COMMANDS and args:
        effective_text = " ".join(args).strip()
        if effective_text:
            return command_name, effective_text
    return None, route_result.parsed.raw_text


def _resolve_open_app_name(route_result, activity_watcher: ActivityWatcher) -> Tuple[Optional[str], bool]:
    if route_result.command_name != "open":
        return None, False

    args = list(route_result.parsed.command_args or ())
    if args:
        app_name = " ".join(args).strip()
        if app_name.lower() in {"it", "the app", "app", "application"}:
            return None, False
        return app_name or None, False

    recent_app = activity_watcher.last_opened_app()
    if recent_app:
        return recent_app, True
    return None, False


def _legacy_bubble_text(command_name: str, args: List[str], *, default_text: str) -> str:
    lowered_args = [str(arg).strip().lower() for arg in args]
    if command_name == "help":
        return "Showing available commands."
    if command_name == "status":
        return "Tuli is active."
    if command_name == "permissions":
        return "Checking macOS permissions."
    if command_name == "windows":
        return "Checking visible windows."
    if command_name == "space":
        action = lowered_args[0] if lowered_args else "status"
        return _LEGACY_SPACE_BUBBLE_TEXT.get(action, default_text)
    if command_name == "window" and lowered_args[:1] == ["native"]:
        action = lowered_args[1] if len(lowered_args) > 1 else ""
        return _LEGACY_WINDOW_BUBBLE_TEXT.get(action, default_text)
    return default_text


def _layout_command_reply(
    route_result,
    *,
    layout_manager: LayoutManager,
) -> Optional[Tuple[str, str, List[Dict[str, Any]], Optional[Dict[str, Any]]]]:
    parsed = route_result.parsed
    if parsed.command_name != "layout":
        return None

    args = [str(arg).strip().lower() for arg in (parsed.command_args or ())]
    subcommand = args[0] if args else "status"

    if subcommand == "status":
        state = layout_manager.status()
        text = layout_manager.format_status(state)
        return (
            text,
            "focused",
            [make_action("bubble_show", text=text), make_action("emotion_hint", emotion="focused")],
            {"type": "layout", "confidence": parsed.confidence, "params": {"subcommand": subcommand, "state": state.to_dict()}},
        )

    if subcommand == "split":
        plan = layout_manager.split()
        text = layout_manager.format_plan(plan, title="Layout split")
        return (
            text,
            "focused",
            [make_action("bubble_show", text=text), make_action("emotion_hint", emotion="focused")],
            {"type": "layout", "confidence": parsed.confidence, "params": {"subcommand": subcommand, "plan": plan.to_dict()}},
        )

    if subcommand == "preview":
        plan = layout_manager.preview()
        text = layout_manager.format_preview(plan)
        return (
            text,
            "focused",
            [make_action("bubble_show", text=text), make_action("emotion_hint", emotion="focused")],
            {"type": "layout", "confidence": parsed.confidence, "params": {"subcommand": subcommand, "plan": plan.to_dict()}},
        )

    if subcommand == "clear":
        state = layout_manager.clear()
        text = "Layout cleared.\n" + layout_manager.format_status(state)
        return (
            text,
            "focused",
            [make_action("bubble_show", text=text), make_action("emotion_hint", emotion="focused")],
            {"type": "layout", "confidence": parsed.confidence, "params": {"subcommand": subcommand, "state": state.to_dict()}},
        )

    text = "Use /layout status, /layout split, /layout preview, or /layout clear."
    return (
        text,
        "thinking",
        [make_action("bubble_show", text=text), make_action("emotion_hint", emotion="thinking")],
        {"type": "layout", "confidence": parsed.confidence, "params": {"subcommand": subcommand, "error": "unknown_subcommand"}},
    )


def _native_window_command_reply(
    route_result,
) -> Optional[Tuple[str, str, List[Dict[str, Any]], Optional[Dict[str, Any]]]]:
    parsed = route_result.parsed
    command_name = parsed.command_name or ""
    args = [str(arg).strip().lower() for arg in (parsed.command_args or ())]

    if command_name == "window":
        if not args or args[0] != "native":
            text = "Use /window native fill, center, left, right, top, bottom, top-left, top-right, bottom-left, bottom-right, quarters, or return."
            return (
                text,
                "thinking",
                [make_action("bubble_show", text=text), make_action("emotion_hint", emotion="thinking")],
                {"type": "window", "confidence": parsed.confidence, "params": {"args": args, "error": "unknown_subcommand"}},
            )
        action = args[1] if len(args) > 1 else ""
    elif command_name == "layout" and args and args[0] == "native":
        action = args[1] if len(args) > 1 else ""
    else:
        return None

    controller = NativeWindowTiling()
    result = controller.apply(action)
    text = format_native_tiling_result(result)
    bubble_text = _LEGACY_WINDOW_BUBBLE_TEXT.get(action, text)
    emotion = "focused" if result.success else "worried"
    event_type = "native_tiling_result" if result.success else "native_tiling_failed"
    return (
        text,
        emotion,
        [make_action("bubble_show", text=bubble_text), make_action("emotion_hint", emotion=emotion)],
        {
            "type": event_type,
            "confidence": parsed.confidence,
            "params": {
                "command": command_name,
                "subcommand": "native",
                "action": action,
                "result": result.to_dict(),
                "bubble_text": bubble_text,
            },
        },
    )


def _space_command_reply(
    route_result,
) -> Optional[Tuple[str, str, List[Dict[str, Any]], Optional[Dict[str, Any]]]]:
    parsed = route_result.parsed
    if parsed.command_name != "space":
        return None

    args = [str(arg).strip().lower() for arg in (parsed.command_args or ())]
    action = args[0] if args else "status"
    controller = SpaceControl()

    if action in {"status", "estado"}:
        status = controller.status()
        text = format_space_status_result(status)
        bubble_text = _LEGACY_SPACE_BUBBLE_TEXT["status"]
        emotion = "focused" if status.success else "worried"
        return (
            text,
            emotion,
            [make_action("bubble_show", text=bubble_text), make_action("emotion_hint", emotion=emotion)],
            {"type": "space_status", "confidence": parsed.confidence, "params": {**status.to_dict(), "bubble_text": bubble_text}},
        )

    if action in {"next", "siguiente"}:
        result = controller.next_space()
    elif action in {"previous", "prev", "anterior"}:
        result = controller.previous_space()
    elif action in {"mission-control", "mission", "control"}:
        result = controller.mission_control()
        action = "mission-control"
    else:
        try:
            desktop_number = int(action)
        except ValueError:
            text = "Use /space next, /space previous, /space mission-control, /space status, or /space 1 through /space 4."
            return (
                text,
                "thinking",
                [make_action("bubble_show", text=text), make_action("emotion_hint", emotion="thinking")],
                {"type": "space", "confidence": parsed.confidence, "params": {"args": args, "error": "unknown_subcommand"}},
            )
        result = controller.switch_to_desktop(desktop_number)

    text = format_space_control_result(result)
    bubble_text = _LEGACY_SPACE_BUBBLE_TEXT.get(action, text)
    emotion = "focused" if result.success else "worried"
    event_type = "space_control_result" if result.success else "space_control_failed"
    return (
        text,
        emotion,
        [make_action("bubble_show", text=bubble_text), make_action("emotion_hint", emotion=emotion)],
        {"type": event_type, "confidence": parsed.confidence, "params": {"action": action, "result": result.to_dict(), "bubble_text": bubble_text}},
    )


def _try_tool_chain_reply(
    user_text: str,
    *,
    config,
    memory_store: SQLiteMemoryStore,
    activity_watcher: ActivityWatcher,
    selected_model: str,
) -> Optional[Tuple[str, str, List[Dict[str, Any]], Optional[Dict[str, Any]]]]:
    if not isinstance(user_text, str) or not user_text.strip():
        return None
    if user_text.lstrip().startswith("/"):
        return None

    intent = IntentResolver().resolve(user_text)
    planner = ActionPlanner()
    plan = planner.plan(intent)

    def build_tool_result_reply(
        tool_result,
        *,
        confidence: float,
        intent_name: str,
        metadata: Dict[str, Any],
        route_source: str,
    ) -> Tuple[str, str, List[Dict[str, Any]], Optional[Dict[str, Any]]]:
        bubble_text = tool_result.bubble_text or plan.bubble_text or tool_result.console_text or tool_result.result_text
        response_text = tool_result.console_text or tool_result.result_text or bubble_text
        response_emotion = "focused" if tool_result.success else "worried"
        actions: List[Dict[str, Any]] = []
        if bubble_text:
            actions.append(make_action("bubble_show", text=bubble_text))
        actions.append(make_action("emotion_hint", emotion=response_emotion))
        event_payload = tool_result.event_payload or {}
        if isinstance(event_payload, dict) and event_payload.get("type") in {"bubble_show", "emotion_hint"}:
            actions.append(dict(event_payload))
        return (
            response_text,
            response_emotion,
            actions,
            {
                "type": "tool_chain",
                "confidence": confidence,
                "params": {
                    "tool_name": tool_result.tool_name,
                    "arguments": dict(tool_result.arguments),
                    "success": tool_result.success,
                    "bubble_text": bubble_text,
                    "console_text": tool_result.console_text,
                    "intent_name": intent_name,
                    "metadata": metadata,
                    "error": tool_result.error,
                    "route_source": route_source,
                },
            },
        )

    if plan.should_execute and plan.tool_call is not None:
        _trace_route("deterministic_tool_chain")
        tool_result = ToolExecutor().execute(plan.tool_call)
        return build_tool_result_reply(
            tool_result,
            confidence=intent.confidence,
            intent_name=intent.intent_name,
            metadata=intent.to_dict(),
            route_source="deterministic",
        )

    if plan.reason == "requires_confirmation":
        _trace_route("deterministic_tool_chain")
        response_text = plan.console_text or "This action requires confirmation."
        bubble_text = plan.bubble_text or "I need confirmation before doing that."
        return (
            response_text,
            "worried",
            [make_action("bubble_show", text=bubble_text), make_action("emotion_hint", emotion="worried")],
            {
                "type": "tool_chain_confirmation_required",
                "confidence": intent.confidence,
                "params": {
                    "tool_name": intent.tool_name,
                    "arguments": dict(intent.arguments),
                    "success": False,
                    "bubble_text": bubble_text,
                    "console_text": response_text,
                    "intent_name": intent.intent_name,
                    "metadata": intent.to_dict(),
                    "error": intent.error,
                },
            },
        )

    if plan.reason in {"low_confidence", "tool_not_found"}:
        router = AIIntentRouter()
        router_decision = router.validate_decision(router.route(user_text, config))
        if router_decision.route == "tool":
            router_intent = IntentResult(
                intent_name="ai_router_tool",
                tool_name=router_decision.tool_name,
                arguments=dict(router_decision.arguments),
                confidence=router_decision.confidence,
                source_text=user_text,
                bubble_text="",
                response_text="",
                metadata={"router": router_decision.to_dict()},
                error=router_decision.error,
            )
            router_plan = ActionPlanner().plan(router_intent)
            if router_plan.should_execute and router_plan.tool_call is not None:
                _trace_route("ai_router_tool")
                tool_result = ToolExecutor().execute(router_plan.tool_call)
                return build_tool_result_reply(
                    tool_result,
                    confidence=router_decision.confidence,
                    intent_name=router_intent.intent_name,
                    metadata=router_decision.to_dict(),
                    route_source="ai_router",
                )
            if router_plan.reason == "requires_confirmation":
                _trace_route("ai_router_clarify")
                response_text = router_plan.console_text or "This action requires confirmation."
                bubble_text = router_plan.bubble_text or "I need confirmation before doing that."
                return (
                    response_text,
                    "worried",
                    [make_action("bubble_show", text=bubble_text), make_action("emotion_hint", emotion="worried")],
                    {
                        "type": "tool_chain_confirmation_required",
                        "confidence": router_decision.confidence,
                        "params": {
                            "tool_name": router_decision.tool_name,
                            "arguments": dict(router_decision.arguments),
                            "success": False,
                            "bubble_text": bubble_text,
                            "console_text": response_text,
                            "intent_name": "ai_router_tool",
                            "metadata": router_decision.to_dict(),
                            "error": router_decision.error,
                            "route_source": "ai_router",
                        },
                    },
                )
            _trace_route("ai_router_clarify")
            clarification = router_decision.clarification or "I understood this as an action, but I need a clearer command."
            return (
                clarification,
                "thinking",
                [make_action("bubble_show", text=clarification), make_action("emotion_hint", emotion="thinking")],
                {
                    "type": "ai_router_clarify",
                    "confidence": router_decision.confidence,
                    "params": {
                        "tool_name": router_decision.tool_name,
                        "arguments": dict(router_decision.arguments),
                        "success": False,
                        "bubble_text": clarification,
                        "console_text": clarification,
                        "metadata": router_decision.to_dict(),
                        "error": router_plan.reason,
                    },
                },
            )
        if router_decision.route == "clarify":
            _trace_route("ai_router_clarify")
            clarification = router_decision.clarification or "I understood this as an action, but I need a clearer command."
            return (
                clarification,
                "thinking",
                [make_action("bubble_show", text=clarification), make_action("emotion_hint", emotion="thinking")],
                {
                    "type": "ai_router_clarify",
                    "confidence": router_decision.confidence,
                    "params": {
                        "tool_name": router_decision.tool_name,
                        "arguments": dict(router_decision.arguments),
                        "success": False,
                        "bubble_text": clarification,
                        "console_text": clarification,
                        "metadata": router_decision.to_dict(),
                        "error": router_decision.error,
                    },
                },
            )
        _trace_route("ai_router_chat")
        return None

    return None


def _local_command_reply(
    route_result,
    *,
    config,
    memory_store: SQLiteMemoryStore,
    selected_model: str,
    resolved_open_app_name: Optional[str] = None,
    resolved_open_from_reference: bool = False,
) -> Optional[Tuple[str, str, List[Dict[str, Any]], Optional[Dict[str, Any]]]]:
    parsed = route_result.parsed
    command_name = parsed.command_name or ""
    args = list(parsed.command_args or ())

    if route_result.permission.status == "deny":
        text = "No puedo ejecutar esa orden."
        return text, "worried", [make_action("bubble_show", text=text), make_action("emotion_hint", emotion="worried")], {"type": command_name or "chat_reply", "confidence": parsed.confidence, "params": {"args": args, "status": "denied"}}

    if route_result.permission.status == "confirm":
        text = "I need confirmation before proceeding with that."
        return text, "worried", [make_action("bubble_show", text=text), make_action("emotion_hint", emotion="worried")], {"type": command_name or "chat_reply", "confidence": parsed.confidence, "params": {"args": args, "status": "confirm"}}

    if command_name == "help":
        text = "Available commands:\n" + "\n".join(DEFAULT_COMMAND_REGISTRY.help_text())
        bubble_text = _legacy_bubble_text(command_name, args, default_text=text)
        return text, "neutral", [make_action("bubble_show", text=bubble_text), make_action("emotion_hint", emotion="neutral")], {"type": "help", "confidence": parsed.confidence, "params": {"commands": [spec.name for spec in DEFAULT_COMMAND_REGISTRY.list()], "bubble_text": bubble_text}}

    if command_name == "status":
        text = (
            f"Tuli local is active. Base model: {config.ollama_model}. "
            f"Current model: {selected_model}. "
            f"Active memories: {memory_store.count()}. "
            f"Active sessions: {memory_store.count_sessions()}."
        )
        bubble_text = _legacy_bubble_text(command_name, args, default_text=text)
        return text, "focused", [make_action("bubble_show", text=bubble_text), make_action("emotion_hint", emotion="focused")], {"type": "status", "confidence": parsed.confidence, "params": {"model": selected_model, "bubble_text": bubble_text}}

    if command_name == "debug":
        text = f"Local debug is available at {config.debug_store_path}. Events are stored at {config.event_stream_path}."
        return text, "focused", [make_action("bubble_show", text=text), make_action("emotion_hint", emotion="focused")], {"type": "debug", "confidence": parsed.confidence, "params": {"debug_store_path": config.debug_store_path, "event_stream_path": config.event_stream_path}}

    if command_name == "instant":
        text = "Instant mode enabled."
        return text, "focused", [make_action("bubble_show", text=text), make_action("emotion_hint", emotion="focused")], {"type": "instant", "confidence": parsed.confidence, "params": {}}

    if command_name == "thinking":
        text = "Thinking mode enabled."
        return text, "thinking", [make_action("bubble_show", text=text), make_action("emotion_hint", emotion="thinking")], {"type": "thinking", "confidence": parsed.confidence, "params": {}}

    if command_name == "speak":
        voice_state = args[0].lower() if args else "on"
        if voice_state in {"off", "false", "0", "no", "mute"}:
            text = "Voice is disabled for this turn."
        elif voice_state in {"on", "true", "1", "si", "sí"}:
            text = "Voice is enabled for this turn."
        else:
            text = f"Current local voice: {config.kokoro_voice}."
        return text, "neutral", [make_action("bubble_show", text=text), make_action("emotion_hint", emotion="neutral")], {"type": "speak", "confidence": parsed.confidence, "params": {"args": args}}

    if command_name == "model":
        requested_model = args[0] if args else ""
        if requested_model:
            text = f"Modelo pedido: {requested_model}. Modelo usado: {selected_model}."
        else:
            text = f"Modelo usado ahora: {selected_model}."
        return text, "focused", [make_action("bubble_show", text=text), make_action("emotion_hint", emotion="focused")], {"type": "model", "confidence": parsed.confidence, "params": {"requested_model": requested_model, "selected_model": selected_model}}

    if command_name == "memory":
        text = (
            f"Active memories: {memory_store.count()}. "
            f"Sessions: {memory_store.count_sessions()}. "
            f"Summaries: {memory_store.count_session_summaries()}."
        )
        return text, "focused", [make_action("bubble_show", text=text), make_action("emotion_hint", emotion="focused")], {"type": "memory", "confidence": parsed.confidence, "params": {}}

    if command_name == "macos":
        controller = MacOSControl()
        snapshot = controller.snapshot()
        if snapshot.ok and snapshot.observation is not None:
            observation = snapshot.observation.to_dict()
            window_title = observation.get("window_title")
            window_suffix = f" - {window_title}" if window_title else ""
            text = (
                f"Observed macOS: {observation.get('app_name') or 'unknown'}"
                f"{window_suffix}."
            )
            return (
                text,
                "focused",
                [make_action("bubble_show", text=text), make_action("emotion_hint", emotion="focused")],
                {"type": "macos", "confidence": parsed.confidence, "params": {"observation": observation}},
            )
        text = "I could not observe macOS right now."
        return (
            text,
            "worried",
            [make_action("bubble_show", text=text), make_action("emotion_hint", emotion="worried")],
            {"type": "macos", "confidence": parsed.confidence, "params": {"error": snapshot.error}},
        )

    if command_name == "apps":
        known_apps = list_known_applications()
        preview = ", ".join(known_apps[:18])
        extra = "" if len(known_apps) <= 18 else f" ... and {len(known_apps) - 18} more."
        text = (
            "I can try opening any installed macOS app by name. "
            f"Known apps: {preview}{extra}"
        )
        return (
            text,
            "focused",
            [make_action("bubble_show", text=text), make_action("emotion_hint", emotion="focused")],
            {"type": "apps", "confidence": parsed.confidence, "params": {"known_apps": known_apps, "open_any_installed_app": True}},
        )

    if command_name == "permissions":
        permissions = check_macos_permissions()
        text = format_permissions_report(permissions)
        bubble_text = _legacy_bubble_text(command_name, args, default_text=text)
        return (
            text,
            "focused",
            [make_action("bubble_show", text=bubble_text), make_action("emotion_hint", emotion="focused")],
            {"type": "permissions", "confidence": parsed.confidence, "params": {**permissions.to_dict(), "bubble_text": bubble_text}},
        )

    if command_name == "windows":
        probe = probe_visible_windows()
        text = format_window_report(probe)
        bubble_text = _legacy_bubble_text(command_name, args, default_text=text)
        emotion = "focused" if probe.ok else "worried"
        return (
            text,
            emotion,
            [make_action("bubble_show", text=bubble_text), make_action("emotion_hint", emotion=emotion)],
            {"type": "windows", "confidence": parsed.confidence, "params": {**probe.to_dict(), "bubble_text": bubble_text}},
        )

    space_reply = _space_command_reply(route_result)
    if space_reply is not None:
        return space_reply

    native_window_reply = _native_window_command_reply(route_result)
    if native_window_reply is not None:
        return native_window_reply

    if command_name == "layout":
        layout_reply = _layout_command_reply(route_result, layout_manager=LayoutManager())
        if layout_reply is not None:
            return layout_reply

    if command_name == "open":
        app_name = resolved_open_app_name or " ".join(args).strip()
        if not app_name:
            text = "Tell me which app you want me to open, for example Safari or Notes."
            return text, "thinking", [make_action("bubble_show", text=text), make_action("emotion_hint", emotion="thinking")], {"type": "open", "confidence": parsed.confidence, "params": {"args": args, "status": "missing_app"}}

        controller = MacOSControl()
        result = controller.open_application(app_name)
        if result.ok:
            opened_name = result.observation.app_name if result.observation and result.observation.app_name else app_name
            text = f"Opening {opened_name}."
            return (
                text,
                "focused",
                [make_action("bubble_show", text=text), make_action("emotion_hint", emotion="focused")],
                {
                    "type": "open",
                    "confidence": parsed.confidence,
                    "params": {
                        "app_name": app_name,
                        "opened": True,
                        "resolved_from_reference": resolved_open_from_reference,
                        "observation": result.observation.to_dict() if result.observation is not None else None,
                    },
                },
            )

        text = f"I could not open {app_name}."
        return (
            text,
            "worried",
            [make_action("bubble_show", text=text), make_action("emotion_hint", emotion="worried")],
            {
                "type": "open",
                "confidence": parsed.confidence,
                "params": {
                    "app_name": app_name,
                    "opened": False,
                    "resolved_from_reference": resolved_open_from_reference,
                    "error": result.error,
                },
            },
        )

    if command_name in {"remember", "forget", "summarize", "clear", "pause", "resume", "export"}:
        text = "That command is detected, but the full execution flow is still being prepared."
        return text, "thinking", [make_action("bubble_show", text=text), make_action("emotion_hint", emotion="thinking")], {"type": command_name, "confidence": parsed.confidence, "params": {"args": args}}

    return None


def respond(user_text: str, speak: bool = False) -> dict:
    if not isinstance(user_text, str):
        raise TypeError("user_text must be a string")
    if not user_text.strip():
        raise ValueError("user_text must not be empty")

    config = load_config()
    memory_store = SQLiteMemoryStore(config.memory_db_path)
    memory_store.initialize()
    activity_watcher = ActivityWatcher(config.activity_store_path)
    session_id = os.environ.get("TULI_SESSION_ID", DEFAULT_SESSION_ID).strip() or DEFAULT_SESSION_ID
    turn_id = _turn_id()
    is_slash_command = user_text.lstrip().startswith("/")
    route_result = route_user_text(user_text, registry=DEFAULT_COMMAND_REGISTRY)
    mode_prefix, effective_user_text = _extract_mode_prefix(route_result)
    processing_route_result = (
        route_user_text(effective_user_text, registry=DEFAULT_COMMAND_REGISTRY)
        if mode_prefix is not None
        else route_result
    )
    selected_model = config.ollama_model

    if processing_route_result.command_name == "model" and processing_route_result.parsed.command_args:
        requested_model = processing_route_result.parsed.command_args[0]
    else:
        requested_model = None

    model_route = choose_model(
        command_name=processing_route_result.command_name,
        route=processing_route_result.routing.route,
        mode=mode_prefix or processing_route_result.mode.resolved_mode,
        parsed=processing_route_result.parsed,
        requested_model=requested_model,
    )
    selected_model = model_route.model.resolved_model

    prompt_context = build_context(effective_user_text, memory_store, activity_watcher=activity_watcher)
    prompt_final = prompt_context.system_prompt
    resolved_open_app_name, resolved_open_from_reference = _resolve_open_app_name(route_result, activity_watcher)

    response_text = ""
    response_emotion = READY_EMOTION
    actions: List[Dict[str, Any]] = []
    error_message = ""
    command_reply = None
    prefers_legacy_open_reply = (
        mode_prefix is None
        and not is_slash_command
        and route_result.command_name == "open"
        and (resolved_open_app_name is not None or resolved_open_from_reference)
        and "navegador" not in effective_user_text.lower()
        and "browser" not in effective_user_text.lower()
    )

    if prefers_legacy_open_reply:
        command_reply = _local_command_reply(
            processing_route_result,
            config=config,
            memory_store=memory_store,
            selected_model=selected_model,
            resolved_open_app_name=resolved_open_app_name,
            resolved_open_from_reference=resolved_open_from_reference,
        )

    if command_reply is None and mode_prefix is None and not is_slash_command:
        command_reply = _try_tool_chain_reply(
            effective_user_text,
            config=config,
            memory_store=memory_store,
            activity_watcher=activity_watcher,
            selected_model=selected_model,
        )

    if command_reply is None and mode_prefix is None and is_slash_command:
        _trace_route("slash_command")
        command_reply = _local_command_reply(
            processing_route_result,
            config=config,
            memory_store=memory_store,
            selected_model=selected_model,
            resolved_open_app_name=resolved_open_app_name,
            resolved_open_from_reference=resolved_open_from_reference,
        )

    if command_reply is not None:
        response_text, response_emotion, actions, command_payload = command_reply
    else:
        command_payload = {
            "type": "chat_reply",
            "confidence": processing_route_result.parsed.confidence,
            "params": {
                "route": processing_route_result.routing.route,
                "args": list(processing_route_result.parsed.command_args),
                "mode_prefix": mode_prefix,
                "effective_user_text": effective_user_text,
            },
        }
        try:
            model_result = ollama_chat(effective_user_text, config, system_prompt=prompt_final, model=selected_model)
            response_text = model_result.text
            response_emotion = READY_EMOTION if (mode_prefix or processing_route_result.mode.resolved_mode) != "thinking" else "thinking"
        except OllamaLocalError as exc:
            response_text = FALLBACK_TEXT
            response_emotion = "worried"
            error_message = str(exc)
        actions = [
            make_action("bubble_show", text=response_text),
            make_action("emotion_hint", emotion=response_emotion),
        ]

    if speak:
        try:
            speech = synthesize_speech(response_text, config)
            actions.append(
                make_action(
                    "speech_start",
                    text=response_text,
                    voice=speech.voice,
                    audio_path=speech.audio_path,
                    response_format=speech.response_format,
                    bytes_written=speech.bytes_written,
                )
            )
            actions.append(
                make_action(
                    "speech_end",
                    voice=speech.voice,
                    audio_path=speech.audio_path,
                    response_format=speech.response_format,
                    bytes_written=speech.bytes_written,
                )
            )
        except KokoroLocalError as exc:
            actions.append(make_action("error", message=str(exc)))

    if error_message:
        actions.append(make_action("error", message=error_message))

    response = validate_brain_response(
        {
            "text": response_text,
            "emotion": response_emotion,
            "speak": bool(speak),
            "voice": config.kokoro_voice,
            "actions": actions,
            "command": command_payload,
            "meta": {
                "session_id": session_id,
                "turn_id": turn_id,
                "model_used": selected_model,
                "provider": model_route.model.provider,
                "route": route_result.routing.route,
                "mode": route_result.mode.resolved_mode,
                "permission": route_result.permission.to_dict(),
            },
            "error": {"message": error_message, "source": "ollama_local"} if error_message else None,
        }
    )

    memory_store.upsert_session(
        session_id,
        source="brain.respond",
        last_user_text=effective_user_text,
        last_assistant_text=response_text,
        count_turn=False,
    )

    turn_write_result = None
    if not error_message and should_store_episodic_turn(effective_user_text, response_text):
        turn_write_result = memory_store.record_turn(
            session_id=session_id,
            user_text=effective_user_text,
            assistant_text=response_text,
            source="brain.respond",
            importance=0.45,
            confidence=0.8,
            tags=["turn", "chat"],
        )
    memory_store.save_session_summary(
        session_id,
        text=f"Latest turn -> User: {effective_user_text.strip()} | Tuli: {response_text.strip()}",
        source="brain.respond",
        memory_ids=(turn_write_result.item_id,) if turn_write_result and turn_write_result.item_id else (),
    )
    activity_watcher.record_turn(
        user_text=user_text,
        response_text=response_text,
        turn_id=turn_id,
        command_name=route_result.command_name or "chat_reply",
        route=route_result.routing.route,
        model_used=selected_model,
        mode=route_result.mode.resolved_mode,
        app_name=resolved_open_app_name if route_result.command_name == "open" else None,
        metadata={"resolved_open_reference": resolved_open_from_reference} if route_result.command_name == "open" else None,
    )

    action_route = route_response_actions(response, turn_id=turn_id)
    emit_result = emit_response_events_with_turn(response, config.event_stream_path, turn_id=turn_id)
    debug_store = DebugStore(config.debug_store_path)
    debug_store.write_snapshot(
        make_debug_snapshot(
            session_id=session_id,
            turn_id=turn_id,
            user_text=user_text,
            intent=processing_route_result.parsed.command_kind,
            command=processing_route_result.command_name or "chat_reply",
            risk=processing_route_result.routing.risk,
            requires_confirmation=processing_route_result.requires_confirmation,
            mode=mode_prefix or processing_route_result.mode.resolved_mode,
            model_used=selected_model,
            prompt_final=prompt_final,
            raw_response=json.dumps({"text": response_text, "actions": actions, "command": command_payload, "mode_prefix": mode_prefix}, ensure_ascii=False),
            clean_response=json.dumps(response, ensure_ascii=False),
            actions=actions,
            events=[str(event_id) for event_id in emit_result.event_ids],
            error={"message": error_message, "source": "ollama_local"} if error_message else None,
        )
    )
    response["action_route"] = action_route.to_dict()
    response["_emit"] = emit_result.to_dict()
    return response
