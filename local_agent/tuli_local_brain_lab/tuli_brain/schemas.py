from __future__ import annotations

from copy import deepcopy
from typing import Any, Dict, Iterable, List


VALID_EMOTIONS = frozenset({"happy", "thinking", "worried", "focused", "neutral"})
VALID_ACTION_TYPES = frozenset(
    {
        "bubble_show",
        "bubble_update",
        "emotion_hint",
        "voice_request",
        "voice_started",
        "voice_finished",
        "speech_start",
        "speech_end",
        "memory_store_fact",
        "memory_store_summary",
        "debug_snapshot",
        "activity_note",
        "status_update",
        "error",
    }
)


class SchemaValidationError(ValueError):
    """Raised when a local Tuli brain payload does not match the v1 contract."""


def _require_dict(value: Any, label: str) -> Dict[str, Any]:
    if not isinstance(value, dict):
        raise SchemaValidationError(f"{label} must be a dict")
    return value


def _require_string(value: Any, label: str, *, allow_empty: bool = False) -> str:
    if not isinstance(value, str):
        raise SchemaValidationError(f"{label} must be a string")
    if not allow_empty and not value.strip():
        raise SchemaValidationError(f"{label} must not be empty")
    return value


def _require_bool(value: Any, label: str) -> bool:
    if not isinstance(value, bool):
        raise SchemaValidationError(f"{label} must be a bool")
    return value


def _validate_action(action: Dict[str, Any]) -> Dict[str, Any]:
    action_type = _require_string(action.get("type"), "action.type")
    if action_type not in VALID_ACTION_TYPES:
        allowed = ", ".join(sorted(VALID_ACTION_TYPES))
        raise SchemaValidationError(f"action.type must be one of: {allowed}")

    if action_type in {"bubble_show", "bubble_update", "speech_start"}:
        _require_string(action.get("text"), f"{action_type}.text")
    elif action_type == "emotion_hint":
        emotion = _require_string(action.get("emotion"), "emotion_hint.emotion")
        if emotion not in VALID_EMOTIONS:
            allowed = ", ".join(sorted(VALID_EMOTIONS))
            raise SchemaValidationError(f"emotion_hint.emotion must be one of: {allowed}")
    elif action_type in {"voice_request", "voice_started", "voice_finished"}:
        _require_string(action.get("voice"), f"{action_type}.voice")
    elif action_type in {"memory_store_fact", "memory_store_summary"}:
        _require_string(action.get("text"), f"{action_type}.text")
    elif action_type == "debug_snapshot":
        _require_string(action.get("session_id"), "debug_snapshot.session_id")
    elif action_type == "activity_note":
        _require_string(action.get("text"), "activity_note.text")
    elif action_type == "status_update":
        _require_string(action.get("text"), "status_update.text")
    elif action_type == "error":
        _require_string(action.get("message"), "error.message")

    return action


def make_action(type: str, **payload: Any) -> Dict[str, Any]:
    action = {"type": type}
    action.update(payload)
    return _validate_action(action)


def _validate_actions(actions: Any) -> List[Dict[str, Any]]:
    if not isinstance(actions, list):
        raise SchemaValidationError("actions must be a list")
    return [_validate_action(_require_dict(action, "action")) for action in actions]


def validate_brain_response(response: dict) -> dict:
    payload = deepcopy(_require_dict(response, "response"))

    _require_string(payload.get("text"), "text")
    emotion = _require_string(payload.get("emotion"), "emotion")
    if emotion not in VALID_EMOTIONS:
        allowed = ", ".join(sorted(VALID_EMOTIONS))
        raise SchemaValidationError(f"emotion must be one of: {allowed}")

    _require_bool(payload.get("speak"), "speak")
    _require_string(payload.get("voice"), "voice")
    payload["actions"] = _validate_actions(payload.get("actions"))

    return payload


def valid_emotions() -> Iterable[str]:
    return tuple(sorted(VALID_EMOTIONS))


def valid_action_types() -> Iterable[str]:
    return tuple(sorted(VALID_ACTION_TYPES))
