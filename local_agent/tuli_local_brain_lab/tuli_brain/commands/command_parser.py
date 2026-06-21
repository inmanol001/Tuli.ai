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
