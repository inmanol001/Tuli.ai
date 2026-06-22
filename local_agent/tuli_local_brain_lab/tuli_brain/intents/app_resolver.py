from __future__ import annotations

from typing import Optional

from ..macos_control import list_known_applications


_APP_ALIAS_MAP = {
    "browser": ("Google Chrome", "Safari"),
    "navegador": ("Google Chrome", "Safari"),
    "chrome": ("Google Chrome",),
    "google chrome": ("Google Chrome",),
    "safari": ("Safari",),
    "terminal": ("Terminal",),
    "finder": ("Finder",),
    "notas": ("Notes",),
    "notes": ("Notes",),
    "code": ("Visual Studio Code",),
    "vs code": ("Visual Studio Code",),
    "codigo": ("Visual Studio Code",),
    "código": ("Visual Studio Code",),
    "editor": ("Visual Studio Code",),
    "vscode": ("Visual Studio Code",),
    "capcut": ("CapCut",),
}


def normalize_app_alias(alias: str) -> str:
    return " ".join(str(alias or "").strip().lower().split())


def known_app_preference(alias: str) -> Optional[str]:
    normalized = normalize_app_alias(alias)
    candidates = _APP_ALIAS_MAP.get(normalized, ())
    if not candidates:
        return None

    known_apps = set(list_known_applications())
    for candidate in candidates:
        if candidate in known_apps:
            return candidate
    return candidates[0] if candidates else None


def resolve_app_name(text_or_alias: str) -> Optional[str]:
    normalized = normalize_app_alias(text_or_alias)
    if not normalized:
        return None
    preferred = known_app_preference(normalized)
    if preferred:
        return preferred

    for known in list_known_applications():
        if normalize_app_alias(known) == normalized:
            return known
    return None
