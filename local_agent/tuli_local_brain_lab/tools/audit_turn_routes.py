from __future__ import annotations

import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tuli_brain.config import load_config
from tuli_brain.intents import ActionPlanner, IntentResolver
from tuli_brain.router import AIIntentRouter


PHRASES = (
    "Tuli move this window to the left",
    "Tuli move it left",
    "Tuli put it on the left",
    "Tuli snap this window left",
    "Tuli move this window to the right",
    "Tuli open browser",
    "Tuli open the browser",
    "Tuli open it",
    "Tuli switch back",
    "Tuli switch to the previous desktop",
    "Tuli open Mission Control",
    "Tuli tell me about sales",
    "Tuli explain sales strategy",
    "Tuli what can you do",
    "Tuli can you see my desktop",
    "Tuli remember that this project is called Inma",
    "/window native left",
)


def main() -> int:
    config = load_config()
    router = AIIntentRouter()
    planner = ActionPlanner()

    for phrase in PHRASES:
        if phrase.lstrip().startswith("/"):
            print(json.dumps({"phrase": phrase, "final_route": "slash_command"}, ensure_ascii=False))
            continue

        intent = IntentResolver().resolve(phrase)
        plan = planner.plan(intent)
        if plan.should_execute or plan.reason == "requires_confirmation":
            print(
                json.dumps(
                    {
                        "phrase": phrase,
                        "final_route": "deterministic_tool_chain",
                        "tool_name": intent.tool_name,
                        "arguments": dict(intent.arguments),
                        "confidence": intent.confidence,
                    },
                    ensure_ascii=False,
                )
            )
            continue

        decision = router.route(phrase, config)
        final_route = {
            "tool": "ai_router_tool",
            "chat": "ai_router_chat",
            "clarify": "ai_router_clarify",
        }.get(decision.route, "ai_router_chat")
        print(
            json.dumps(
                {
                    "phrase": phrase,
                    "final_route": final_route,
                    "tool_name": decision.tool_name,
                    "arguments": dict(decision.arguments),
                    "confidence": decision.confidence,
                    "clarification": decision.clarification,
                    "error": decision.error,
                },
                ensure_ascii=False,
            )
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
