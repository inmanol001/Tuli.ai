from __future__ import annotations

from typing import Optional

from .router_types import RouterDecision


GREETING_HINT_TOKENS = (
    "hola",
    "hello",
    "hi",
    "hey",
    "buenas",
    "good morning",
    "good afternoon",
    "good evening",
)
CAPABILITY_HINT_TOKENS = (
    "what can you do",
    "what tools do you have",
    "what are your capabilities",
    "can you move windows",
    "can you resize windows",
)
GENERAL_CHAT_HINT_TOKENS = (
    "tell me about",
    "explain",
    "how do i",
    "give me ideas",
    "brainstorm",
    "strategy",
    "sales",
    "sell more",
    "write",
    "draft",
    "summarize",
    "help me understand",
)
VISIBLE_WINDOWS_HINT_TOKENS = (
    "what windows do you see",
    "what windows are visible",
    "list visible windows",
    "show my windows",
    "which windows are open",
    "what apps/windows are open",
)
FRONTMOST_HINT_TOKENS = (
    "what app is active",
    "what is the frontmost window",
    "frontmost app",
    "frontmost window",
    "what am i using right now",
    "current app",
    "active window",
)
PREVIOUS_SPACE_HINT_TOKENS = (
    "switch back",
    "previous desktop",
    "previous space",
    "go to the previous desktop",
    "return to the previous desktop",
    "switch to previous space",
    "go back a desktop",
)

WINDOW_PLACEMENT_VERBS = (
    "move",
    "put",
    "snap",
    "place",
    "fill",
    "center",
    "maximize",
    "fullscreen",
)
WINDOW_TARGET_HINTS = (
    "window",
    "current window",
    "frontmost window",
    "this window",
)


def _contains_any(text: str, tokens: tuple[str, ...]) -> bool:
    return any(token in text for token in tokens)


def _window_action_from_text(user_text: str) -> Optional[str]:
    lowered = _normalize_text(user_text)
    if not _contains_any(lowered, WINDOW_PLACEMENT_VERBS):
        return None
    if not (_contains_any(lowered, WINDOW_TARGET_HINTS) or " move it " in f" {lowered} " or " put it " in f" {lowered} " or " snap it " in f" {lowered} " or " place it " in f" {lowered} "):
        return None

    if "top-left" in lowered or "top left" in lowered:
        return "top-left"
    if "top-right" in lowered or "top right" in lowered:
        return "top-right"
    if "bottom-left" in lowered or "bottom left" in lowered:
        return "bottom-left"
    if "bottom-right" in lowered or "bottom right" in lowered:
        return "bottom-right"
    if "left" in lowered:
        return "left"
    if "right" in lowered:
        return "right"
    if "top" in lowered or "up" in lowered:
        return "top"
    if "bottom" in lowered or "down" in lowered:
        return "bottom"
    if "center" in lowered:
        return "center"
    if "fill" in lowered:
        return "fill"
    if "maximize" in lowered or "fullscreen" in lowered:
        return "fill"
    return None


def _is_capability_question(user_text: str) -> bool:
    lowered = _normalize_text(user_text)
    if any(token in lowered for token in CAPABILITY_HINT_TOKENS):
        return True
    return "if i ask you to" in lowered and "can you do it" in lowered


def _is_previous_space_request(user_text: str) -> bool:
    lowered = _normalize_text(user_text)
    return any(token in lowered for token in PREVIOUS_SPACE_HINT_TOKENS)


def _is_visible_windows_question(user_text: str) -> bool:
    lowered = _normalize_text(user_text)
    return any(token in lowered for token in VISIBLE_WINDOWS_HINT_TOKENS)


def _is_frontmost_question(user_text: str) -> bool:
    lowered = _normalize_text(user_text)
    return any(token in lowered for token in FRONTMOST_HINT_TOKENS)


def _is_general_chat_request(user_text: str) -> bool:
    lowered = _normalize_text(user_text)
    if not any(token in lowered for token in GENERAL_CHAT_HINT_TOKENS):
        return False
    if _window_action_from_text(user_text) is not None:
        return False
    if _is_previous_space_request(user_text) or _is_visible_windows_question(user_text) or _is_frontmost_question(user_text):
        return False
    return True


def _normalize_text(text: str) -> str:
    return " ".join(str(text or "").strip().lower().split())


def _looks_greeting_like(user_text: str) -> bool:
    lowered = _normalize_text(user_text)
    if not lowered:
        return False
    if lowered in {"hola tuli", "hello tuli", "hi tuli", "hey tuli", "tuli hola", "tuli hello", "tuli hi", "tuli hey"}:
        return True
    return any(lowered.startswith(token + " ") or lowered == token for token in GREETING_HINT_TOKENS)


def apply_pre_router_semantic_guard(user_text: str) -> Optional[RouterDecision]:
    lowered = _normalize_text(user_text)
    window_action = _window_action_from_text(user_text)

    if window_action is not None:
        return RouterDecision(
            route="tool",
            tool_name="window.native_tiling",
            arguments={"action": window_action},
            confidence=0.9,
            clarification="",
            reason="A clear window placement request should use native window tiling.",
            raw_text=user_text,
            raw_response="",
            error=None,
        )

    if _is_capability_question(user_text):
        return RouterDecision(
            route="chat",
            tool_name="",
            arguments={},
            confidence=0.9,
            clarification="",
            reason="The user is asking about Tuli's capabilities, not requesting execution.",
            raw_text=user_text,
            raw_response="",
            error=None,
        )

    if _looks_greeting_like(lowered):
        return RouterDecision(
            route="chat",
            tool_name="",
            arguments={},
            confidence=0.8,
            clarification="",
            reason="Greeting-like text should stay on the normal chat path.",
            raw_text=user_text,
            raw_response="",
            error=None,
        )

    if _is_previous_space_request(user_text):
        return RouterDecision(
            route="tool",
            tool_name="space.previous",
            arguments={},
            confidence=0.85,
            clarification="",
            reason="A previous desktop request should map to the previous space action.",
            raw_text=user_text,
            raw_response="",
            error=None,
        )

    if _is_visible_windows_question(user_text):
        return RouterDecision(
            route="tool",
            tool_name="macos.visible_windows",
            arguments={},
            confidence=0.88,
            clarification="",
            reason="A visible windows question should use the visible windows observation tool.",
            raw_text=user_text,
            raw_response="",
            error=None,
        )

    if _is_general_chat_request(user_text):
        return RouterDecision(
            route="chat",
            tool_name="",
            arguments={},
            confidence=0.88,
            clarification="",
            reason="This is a general knowledge or creative request, so it should stay on chat.",
            raw_text=user_text,
            raw_response="",
            error=None,
        )

    return None


def apply_post_router_semantic_guard(user_text: str, decision: RouterDecision) -> RouterDecision:
    lowered = _normalize_text(user_text)
    window_action = _window_action_from_text(user_text)

    if window_action is not None and decision.tool_name in {"", "macos.observe_frontmost"}:
        return RouterDecision(
            route="tool",
            tool_name="window.native_tiling",
            arguments={"action": window_action},
            confidence=max(decision.confidence, 0.9),
            clarification="",
            reason="A clear window placement request should use native window tiling.",
            raw_text=decision.raw_text or user_text,
            raw_response=decision.raw_response,
            error=None,
        )

    if _is_capability_question(user_text):
        return RouterDecision(
            route="chat",
            tool_name="",
            arguments={},
            confidence=max(decision.confidence, 0.9),
            clarification="",
            reason="The user is asking about Tuli's capabilities, not requesting execution.",
            raw_text=decision.raw_text or user_text,
            raw_response=decision.raw_response,
            error=None,
        )

    if _looks_greeting_like(lowered):
        return RouterDecision(
            route="chat",
            tool_name="",
            arguments={},
            confidence=max(decision.confidence, 0.8),
            clarification="",
            reason="Greeting-like text should stay on the normal chat path.",
            raw_text=decision.raw_text or user_text,
            raw_response=decision.raw_response,
            error=None,
        )

    if _is_previous_space_request(user_text):
        return RouterDecision(
            route="tool",
            tool_name="space.previous",
            arguments={},
            confidence=max(decision.confidence, 0.85),
            clarification="",
            reason="A previous desktop request should map to the previous space action.",
            raw_text=decision.raw_text or user_text,
            raw_response=decision.raw_response,
            error=None,
        )

    if _is_visible_windows_question(user_text) and decision.tool_name in {"", "macos.observe_frontmost"}:
        return RouterDecision(
            route="tool",
            tool_name="macos.visible_windows",
            arguments={},
            confidence=max(decision.confidence, 0.88),
            clarification="",
            reason="A visible windows question should use the visible windows observation tool.",
            raw_text=decision.raw_text or user_text,
            raw_response=decision.raw_response,
            error=None,
        )

    if _is_general_chat_request(user_text) and decision.tool_name in {"", "macos.list_apps", "macos.observe_frontmost"}:
        return RouterDecision(
            route="chat",
            tool_name="",
            arguments={},
            confidence=max(decision.confidence, 0.88),
            clarification="",
            reason="This is a general knowledge or creative request, so it should stay on chat.",
            raw_text=decision.raw_text or user_text,
            raw_response=decision.raw_response,
            error=None,
        )

    if "open it" in lowered and decision.tool_name == "macos.open_app" and not decision.arguments:
        return RouterDecision(
            route="clarify",
            tool_name="macos.open_app",
            arguments={},
            confidence=max(decision.confidence, 0.72),
            clarification="Which app do you want me to open?",
            reason="Open request is missing the app name.",
            raw_text=decision.raw_text or user_text,
            raw_response=decision.raw_response,
            error="missing_required_argument",
        )

    if not decision.tool_name:
        if "open it" in lowered:
            return RouterDecision(
                route="clarify",
                tool_name="macos.open_app",
                arguments={},
                confidence=max(decision.confidence, 0.72),
                clarification="Which app do you want me to open?",
                reason="Heuristic fallback inferred an app-open request with a missing app name.",
                raw_text=decision.raw_text or user_text,
                raw_response=decision.raw_response,
                error="missing_required_argument",
            )

        if "can you see my desktop" in lowered:
            return RouterDecision(
                route="tool",
                tool_name="macos.visible_windows",
                arguments={},
                confidence=max(decision.confidence, 0.75),
                clarification="",
                reason="Heuristic fallback inferred a desktop visibility question.",
                raw_text=decision.raw_text or user_text,
                raw_response=decision.raw_response,
                error=None,
            )

    return decision
