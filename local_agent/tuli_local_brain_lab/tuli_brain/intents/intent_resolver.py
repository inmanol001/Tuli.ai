from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Optional

from .app_resolver import resolve_app_name
from .intent_types import IntentResult


_LEADING_TULI_PREFIXES = ("tuli,", "tuli:", "tuli ", "tuli-")


def _normalize_text(text: str) -> str:
    return " ".join(str(text or "").strip().split())


def _strip_tuli_prefix(text: str) -> str:
    lowered = text.lower()
    for prefix in _LEADING_TULI_PREFIXES:
        if lowered.startswith(prefix):
            return text[len(prefix) :].lstrip(" ,:")
    return text


@dataclass
class IntentResolver:
    def resolve(self, user_text: str) -> IntentResult:
        raw_text = _normalize_text(user_text)
        if not raw_text:
            return IntentResult(intent_name="none", tool_name="", source_text="", error="empty input")

        if raw_text.startswith("/"):
            return IntentResult(
                intent_name="none",
                tool_name="",
                confidence=0.0,
                source_text=raw_text,
                metadata={"bypass": "slash_command"},
                error="slash command bypass",
            )

        candidate = _strip_tuli_prefix(raw_text)
        lowered = candidate.lower()

        resolver = (
            self._resolve_open_app(lowered, raw_text)
            or self._resolve_visible_windows(lowered, raw_text)
            or self._resolve_frontmost(lowered, raw_text)
            or self._resolve_permissions(lowered, raw_text)
            or self._resolve_list_apps(lowered, raw_text)
            or self._resolve_window_tiling(lowered, raw_text)
            or self._resolve_space(lowered, raw_text)
            or self._resolve_memory(lowered, raw_text)
            or self._resolve_voice(lowered, raw_text)
            or self._resolve_system(lowered, raw_text)
        )
        if resolver is not None:
            return resolver

        return IntentResult(
            intent_name="none",
            tool_name="",
            confidence=0.3,
            source_text=raw_text,
            error="no intent matched",
        )

    def _resolve_open_app(self, lowered: str, source_text: str) -> Optional[IntentResult]:
        match = re.search(r"\b(?:open|launch|abre|abrir|lanza)\s+(?:the\s+|el\s+|la\s+)?(?P<app>.+)$", lowered)
        if not match:
            return None
        app_name = resolve_app_name(match.group("app"))
        if not app_name:
            return None
        return IntentResult(
            intent_name="open_app",
            tool_name="macos.open_app",
            arguments={"app_name": app_name},
            confidence=0.9,
            source_text=source_text,
            bubble_text=f"Opening {app_name}.",
            response_text=f"Opening {app_name}.",
            metadata={"resolver": "app_resolver"},
        )

    def _resolve_visible_windows(self, lowered: str, source_text: str) -> Optional[IntentResult]:
        english_phrases = (
            "what windows do you see",
            "list visible windows",
            "show visible windows",
            "check my windows",
            "what windows are open",
        )
        spanish_aliases = (
            "que ventanas ves",
            "qué ventanas ves",
            "dime que ventanas estan abiertas",
            "dime qué ventanas están abiertas",
            "lista las ventanas",
            "mira mis ventanas",
        )
        if any(phrase in lowered for phrase in english_phrases + spanish_aliases):
            return IntentResult("visible_windows", "macos.visible_windows", confidence=0.88, source_text=source_text, bubble_text="Checking visible windows.", response_text="Checking visible windows.")
        return None

    def _resolve_frontmost(self, lowered: str, source_text: str) -> Optional[IntentResult]:
        english_phrases = (
            "what app is active",
            "what app is in front",
            "what am i using",
            "check the active window",
        )
        spanish_aliases = (
            "que app esta al frente",
            "qué app está al frente",
            "que estoy usando",
            "qué estoy usando",
            "que ventana esta activa",
            "qué ventana está activa",
            "observa macos",
        )
        if any(phrase in lowered for phrase in english_phrases + spanish_aliases):
            return IntentResult("observe_frontmost", "macos.observe_frontmost", confidence=0.88, source_text=source_text, bubble_text="Checking the active app.", response_text="Checking the active app.")
        return None

    def _resolve_permissions(self, lowered: str, source_text: str) -> Optional[IntentResult]:
        english_phrases = ("check permissions", "check macos permissions", "verify permissions")
        spanish_aliases = ("que permisos tienes", "qué permisos tienes", "revisa permisos", "verifica permisos")
        if any(phrase in lowered for phrase in english_phrases + spanish_aliases):
            return IntentResult("permissions_check", "macos.permissions_check", confidence=0.88, source_text=source_text, bubble_text="Checking macOS permissions.", response_text="Checking macOS permissions.")
        return None

    def _resolve_list_apps(self, lowered: str, source_text: str) -> Optional[IntentResult]:
        english_phrases = ("what apps do you know", "what apps can you open", "list apps")
        spanish_aliases = ("que apps conoces", "qué apps conoces", "que aplicaciones puedes abrir", "qué aplicaciones puedes abrir", "lista apps")
        if any(phrase in lowered for phrase in english_phrases + spanish_aliases):
            return IntentResult("list_apps", "macos.list_apps", confidence=0.88, source_text=source_text, bubble_text="Checking available apps.", response_text="Checking available apps.")
        return None

    def _resolve_window_tiling(self, lowered: str, source_text: str) -> Optional[IntentResult]:
        action_map = (
            ("top-left", ("put it top left", "move this window to the top left", "ponla arriba a la izquierda")),
            ("top-right", ("put it top right", "move this window to the top right", "ponla arriba a la derecha")),
            ("bottom-left", ("put it bottom left", "move this window to the bottom left", "ponla abajo a la izquierda")),
            ("bottom-right", ("put it bottom right", "move this window to the bottom right", "ponla abajo a la derecha")),
            ("right", ("move this window to the right", "put this window on the right", "pon esta ventana a la derecha", "ponla a la derecha")),
            ("left", ("move this window to the left", "put this window on the left", "mueve esto a la izquierda", "pon esta ventana a la izquierda")),
            ("fill", ("fill this window", "make this window bigger", "maximize this window", "llena esta ventana", "hazla grande", "maximiza esta ventana")),
            ("center", ("center this window", "centra esta ventana")),
            ("quarters", ("arrange windows into quarters", "organize in 4", "organiza en 4", "organiza las ventanas en cuartos")),
            ("top", ("move this window to the top", "put this window at the top")),
            ("bottom", ("move this window to the bottom", "put this window at the bottom")),
            ("return", ("restore the previous window size", "return this window to the previous size")),
        )
        for action, phrases in action_map:
            if any(phrase in lowered for phrase in phrases):
                return IntentResult(
                    intent_name="window_native_tiling",
                    tool_name="window.native_tiling",
                    arguments={"action": action},
                    confidence=0.9,
                    source_text=source_text,
                    bubble_text="Preparing window action.",
                    response_text="Preparing window action.",
                )
        return None

    def _resolve_space(self, lowered: str, source_text: str) -> Optional[IntentResult]:
        mapping = (
            ("space.next", ("go to the next desktop", "switch to the next desktop", "next desktop", "pasa al escritorio siguiente", "ve al otro escritorio", "siguiente escritorio")),
            ("space.previous", ("go back to the previous desktop", "switch to the previous desktop", "previous desktop", "vuelve al escritorio anterior", "regresa al escritorio anterior", "pasa al escritorio anterior", "escritorio anterior")),
            ("space.mission_control", ("open mission control", "show mission control", "abre mission control", "abre el control de escritorios", "control de escritorios")),
            ("space.status", ("desktop status", "space status", "estado de escritorios")),
        )
        for tool_name, phrases in mapping:
            if any(phrase in lowered for phrase in phrases):
                return IntentResult(
                    intent_name=tool_name.replace(".", "_"),
                    tool_name=tool_name,
                    confidence=0.88,
                    source_text=source_text,
                    bubble_text="Preparing desktop action.",
                    response_text="Preparing desktop action.",
                )
        return None

    def _resolve_memory(self, lowered: str, source_text: str) -> Optional[IntentResult]:
        remember_match = re.search(r"\b(?:remember that|save that|remember this:|recuerda que|guarda que)\s+(?P<text>.+)$", lowered)
        if remember_match:
            text = remember_match.group("text").strip()
            return IntentResult(
                intent_name="memory_remember",
                tool_name="memory.remember",
                arguments={"text": text},
                confidence=0.86,
                source_text=source_text,
                bubble_text="I'll remember that.",
                response_text="I'll remember that.",
            )
        if any(phrase in lowered for phrase in ("what do you remember", "check your memory", "que recuerdas", "qué recuerdas", "mira tu memoria")):
            return IntentResult("memory_inspect", "memory.inspect", confidence=0.84, source_text=source_text, bubble_text="Checking memory.", response_text="Checking memory.")
        if lowered.startswith("forget ") or lowered.startswith("olvida "):
            query = candidate_tail(lowered, "forget ").strip() or candidate_tail(lowered, "olvida ").strip() or "this"
            return IntentResult(
                intent_name="memory_forget",
                tool_name="memory.forget",
                arguments={"query": query},
                confidence=0.82,
                requires_confirmation=True,
                source_text=source_text,
                bubble_text="I need confirmation before forgetting that.",
                response_text="I need confirmation before forgetting that.",
            )
        if lowered.startswith("summarize this") or lowered.startswith("resume esto"):
            return IntentResult("memory_summarize", "memory.summarize", confidence=0.8, source_text=source_text, bubble_text="Preparing summary.", response_text="Preparing summary.")
        return None

    def _resolve_voice(self, lowered: str, source_text: str) -> Optional[IntentResult]:
        if any(phrase in lowered for phrase in ("enable voice", "turn on voice", "activa voz", "habla")):
            return IntentResult("voice_on", "voice.speak_toggle", arguments={"state": "on"}, confidence=0.82, source_text=source_text, bubble_text="Voice enabled.", response_text="Voice enabled.")
        if any(phrase in lowered for phrase in ("disable voice", "turn off voice", "be quiet", "desactiva voz", "silencio")):
            return IntentResult("voice_off", "voice.speak_toggle", arguments={"state": "off"}, confidence=0.82, source_text=source_text, bubble_text="Voice disabled.", response_text="Voice disabled.")
        return None

    def _resolve_system(self, lowered: str, source_text: str) -> Optional[IntentResult]:
        if any(phrase in lowered for phrase in ("tuli status", "how are you running", "estado de tuli", "como estas funcionando", "cómo estás funcionando")):
            return IntentResult("system_status", "system.status", confidence=0.8, source_text=source_text, bubble_text="Tuli is active.", response_text="Tuli is active.")
        if "fast mode" in lowered or "modo rapido" in lowered or "modo rápido" in lowered:
            return IntentResult("mode_instant", "mode.instant", confidence=0.8, source_text=source_text, bubble_text="Instant mode enabled.", response_text="Instant mode enabled.")
        if "think more" in lowered or "piensa mas" in lowered or "piensa más" in lowered:
            return IntentResult("mode_thinking", "mode.thinking", confidence=0.8, source_text=source_text, bubble_text="Thinking mode enabled.", response_text="Thinking mode enabled.")
        return None


def candidate_tail(text: str, prefix: str) -> str:
    if text.startswith(prefix):
        return text[len(prefix) :]
    return text
