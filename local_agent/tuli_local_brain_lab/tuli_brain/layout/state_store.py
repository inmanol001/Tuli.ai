from __future__ import annotations

import json
from pathlib import Path
from typing import Optional

from ..config import APP_SUPPORT, WORKSPACE_SUPPORT
from .models import LayoutState
from .presets import build_normal_state


DEFAULT_LAYOUT_STATE_PATH = APP_SUPPORT / "tuli_layout_state.json"
DEFAULT_FALLBACK_LAYOUT_STATE_PATH = WORKSPACE_SUPPORT / "tuli_layout_state.json"


class LayoutStateStore:
    def __init__(self, path: str | Path = DEFAULT_LAYOUT_STATE_PATH):
        self.path = Path(path).expanduser()
        self.fallback_path = DEFAULT_FALLBACK_LAYOUT_STATE_PATH
        self._uses_default_path = self.path == DEFAULT_LAYOUT_STATE_PATH

    def ensure_parent(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)

    def _write_json_text(self, path: Path, payload: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(payload, encoding="utf-8")

    def _fallback_write(self, payload: str) -> Path:
        self.fallback_path.parent.mkdir(parents=True, exist_ok=True)
        self.fallback_path.write_text(payload, encoding="utf-8")
        self.path = self.fallback_path
        return self.path

    def read(self) -> Optional[LayoutState]:
        candidates = (self.path, self.fallback_path) if self._uses_default_path else (self.path,)
        for candidate in candidates:
            if not candidate.exists():
                continue
            try:
                payload = json.loads(candidate.read_text(encoding="utf-8"))
            except Exception:
                continue
            if not isinstance(payload, dict):
                continue
            self.path = candidate
            return LayoutState.from_dict(payload).normalized()
        return None

    def read_or_create(self) -> LayoutState:
        state = self.read()
        if state is not None:
            return state
        state = build_normal_state()
        self.write(state)
        return state

    def write(self, state: LayoutState) -> LayoutState:
        normalized = state.normalized()
        payload = json.dumps(normalized.to_dict(), ensure_ascii=False, indent=2)
        try:
            self._write_json_text(self.path, payload)
        except PermissionError:
            self._fallback_write(payload)
        return normalized

    def clear(self) -> LayoutState:
        state = build_normal_state()
        self.write(state)
        return state
