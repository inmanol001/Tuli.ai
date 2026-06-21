from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Optional

from .debug_types import DEBUG_LEVELS, DebugSnapshot


DEBUG_FILE_SUFFIX = ".jsonl"


@dataclass(frozen=True)
class DebugWriteResult:
    """Result of writing one or more debug snapshots."""

    path: str
    written_count: int

    def to_dict(self) -> Dict[str, Any]:
        return {"path": self.path, "written_count": self.written_count}


class DebugStore:
    """Append-only local debug store for Tuli turns."""

    def __init__(self, path: str | Path):
        self.path = Path(path).expanduser()

    def ensure_parent(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)

    def write_snapshot(self, snapshot: DebugSnapshot) -> DebugWriteResult:
        return self.write_snapshots([snapshot])

    def write_snapshots(self, snapshots: Iterable[DebugSnapshot]) -> DebugWriteResult:
        self.ensure_parent()
        written = 0
        with self.path.open("a", encoding="utf-8") as stream:
            for snapshot in snapshots:
                stream.write(json.dumps(snapshot.to_dict(), ensure_ascii=False, separators=(",", ":")) + "\n")
                written += 1
        return DebugWriteResult(path=str(self.path), written_count=written)

    def tail(self, *, lines: int = 20) -> List[Dict[str, Any]]:
        if not self.path.exists():
            return []
        with self.path.open("r", encoding="utf-8") as stream:
            raw_lines = [line.rstrip("\n") for line in stream.readlines()[-lines:]]
        items: List[Dict[str, Any]] = []
        for line in raw_lines:
            if not line.strip():
                continue
            try:
                items.append(json.loads(line))
            except json.JSONDecodeError:
                items.append({"raw": line})
        return items

    def clear(self) -> None:
        if self.path.exists():
            self.path.write_text("", encoding="utf-8")

    def exists(self) -> bool:
        return self.path.exists()

    def count(self) -> int:
        if not self.path.exists():
            return 0
        with self.path.open("r", encoding="utf-8") as stream:
            return sum(1 for line in stream if line.strip())

    def to_dict(self) -> Dict[str, Any]:
        return {"path": str(self.path), "exists": self.exists(), "count": self.count()}


def make_debug_snapshot(
    *,
    session_id: str,
    turn_id: str,
    user_text: str,
    intent: str,
    command: str,
    risk: str,
    requires_confirmation: bool,
    mode: str,
    model_used: str,
    prompt_final: str,
    raw_response: str,
    clean_response: str,
    actions: Iterable[Mapping[str, Any]] = (),
    events: Iterable[str] = (),
    error: Optional[Mapping[str, Any]] = None,
) -> DebugSnapshot:
    return DebugSnapshot(
        session_id=session_id,
        turn_id=turn_id,
        user_text=user_text,
        intent=intent,
        command=command,
        risk=risk,
        requires_confirmation=requires_confirmation,
        mode=mode,
        model_used=model_used,
        prompt_final=prompt_final,
        raw_response=raw_response,
        clean_response=clean_response,
        actions=tuple(actions),
        events=tuple(events),
        error=error,
    )


def tail_debug_snapshots(path: str | Path, *, lines: int = 20) -> List[Dict[str, Any]]:
    return DebugStore(path).tail(lines=lines)

