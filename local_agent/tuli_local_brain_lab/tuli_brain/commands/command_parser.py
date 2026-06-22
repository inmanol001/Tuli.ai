from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Iterable, List, Optional, Sequence, Tuple

from .command_registry import DEFAULT_COMMAND_REGISTRY, CommandRegistry
from .command_types import ParsedCommand


_LEADING_TULI_PREFIXES = (
    "tuli,",
    "tuli:",
    "tuli ",
    "tuli-",
)

_SIMPLE_PHRASE_RULES: Tuple[Tuple[str, str, Tuple[str, ...], str, bool, str, str], ...] = (
    ("speak", r"\b(activa la voz|enciende la voz|habilita la voz|turn on voice|speak on)\b", ("on",), "voice", False, "simple voice on", "instant"),
    ("speak", r"\b(desactiva la voz|apaga la voz|turn off voice|speak off)\b", ("off",), "voice", False, "simple voice off", "instant"),
    ("status", r"\b(estado|status)\b", (), "info", False, "status request", "instant"),
    ("help", r"\b(ayuda|help)\b", (), "info", False, "help request", "instant"),
    ("clear", r"\b(limpia|limpiar|clear)\b", (), "session", False, "clear request", "instant"),
    ("debug", r"\b(debug|depura|abrir debug|abre debug)\b", (), "debug", False, "debug request", "instant"),
    ("macos", r"\b(macos|mac os|estado de macos|estado macos|observa macos|observar macos)\b", (), "system", False, "macos observation request", "instant"),
    ("apps", r"\b(apps|aplicaciones|aplicaciónes|what apps can you open|which apps can you open|qué aplicaciones puedes abrir|que aplicaciones puedes abrir)\b", (), "system", False, "apps list request", "instant"),
    ("instant", r"\b(modo rapido|modo rápido|instant|rápido|rapido)\b", (), "mode", False, "instant mode request", "instant"),
    ("thinking", r"\b(modo pensar|piensa|analiza bien|thinking)\b", (), "mode", False, "thinking mode request", "thinking"),
    ("memory", r"\b(memoria|memory)\b", (), "memory", False, "memory request", "thinking"),
    ("remember", r"\b(recuerda esto|remember this|guarda esto)\b", (), "memory", False, "remember request", "thinking"),
    ("forget", r"\b(olvida esto|forget this|borra ese recuerdo)\b", (), "memory", True, "forget request", "thinking"),
    ("summarize", r"\b(resume|resume esto|summarize)\b", (), "memory", False, "summarize request", "thinking"),
)

_OPEN_APP_PATTERN = re.compile(r"\b(?:abre|abrir|open|launch|lanza)\s+(?P<app>.+)$", re.IGNORECASE)
_OPEN_APP_REFERENCE_PATTERN = re.compile(
    r"\b(?:ábrela|abrirla|abrela|abre la|la abre|la abra|esa app|esa aplicación|esa aplicacion|open it|open this|launch it)\b",
    re.IGNORECASE,
)

_NATIVE_WINDOW_PHRASE_RULES: Tuple[Tuple[str, str], ...] = (
    ("top-left", r"\b(?:arriba\s+a\s+la\s+izquierda|esquina\s+superior\s+izquierda|top\s*-?\s*left)\b"),
    ("top-right", r"\b(?:arriba\s+a\s+la\s+derecha|esquina\s+superior\s+derecha|top\s*-?\s*right)\b"),
    ("bottom-left", r"\b(?:abajo\s+a\s+la\s+izquierda|esquina\s+inferior\s+izquierda|bottom\s*-?\s*left)\b"),
    ("bottom-right", r"\b(?:abajo\s+a\s+la\s+derecha|esquina\s+inferior\s+derecha|bottom\s*-?\s*right)\b"),
    ("quarters", r"\b(?:organiza(?:r)?|reorganiza(?:r)?|acomoda(?:r)?|ordena(?:r)?)\b.*\b(?:ventanas?|window|windows|cuartos?|quarters?|mosaico|grid|rejilla)\b"),
    ("quarters", r"\b(?:en\s+cuartos?|quarters?|mosaico|grid|rejilla)\b"),
    ("fill", r"\b(?:fill|llena(?:r)?|rellena(?:r)?|ocupa(?:r)?\s+(?:la\s+)?pantalla|maximiza(?:r)?|agranda(?:r)?)(?:\s+(?:esta|la)\s+ventana)?\b"),
    ("center", r"\b(?:center|centra(?:r)?|pon(?:er)?\s+(?:esta|la)?\s*ventana\s+en\s+el\s+centro|al\s+centro)\b"),
    ("left", r"\b(?:left|izquierda|lado\s+izquierdo|mitad\s+izquierda)\b"),
    ("right", r"\b(?:right|derecha|lado\s+derecho|mitad\s+derecha)\b"),
    ("top", r"\b(?:top|arriba|parte\s+superior|mitad\s+superior)\b"),
    ("bottom", r"\b(?:bottom|abajo|parte\s+inferior|mitad\s+inferior)\b"),
)

_SPACE_PHRASE_RULES: Tuple[Tuple[str, str], ...] = (
    ("mission-control", r"\b(?:mission\s+control|control\s+de\s+misiones|vista\s+de\s+escritorios)\b"),
    ("next", r"\b(?:siguiente|next|próximo|proximo)\b.*\b(?:space|spaces|escritorio|desktop)\b"),
    ("next", r"\b(?:cambia|ve|mueve(?:te)?|pasa)\b.*\b(?:space|spaces|escritorio|desktop)\b.*\b(?:siguiente|next|próximo|proximo)\b"),
    ("previous", r"\b(?:anterior|previous|previo|atrás|atras)\b.*\b(?:space|spaces|escritorio|desktop)\b"),
    ("previous", r"\b(?:cambia|ve|mueve(?:te)?|pasa)\b.*\b(?:space|spaces|escritorio|desktop)\b.*\b(?:anterior|previous|previo|atrás|atras)\b"),
    ("status", r"\b(?:estado|status)\b.*\b(?:space|spaces|escritorios|desktops)\b"),
)


def _normalize_text(text: str) -> str:
    return " ".join(text.strip().split())


def _strip_tuli_prefix(text: str) -> str:
    lowered = text.lower()
    for prefix in _LEADING_TULI_PREFIXES:
        if lowered.startswith(prefix):
            return text[len(prefix) :].lstrip(" ,:")
    return text


def _split_command_body(text: str) -> Tuple[str, Tuple[str, ...]]:
    cleaned = _normalize_text(text)
    if not cleaned:
        return "", ()
    parts = cleaned.split()
    return parts[0], tuple(parts[1:])


def _parse_open_app_candidate(text: str) -> Optional[Tuple[str, ...]]:
    match = _OPEN_APP_PATTERN.search(text.strip())
    if not match:
        return None

    app_text = _normalize_text(match.group("app"))
    app_text = app_text.strip(" ,.;:!?")
    if not app_text:
        return None

    app_text = re.split(r"\s+(?:y|and|then)\s+", app_text, maxsplit=1, flags=re.IGNORECASE)[0].strip()
    app_text = app_text.strip(" ,.;:!?")
    if not app_text:
        return None

    return (app_text,)


def _parse_native_window_candidate(text: str) -> Optional[Tuple[str, ...]]:
    lowered = text.lower().strip(" ,.;:!?")
    if not lowered:
        return None

    has_window_context = re.search(
        r"\b(?:ventana|ventanas|window|windows|layout|organiza|reorganiza|acomoda|ordena|pon|ponla|mueve|muévela|muevela|coloca|colócala|colocala|ubica|centra|llena|maximiza)\b",
        lowered,
    )
    if not has_window_context:
        return None

    for action, pattern in _NATIVE_WINDOW_PHRASE_RULES:
        if re.search(pattern, lowered):
            return ("native", action)
    return None


def _parse_space_candidate(text: str) -> Optional[Tuple[str, ...]]:
    lowered = text.lower().strip(" ,.;:!?")
    if not lowered:
        return None

    desktop_match = re.search(r"\b(?:escritorio|desktop|space)\s+(?P<number>[1-9])\b", lowered)
    if desktop_match and re.search(r"\b(?:ve|ir|cambia|cambiar|mueve(?:te)?|pasa|abre|switch|go)\b", lowered):
        return (desktop_match.group("number"),)

    for action, pattern in _SPACE_PHRASE_RULES:
        if re.search(pattern, lowered):
            return (action,)
    return None


def _parsed_command(
    *,
    raw_text: str,
    is_command: bool,
    command_name: Optional[str],
    command_args: Sequence[str] = (),
    command_kind: str = "chat",
    confidence: float = 0.0,
    parse_reason: str = "",
    requires_confirmation: bool = False,
    danger_level: str = "safe",
    requested_mode: str = "auto",
) -> ParsedCommand:
    return ParsedCommand(
        raw_text=raw_text,
        is_command=is_command,
        command_name=command_name,
        command_args=tuple(command_args),
        command_kind=command_kind,
        confidence=float(confidence),
        parse_reason=parse_reason,
        requires_confirmation=requires_confirmation,
        danger_level=danger_level,
        requested_mode=requested_mode,
    )


def parse_command(user_text: str, registry: CommandRegistry = DEFAULT_COMMAND_REGISTRY) -> ParsedCommand:
    if not isinstance(user_text, str):
        raise TypeError("user_text must be a string")

    raw_text = user_text.strip()
    if not raw_text:
        return _parsed_command(
            raw_text="",
            is_command=False,
            command_name=None,
            command_args=(),
            command_kind="chat",
            confidence=0.0,
            parse_reason="empty input",
        )

    if raw_text.startswith("/"):
        command_body = raw_text[1:]
        command_name, command_args = _split_command_body(command_body)
        canonical = registry.resolve_name(command_name) or command_name
        spec = registry.get(command_name)
        return _parsed_command(
            raw_text=raw_text,
            is_command=True,
            command_name=canonical,
            command_args=command_args,
            command_kind=spec.category if spec is not None else "general",
            confidence=0.99,
            parse_reason="slash command",
            requires_confirmation=registry.requires_confirmation(command_name),
            danger_level=registry.risk_for(command_name),
            requested_mode=spec.default_mode if spec is not None else "auto",
        )

    candidate = _strip_tuli_prefix(raw_text)
    lowered = candidate.lower()

    for command_name, pattern, args, category, requires_confirmation, reason, requested_mode in _SIMPLE_PHRASE_RULES:
        if re.search(pattern, lowered):
            spec = registry.get(command_name)
            risk = spec.risk if spec is not None else ("medium_risk" if requires_confirmation else "safe")
            return _parsed_command(
                raw_text=raw_text,
                is_command=True,
                command_name=command_name,
                command_args=args,
                command_kind=category,
                confidence=0.86,
                parse_reason=reason,
                requires_confirmation=requires_confirmation or registry.requires_confirmation(command_name),
                danger_level=risk,
                requested_mode=requested_mode,
            )

    # Soft phrase recognition for a few common intents that should still be
    # treated as command-like input.
    if lowered in {"rápido", "rapido", "instant"}:
        return _parsed_command(
            raw_text=raw_text,
            is_command=True,
            command_name="instant",
            command_args=(),
            command_kind="mode",
            confidence=0.9,
            parse_reason="explicit fast mode request",
            requested_mode="instant",
        )
    if lowered in {"piensa", "thinking", "analiza"}:
        return _parsed_command(
            raw_text=raw_text,
            is_command=True,
            command_name="thinking",
            command_args=(),
            command_kind="mode",
            confidence=0.9,
            parse_reason="explicit deep mode request",
            requested_mode="thinking",
        )

    space_args = _parse_space_candidate(candidate)
    if space_args is not None:
        return _parsed_command(
            raw_text=raw_text,
            is_command=True,
            command_name="space",
            command_args=space_args,
            command_kind="system",
            confidence=0.84,
            parse_reason="space control phrase",
            danger_level="safe",
            requested_mode="instant",
        )

    native_window_args = _parse_native_window_candidate(candidate)
    if native_window_args is not None:
        return _parsed_command(
            raw_text=raw_text,
            is_command=True,
            command_name="window",
            command_args=native_window_args,
            command_kind="system",
            confidence=0.84,
            parse_reason="native window tiling phrase",
            danger_level="safe",
            requested_mode="instant",
        )

    open_app_args = _parse_open_app_candidate(candidate)
    if open_app_args is not None:
        return _parsed_command(
            raw_text=raw_text,
            is_command=True,
            command_name="open",
            command_args=open_app_args,
            command_kind="system",
            confidence=0.88,
            parse_reason="open app request",
            danger_level="safe",
            requested_mode="instant",
        )

    if _OPEN_APP_REFERENCE_PATTERN.search(candidate):
        return _parsed_command(
            raw_text=raw_text,
            is_command=True,
            command_name="open",
            command_args=(),
            command_kind="system",
            confidence=0.84,
            parse_reason="open app reference",
            danger_level="safe",
            requested_mode="instant",
        )

    return _parsed_command(
        raw_text=raw_text,
        is_command=False,
        command_name=None,
        command_args=(),
        command_kind="chat",
        confidence=0.45,
        parse_reason="natural language chat",
    )


def command_name_or_none(parsed: ParsedCommand) -> Optional[str]:
    return parsed.command_name if parsed.is_command else None


def is_low_confidence(parsed: ParsedCommand) -> bool:
    return parsed.confidence < 0.7


def parse_many(texts: Iterable[str], registry: CommandRegistry = DEFAULT_COMMAND_REGISTRY) -> List[ParsedCommand]:
    return [parse_command(text, registry=registry) for text in texts]
