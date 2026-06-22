from __future__ import annotations

import json
import os
from dataclasses import dataclass
from typing import Any, Dict, List, Optional

from ..config import TuliBrainConfig, load_config
from ..providers.ollama_local import OllamaLocalError, chat_raw_messages
from ..tools import DEFAULT_TOOL_CATALOG, ToolCatalog
from .semantic_guards import apply_post_router_semantic_guard, apply_pre_router_semantic_guard
from .router_types import RouterDecision


ALLOWED_ROUTES = {"tool", "chat", "clarify"}
WINDOW_TILING_ACTIONS = {
    "right",
    "left",
    "fill",
    "center",
    "quarters",
    "top-left",
    "top-right",
    "bottom-left",
    "bottom-right",
    "top",
    "bottom",
    "return",
}
ACTION_HINT_TOKENS = (
    "open",
    "move",
    "put",
    "snap",
    "switch",
    "go",
    "show",
    "check",
    "list",
    "remember",
    "forget",
    "fill",
    "center",
    "arrange",
    "enable",
    "disable",
    "abre",
    "pon",
    "mueve",
    "cambia",
    "revisa",
    "lista",
    "recuerda",
    "olvida",
)
ROUTER_SYSTEM_PROMPT = (
    "You are Tuli's intent router. "
    "Return only valid JSON. "
    "Do not answer the user. "
    "Choose exactly one route: tool, chat, clarify. "
    "Use route tool when the user wants a supported desktop, app, window, space, memory, voice, system, or observation action. "
    "Use route chat for knowledge, strategy, creative, explanation, or conversation requests. "
    "Use route clarify when the user wants an action but a required detail is missing. "
    "Only use tools listed in the tool catalog. "
    "Never invent tool names. "
    "Never execute tools. "
    "Never include markdown. "
    "Never include commentary outside JSON. "
    "For route tool, always include tool_name and arguments. "
    "For route clarify, include a short clarification question. "
    "Do not choose macos.list_apps for general brainstorming, sales, marketing, writing, or knowledge questions. "
    "Do not choose macos.observe_frontmost for window movement requests. Use window.native_tiling. "
    "Do not choose macos.open_app for desktop or space navigation. Use space tools. "
    'Return an object with keys: route, tool_name, arguments, confidence, clarification, reason.'
)
ROUTER_EXAMPLES = (
    {
        "user_text": "Tuli move it left",
        "json": {
            "route": "tool",
            "tool_name": "window.native_tiling",
            "arguments": {"action": "left"},
            "confidence": 0.92,
            "clarification": "",
            "reason": "The user wants to move the current window left.",
        },
    },
    {
        "user_text": "Tuli put the current window on the right",
        "json": {
            "route": "tool",
            "tool_name": "window.native_tiling",
            "arguments": {"action": "right"},
            "confidence": 0.92,
            "clarification": "",
            "reason": "The user wants to place the current window on the right.",
        },
    },
    {
        "user_text": "Tuli can you move windows?",
        "json": {
            "route": "chat",
            "tool_name": "",
            "arguments": {},
            "confidence": 0.90,
            "clarification": "",
            "reason": "The user is asking about Tuli's capabilities, not requesting execution.",
        },
    },
    {
        "user_text": "Tuli go to the previous desktop",
        "json": {
            "route": "tool",
            "tool_name": "space.previous",
            "arguments": {},
            "confidence": 0.90,
            "clarification": "",
            "reason": "The user wants to move to the previous desktop.",
        },
    },
    {
        "user_text": "Tuli what windows do you see?",
        "json": {
            "route": "tool",
            "tool_name": "macos.visible_windows",
            "arguments": {},
            "confidence": 0.90,
            "clarification": "",
            "reason": "The user wants a list of visible windows.",
        },
    },
    {
        "user_text": "Tuli tell me about sales",
        "json": {
            "route": "chat",
            "tool_name": "",
            "arguments": {},
            "confidence": 0.90,
            "clarification": "",
            "reason": "The user is asking a general business question.",
        },
    },
    {
        "user_text": "Tuli give me three ideas to sell more",
        "json": {
            "route": "chat",
            "tool_name": "",
            "arguments": {},
            "confidence": 0.90,
            "clarification": "",
            "reason": "The user is asking for brainstorming and sales ideas.",
        },
    },
    {
        "user_text": "hola Tuli",
        "json": {
            "route": "chat",
            "tool_name": "",
            "arguments": {},
            "confidence": 0.90,
            "clarification": "",
            "reason": "This is a greeting and should stay on the chat path.",
        },
    },
    {
        "user_text": "Tuli open it",
        "json": {
            "route": "clarify",
            "tool_name": "macos.open_app",
            "arguments": {},
            "confidence": 0.72,
            "clarification": "Which app do you want me to open?",
            "reason": "The user wants to open something, but the app name is missing.",
        },
    },
)


def _trace_enabled() -> bool:
    return os.environ.get("TULI_TRACE_ROUTER", "").strip() == "1" or os.environ.get("TULI_TRACE", "").strip() == "1"


def _trace(line: str) -> None:
    if _trace_enabled():
        print(f"[TULI ROUTER TRACE] {line}")


def _clamp_confidence(value: Any) -> float:
    try:
        confidence = float(value)
    except (TypeError, ValueError):
        return 0.0
    return max(0.0, min(1.0, confidence))


def _strip_fences(text: str) -> str:
    cleaned = str(text or "").strip()
    if cleaned.startswith("```"):
        lines = cleaned.splitlines()
        if lines:
            lines = lines[1:]
        if lines and lines[-1].strip().startswith("```"):
            lines = lines[:-1]
        cleaned = "\n".join(lines).strip()
    return cleaned


def _extract_first_json_object(text: str) -> str:
    cleaned = _strip_fences(text)
    if cleaned.startswith("{") and cleaned.endswith("}"):
        return cleaned

    start = cleaned.find("{")
    if start < 0:
        return cleaned

    depth = 0
    in_string = False
    escape = False
    for index, char in enumerate(cleaned[start:], start=start):
        if in_string:
            if escape:
                escape = False
            elif char == "\\":
                escape = True
            elif char == '"':
                in_string = False
            continue
        if char == '"':
            in_string = True
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return cleaned[start : index + 1]
    return cleaned


def _looks_action_like(user_text: str) -> bool:
    lowered = " ".join(str(user_text or "").strip().lower().split())
    return any(token in lowered for token in ACTION_HINT_TOKENS)


def _normalize_text(text: str) -> str:
    return " ".join(str(text or "").strip().lower().split())


def _compact_catalog(catalog: ToolCatalog) -> List[Dict[str, Any]]:
    compact: List[Dict[str, Any]] = []
    for spec in catalog.enabled_tools():
        arguments: Dict[str, Any] = dict(spec.input_schema)
        if spec.name == "window.native_tiling":
            arguments["action"] = "|".join(sorted(WINDOW_TILING_ACTIONS))
        compact.append(
            {
                "name": spec.name,
                "description": spec.description,
                "arguments": arguments,
            }
        )
    return compact


@dataclass
class AIIntentRouter:
    catalog: ToolCatalog = DEFAULT_TOOL_CATALOG

    def route(self, user_text: str, config: Optional[TuliBrainConfig] = None) -> RouterDecision:
        cfg = config or load_config()
        _trace(f"model: {cfg.router_model}")
        _trace(f"num_ctx: {cfg.router_num_ctx}")
        _trace(f"num_predict: {cfg.router_num_predict}")
        _trace(f"user_text: {user_text}")
        pre_guard_decision = apply_pre_router_semantic_guard(user_text)
        if pre_guard_decision is not None:
            _trace(f"decision: {json.dumps(pre_guard_decision.to_dict(), ensure_ascii=False)}")
            _trace("validation: ok (pre-router-guard)")
            return pre_guard_decision
        try:
            raw_response = self._request_router_response(user_text, cfg)
        except OllamaLocalError as exc:
            decision = self._router_error_decision(user_text, str(exc))
            _trace(f"decision: {json.dumps(decision.to_dict(), ensure_ascii=False)}")
            _trace("validation: failed")
            return decision

        _trace(f"raw_response: {raw_response}")
        decision = self.parse_response(user_text, raw_response)
        validated = self.validate_decision(decision)
        _trace(f"decision: {json.dumps(validated.to_dict(), ensure_ascii=False)}")
        _trace(f"validation: {'ok' if not validated.error else 'failed'}")
        return validated

    def _request_router_response(self, user_text: str, config: TuliBrainConfig) -> str:
        messages = [
            {"role": "system", "content": ROUTER_SYSTEM_PROMPT},
            {
                "role": "user",
                "content": json.dumps(
                    {
                        "user_text": user_text,
                        "tool_catalog": _compact_catalog(self.catalog),
                        "examples": ROUTER_EXAMPLES,
                    },
                    ensure_ascii=False,
                ),
            },
        ]
        result = chat_raw_messages(
            messages,
            config,
            model=config.router_model,
            url=config.router_url,
            temperature=0.0,
            top_p=0.8,
            num_ctx=config.router_num_ctx,
            num_predict=config.router_num_predict,
            keep_alive=config.ollama_keep_alive,
            model_role="router",
        )
        return result.text

    def parse_response(self, user_text: str, raw_response: str) -> RouterDecision:
        extracted = _extract_first_json_object(raw_response)
        try:
            payload = json.loads(extracted)
        except json.JSONDecodeError:
            return self._invalid_json_decision(user_text, raw_response)
        if not isinstance(payload, dict):
            return self._invalid_json_decision(user_text, raw_response)

        route = str(payload.get("route") or "").strip().lower()
        tool_name = str(payload.get("tool_name") or "").strip()
        arguments = payload.get("arguments") if isinstance(payload.get("arguments"), dict) else {}
        clarification = str(payload.get("clarification") or "").strip()
        reason = str(payload.get("reason") or "").strip()
        confidence = _clamp_confidence(payload.get("confidence"))

        return RouterDecision(
            route=route,
            tool_name=tool_name,
            arguments=dict(arguments),
            confidence=confidence,
            clarification=clarification,
            reason=reason,
            raw_text=user_text,
            raw_response=raw_response,
        )

    def validate_decision(self, decision: RouterDecision) -> RouterDecision:
        decision = apply_post_router_semantic_guard(decision.raw_text, decision)

        if decision.route not in ALLOWED_ROUTES:
            return RouterDecision(
                route="chat",
                confidence=decision.confidence,
                raw_text=decision.raw_text,
                raw_response=decision.raw_response,
                error="unknown_route",
                reason=decision.reason,
            )

        if decision.route == "chat":
            return decision

        if decision.route == "clarify":
            clarification = decision.clarification or "What would you like me to do?"
            return RouterDecision(**{**decision.to_dict(), "clarification": clarification})

        if not decision.tool_name:
            guarded = apply_post_router_semantic_guard(decision.raw_text, decision)
            if guarded.tool_name:
                decision = guarded
            else:
                return self._clarify_decision(decision, "I understood this as an action, but I need a clearer command.", "missing_tool_name")

        spec = self.catalog.get(decision.tool_name)
        if spec is None:
            return self._clarify_decision(decision, "I understood this as an action, but I need a supported command.", "unknown_tool")

        if not spec.enabled:
            return self._clarify_decision(decision, f"{spec.name} is not available right now.", "disabled_tool")

        if spec.risk_level not in {"safe", "low_risk"}:
            return self._clarify_decision(decision, "I need confirmation before using that tool.", "unsupported_risk_level")

        arguments = dict(decision.arguments)
        missing = [key for key in spec.input_schema.keys() if key not in arguments or (isinstance(arguments.get(key), str) and not str(arguments.get(key)).strip())]
        if missing:
            if spec.name == "macos.open_app":
                return self._clarify_decision(decision, "Which app do you want me to open?", "missing_required_argument")
            if spec.name == "window.native_tiling":
                return self._clarify_decision(decision, "Which window layout action do you want me to use?", "missing_required_argument")
            return self._clarify_decision(decision, f"I need {missing[0]} before I can do that.", "missing_required_argument")

        if spec.name == "window.native_tiling":
            action = str(arguments.get("action") or "").strip().lower()
            if action not in WINDOW_TILING_ACTIONS:
                return self._clarify_decision(decision, "Which window position do you want: left, right, fill, center, quarters, top, bottom, or a corner?", "invalid_window_action")
            arguments["action"] = action

        return RouterDecision(
            route="tool",
            tool_name=spec.name,
            arguments=arguments,
            confidence=decision.confidence,
            clarification="",
            reason=decision.reason,
            raw_text=decision.raw_text,
            raw_response=decision.raw_response,
            error=None,
        )

    def _invalid_json_decision(self, user_text: str, raw_response: str) -> RouterDecision:
        if _looks_action_like(user_text):
            return RouterDecision(
                route="clarify",
                confidence=0.0,
                clarification="I understood this may be an action, but I need a clearer command.",
                reason="router_json_invalid_action_like",
                raw_text=user_text,
                raw_response=raw_response,
                error="invalid_router_json",
            )
        return RouterDecision(
            route="chat",
            confidence=0.0,
            reason="router_json_invalid",
            raw_text=user_text,
            raw_response=raw_response,
            error="invalid_router_json",
        )

    def _router_error_decision(self, user_text: str, error: str) -> RouterDecision:
        if _looks_action_like(user_text):
            return RouterDecision(
                route="clarify",
                confidence=0.0,
                clarification="I understood this may be an action, but I need a clearer command.",
                reason="router_provider_error_action_like",
                raw_text=user_text,
                raw_response="",
                error=error,
            )
        return RouterDecision(
            route="chat",
            confidence=0.0,
            reason="router_provider_error",
            raw_text=user_text,
            raw_response="",
            error=error,
        )

    def _clarify_decision(self, decision: RouterDecision, clarification: str, error: str) -> RouterDecision:
        return RouterDecision(
            route="clarify",
            tool_name=decision.tool_name,
            arguments=dict(decision.arguments),
            confidence=decision.confidence,
            clarification=clarification,
            reason=decision.reason,
            raw_text=decision.raw_text,
            raw_response=decision.raw_response,
            error=error,
        )
