from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Any, Dict, List, Mapping, Optional, Tuple

from ..schemas import SchemaValidationError, validate_brain_response
from .action_types import ACTION_TYPES, ActionRequest, ActionResult


ROUTABLE_ACTION_TYPES = frozenset(
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

LOCAL_SAFE_ACTIONS = frozenset(
    {
        "bubble_show",
        "bubble_update",
        "emotion_hint",
        "voice_request",
        "voice_started",
        "voice_finished",
        "speech_start",
        "speech_end",
        "status_update",
        "error",
    }
)

CONFIRMATION_ACTIONS = frozenset(
    {
        "memory_store_fact",
        "memory_store_summary",
        "debug_snapshot",
        "activity_note",
    }
)


def utc_now() -> str:
    return datetime.utcnow().replace(microsecond=0).isoformat() + "Z"


def make_action_id(prefix: str = "act") -> str:
    import uuid

    return f"{prefix}_{uuid.uuid4().hex[:12]}"


@dataclass(frozen=True)
class RoutedAction:
    """Normalized action ready for local dispatch or inspection."""

    action_id: str
    index: int
    request: ActionRequest

    def to_dict(self) -> Dict[str, Any]:
        return {
            "action_id": self.action_id,
            "index": self.index,
            "request": self.request.to_dict(),
        }


@dataclass(frozen=True)
class ActionRouteResult:
    """Result of turning a brain response into routable actions."""

    ok: bool
    actions: List[RoutedAction]
    results: List[ActionResult]
    requires_confirmation: bool = False
    errors: Tuple[Mapping[str, Any], ...] = ()

    def to_dict(self) -> Dict[str, Any]:
        return {
            "ok": self.ok,
            "actions": [action.to_dict() for action in self.actions],
            "results": [result.to_dict() for result in self.results],
            "requires_confirmation": self.requires_confirmation,
            "errors": [dict(error) for error in self.errors],
        }


def _payload_without_type(action: Mapping[str, Any]) -> Dict[str, Any]:
    return {key: value for key, value in action.items() if key != "type"}


def _request_from_action(
    action: Mapping[str, Any],
    *,
    turn_id: Optional[str] = None,
) -> ActionRequest:
    action_type = str(action.get("type") or "").strip()
    if action_type not in ROUTABLE_ACTION_TYPES:
        raise SchemaValidationError(f"action is not routable: {action_type}")

    requires_confirmation = action_type in CONFIRMATION_ACTIONS
    status = "requested"
    if action_type in LOCAL_SAFE_ACTIONS:
        status = "confirmed"

    return ActionRequest(
        type=action_type,
        payload=_payload_without_type(action),
        status=status,
        requires_confirmation=requires_confirmation,
        source="brain",
        turn_id=turn_id,
    )


def route_response_actions(response: Dict[str, Any], *, turn_id: Optional[str] = None) -> ActionRouteResult:
    validated = validate_brain_response(response)
    requests: List[RoutedAction] = []
    results: List[ActionResult] = []
    errors: List[Mapping[str, Any]] = []
    requires_confirmation = False

    for index, action in enumerate(validated["actions"]):
        try:
            request = _request_from_action(action, turn_id=turn_id)
        except SchemaValidationError as exc:
            errors.append({"index": index, "error": str(exc), "action": dict(action)})
            results.append(
                ActionResult(
                    ok=False,
                    type=str(action.get("type", "")),
                    status="failed",
                    output={"action": dict(action)},
                    error={"message": str(exc), "source": "actions"},
                )
            )
            continue

        routed = RoutedAction(action_id=make_action_id(), index=index, request=request)
        requests.append(routed)
        requires_confirmation = requires_confirmation or request.requires_confirmation
        results.append(
            ActionResult(
                ok=True,
                type=request.type,
                status=request.status if request.status in {"completed", "confirmed"} else "completed",
                output={
                    "request": request.to_dict(),
                    "accepted": True,
                    "ts": utc_now(),
                },
            )
        )

    ok = not errors
    return ActionRouteResult(
        ok=ok,
        actions=requests,
        results=results,
        requires_confirmation=requires_confirmation,
        errors=tuple(errors),
    )


def route_actions(response: Dict[str, Any]) -> List[Dict[str, Any]]:
    routed = route_response_actions(response)
    return [item.request.to_dict() for item in routed.actions]


def action_summary(result: ActionRouteResult) -> Dict[str, Any]:
    return result.to_dict()
