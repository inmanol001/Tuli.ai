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
from .macos_control import MacOSControl, list_known_applications
from .memory.memory_policy import should_store_episodic_turn
from .memory.sqlite_memory import SQLiteMemoryStore
from .models import choose_model
from .persona.context_builder import build_context
from .schemas import make_action, validate_brain_response
from .providers.kokoro_local import KokoroLocalError, synthesize_speech
from .providers.ollama_local import OllamaLocalError, chat as ollama_chat


READY_EMOTION = "focused"
FALLBACK_TEXT = "I'm here, but my local model has not responded yet."
DEFAULT_SESSION_ID = "local_session"
MODE_PREFIX_COMMANDS = {"instant", "thinking"}


def _turn_id() -> str:
    return "turn_" + uuid.uuid4().hex[:12]


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
        return app_name or None, False

    recent_app = activity_watcher.last_opened_app()
    if recent_app:
        return recent_app, True
    return None, False


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
        return text, "neutral", [make_action("bubble_show", text=text), make_action("emotion_hint", emotion="neutral")], {"type": "help", "confidence": parsed.confidence, "params": {"commands": [spec.name for spec in DEFAULT_COMMAND_REGISTRY.list()]}}

    if command_name == "status":
        text = (
            f"Tuli local is active. Base model: {config.ollama_model}. "
            f"Current model: {selected_model}. "
            f"Active memories: {memory_store.count()}. "
            f"Active sessions: {memory_store.count_sessions()}."
        )
        return text, "focused", [make_action("bubble_show", text=text), make_action("emotion_hint", emotion="focused")], {"type": "status", "confidence": parsed.confidence, "params": {"model": selected_model}}

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
    command_reply = None if mode_prefix is not None else _local_command_reply(
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
