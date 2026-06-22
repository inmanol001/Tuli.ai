from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any, Dict, List, Mapping

from ..activity import ActivityWatcher
from ..config import TuliBrainConfig, load_config
from ..debug.debug_store import DebugStore
from ..layout import LayoutManager
from ..macos_control import MacOSControl, SpaceControl, check_macos_permissions, list_known_applications, probe_visible_windows
from ..memory.sqlite_memory import SQLiteMemoryStore


ROUTE_EVENT_TYPES = {
    "chat_reply",
    "tool_chain",
    "tool_chain_confirmation_required",
    "ai_router_chat",
    "ai_router_tool",
    "ai_router_clarify",
}


def _session_id() -> str:
    return os.environ.get("TULI_SESSION_ID", "local_session").strip() or "local_session"


def _support_dir_from_config(config: TuliBrainConfig) -> Path:
    return Path(config.event_stream_path).expanduser().parent


def _compact_debug_turns(items: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    compact: List[Dict[str, Any]] = []
    for item in items:
        if not isinstance(item, dict):
            continue
        error = item.get("error")
        compact.append(
            {
                "turn_id": item.get("turn_id"),
                "command": item.get("command"),
                "mode": item.get("mode"),
                "user_text": item.get("user_text"),
                "intent": item.get("intent"),
                "model_used": item.get("model_used"),
                "error": error if isinstance(error, Mapping) else None,
            }
        )
    return compact


def summarize_event_stream(event_stream_path: str | Path, *, recent_lines: int = 20) -> Dict[str, Any]:
    path = Path(event_stream_path).expanduser()
    latest_router = None
    latest_chat = None
    last_route = None
    recent_telemetry: List[Dict[str, Any]] = []
    recent_events: List[Dict[str, Any]] = []
    recent_errors: List[Dict[str, Any]] = []

    if not path.exists():
        return {
            "path": str(path),
            "exists": False,
            "latest_router": None,
            "latest_chat": None,
            "last_route": None,
            "recent_telemetry": [],
            "recent_events": [],
            "recent_errors": [],
        }

    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    for line in lines:
        if not line.strip():
            continue
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(payload, dict):
            continue
        event_type = str(payload.get("type") or "")
        if event_type == "token_context_update":
            role = str(payload.get("model_role") or "")
            if role == "router":
                latest_router = payload
            elif role == "chat":
                latest_chat = payload
            recent_telemetry.append(payload)
            if payload.get("phase") == "error" or payload.get("error"):
                recent_errors.append(payload)
            continue
        if event_type in ROUTE_EVENT_TYPES:
            last_route = event_type
        recent_events.append(payload)

    return {
        "path": str(path),
        "exists": True,
        "latest_router": latest_router,
        "latest_chat": latest_chat,
        "last_route": last_route,
        "recent_telemetry": recent_telemetry[-recent_lines:],
        "recent_events": recent_events[-recent_lines:],
        "recent_errors": recent_errors[-recent_lines:],
    }


def build_inspector_snapshot(
    config: TuliBrainConfig | None = None,
    *,
    recent_lines: int = 20,
    include_raw_paths: bool = False,
) -> Dict[str, Any]:
    cfg = config or load_config()
    store = SQLiteMemoryStore(cfg.memory_db_path)
    store.initialize()
    activity = ActivityWatcher(cfg.activity_store_path)
    controller = MacOSControl()
    permissions = check_macos_permissions()
    frontmost = controller.snapshot()
    windows = probe_visible_windows()
    apps = list_known_applications()
    layout_manager = LayoutManager()
    layout_state = layout_manager.status()
    spaces = SpaceControl().status()
    stream_summary = summarize_event_stream(cfg.event_stream_path, recent_lines=recent_lines)
    debug_tail = DebugStore(cfg.debug_store_path).tail(lines=recent_lines)
    latest_debug = debug_tail[-1] if debug_tail else {}
    compact_debug_turns = _compact_debug_turns(debug_tail)

    last_route = stream_summary.get("last_route")
    if not last_route and isinstance(latest_debug, dict):
        raw_response = latest_debug.get("raw_response")
        if isinstance(raw_response, str) and raw_response.strip():
            try:
                parsed = json.loads(raw_response)
            except json.JSONDecodeError:
                parsed = {}
            if isinstance(parsed, dict):
                command = parsed.get("command")
                if isinstance(command, dict):
                    command_type = command.get("type")
                    if isinstance(command_type, str) and command_type.strip():
                        last_route = command_type
        if not last_route:
            command_name = latest_debug.get("command")
            if isinstance(command_name, str) and command_name.strip():
                last_route = command_name

    support_dir = _support_dir_from_config(cfg)
    raw_paths = {
        "event_stream": cfg.event_stream_path,
        "debug_store": cfg.debug_store_path,
        "activity_store": cfg.activity_store_path,
        "memory_db": cfg.memory_db_path,
        "overlay_debug_log": str(support_dir / "overlay_debug.log"),
        "bridge_debug_log": str(support_dir / "bridge_debug.log"),
        "speech_trace_log": str(support_dir / "speech_trace.jsonl"),
    }

    return {
        "agent": {
            "active_model": cfg.ollama_model,
            "base_model": cfg.ollama_model,
            "router_model": cfg.router_model,
            "mode": latest_debug.get("mode") if isinstance(latest_debug, dict) else None,
            "session_id": _session_id(),
            "memory_counts": {
                "active": store.count(),
                "total": store.count(include_archived=True),
                "sessions": store.count_sessions(),
                "session_summaries": store.count_session_summaries(),
            },
            "paths": {
                "activity_store": cfg.activity_store_path,
                "event_stream": cfg.event_stream_path,
                "debug_store": cfg.debug_store_path,
            },
            "activity_summary": activity.summarize_recent(lines=min(recent_lines, 20)).to_dict(),
        },
        "permissions": permissions.to_dict(),
        "frontmost": frontmost.to_dict(),
        "windows": {
            "count": len(windows.windows),
            "result": windows.to_dict(),
        },
        "apps": {
            "count": len(apps),
            "known_apps": apps,
        },
        "layout": {
            "state": layout_state.to_dict(),
            "summary": layout_manager.format_status(layout_state),
        },
        "spaces": spaces.to_dict(),
        "llm": {
            "router": stream_summary.get("latest_router"),
            "chat": stream_summary.get("latest_chat"),
            "budgets": {
                "router": {
                    "model": cfg.router_model,
                    "num_ctx": cfg.router_num_ctx,
                    "num_predict": cfg.router_num_predict,
                    "keep_alive": cfg.ollama_keep_alive,
                },
                "chat": {
                    "model": cfg.ollama_model,
                    "num_ctx": cfg.chat_num_ctx,
                    "num_predict": cfg.chat_num_predict,
                    "keep_alive": cfg.ollama_keep_alive,
                },
            },
        },
        "recent": {
            "last_route": last_route,
            "events": stream_summary.get("recent_events", []),
            "telemetry": stream_summary.get("recent_telemetry", []),
            "errors": stream_summary.get("recent_errors", []),
            "debug_turns": compact_debug_turns,
        },
        "raw": {"paths": raw_paths if include_raw_paths else {}},
    }
