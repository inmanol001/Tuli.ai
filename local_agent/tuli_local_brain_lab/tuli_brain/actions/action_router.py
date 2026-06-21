from __future__ import annotations

from copy import deepcopy
from typing import Any, Dict, List

from ..schemas import SchemaValidationError, validate_brain_response


ROUTABLE_ACTIONS = frozenset(
    {
        "bubble_show",
        "emotion_hint",
        "speech_start",
        "speech_end",
        "error",
    }
)


def route_actions(response: Dict[str, Any]) -> List[Dict[str, Any]]:
    validated = validate_brain_response(response)
    routed: List[Dict[str, Any]] = []

    for index, action in enumerate(validated["actions"]):
        action_type = action.get("type")
        if action_type not in ROUTABLE_ACTIONS:
            raise SchemaValidationError(f"action is not routable: {action_type}")

        routed.append(
            {
                "index": index,
                "type": action_type,
                "payload": {key: deepcopy(value) for key, value in action.items() if key != "type"},
            }
        )

    return routed
