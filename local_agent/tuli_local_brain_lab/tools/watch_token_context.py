from __future__ import annotations

import json
import sys
import time
from pathlib import Path
from typing import Any, Dict, Iterable, Optional


STREAM_PATH = Path.home() / "Library" / "Application Support" / "VroidOverlay" / "openclaw_stream.jsonl"


def parse_token_event(line: str) -> Optional[Dict[str, Any]]:
    try:
        payload = json.loads(line)
    except json.JSONDecodeError:
        return None
    if not isinstance(payload, dict):
        return None
    if payload.get("type") != "token_context_update":
        return None
    return payload


def _read_lines(path: Path) -> Iterable[str]:
    if not path.exists():
        return []
    return path.read_text(encoding="utf-8", errors="replace").splitlines()


def _summarize_event(event: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    if not event:
        return {
            "model": "-",
            "num_ctx": 0,
            "num_predict": 0,
            "context_tokens": 0,
            "context_percent": 0.0,
            "output_tokens": 0,
            "last_duration": "-",
        }
    context_tokens = event.get("actual_prompt_tokens") or event.get("approx_prompt_tokens") or 0
    context_percent = event.get("context_percent_actual")
    if context_percent is None:
        context_percent = event.get("context_percent_estimated") or 0.0
    output_tokens = event.get("actual_output_tokens") or 0
    total_duration = event.get("total_duration")
    last_duration = f"{round((float(total_duration) / 1_000_000_000), 1)}s" if total_duration else "-"
    return {
        "model": event.get("model") or "-",
        "num_ctx": int(event.get("num_ctx") or 0),
        "num_predict": int(event.get("num_predict") or 0),
        "context_tokens": int(context_tokens or 0),
        "context_percent": float(context_percent or 0.0),
        "output_tokens": int(output_tokens or 0),
        "last_duration": last_duration,
    }


def render_hud(state: Dict[str, Any]) -> str:
    router = _summarize_event(state.get("router"))
    chat = _summarize_event(state.get("chat"))
    return (
        "TULI TOKEN CONTEXT LIVE\n"
        "────────────────────────────────────\n"
        f"Router {router['model']}\n"
        f"Context: {router['context_tokens']} / {router['num_ctx']}   {router['context_percent']:.1f}%\n"
        f"Output: {router['output_tokens']} / {router['num_predict']}\n"
        f"Last: {router['last_duration']}\n\n"
        f"Chat {chat['model']}\n"
        f"Context: {chat['context_tokens']} / {chat['num_ctx']}   {chat['context_percent']:.1f}%\n"
        f"Output: {chat['output_tokens']} / {chat['num_predict']}\n"
        f"Last: {chat['last_duration']}\n\n"
        f"Memory:\nLoaded memories: {state.get('loaded_memories', 0)}\nApprox memory chars: {state.get('memory_chars', 0)}\n\n"
        f"Last route:\n{state.get('last_route', '-')}\n"
    )


def main() -> int:
    state: Dict[str, Any] = {"router": None, "chat": None, "last_route": "-", "loaded_memories": 0, "memory_chars": 0}
    last_size = -1
    try:
        while True:
            if not STREAM_PATH.exists():
                sys.stdout.write("\x1b[2J\x1b[H")
                sys.stdout.write("TULI TOKEN CONTEXT LIVE\n────────────────────────────────────\nWaiting for event stream...\n")
                sys.stdout.flush()
                time.sleep(0.5)
                continue

            lines = list(_read_lines(STREAM_PATH))
            if len(lines) != last_size:
                for line in lines[-200:]:
                    event = parse_token_event(line)
                    if event:
                        role = str(event.get("model_role") or "")
                        if role in {"router", "chat"}:
                            state[role] = event
                        continue
                    try:
                        payload = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if not isinstance(payload, dict):
                        continue
                    if payload.get("type") == "memory_summary":
                        state["loaded_memories"] = payload.get("loaded_memories", state["loaded_memories"])
                        state["memory_chars"] = payload.get("memory_chars", state["memory_chars"])
                    if payload.get("type") in {"tool_chain", "chat_reply", "ai_router_chat", "ai_router_tool", "ai_router_clarify"}:
                        state["last_route"] = payload.get("type")
                last_size = len(lines)
                sys.stdout.write("\x1b[2J\x1b[H")
                sys.stdout.write(render_hud(state))
                sys.stdout.flush()
            time.sleep(0.5)
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
