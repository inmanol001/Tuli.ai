from __future__ import annotations

import json
import os
import re
import uuid
from collections import Counter
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence

from ..events.jsonl_writer import tail_jsonl_lines, write_jsonl_events
from .activity_types import (
    ACTIVITY_KINDS,
    ACTIVITY_PRIVACY_LEVELS,
    ACTIVITY_SEVERITIES,
    ActivityRecord,
    ActivitySummary,
    ActivityWriteResult,
)


DEFAULT_SESSION_ID = "local_session"
DEFAULT_SOURCE = "activity_watcher"
MAX_SUMMARY_CHARS = 180


_PATH_PATTERN = re.compile(r"(/[^ \n\t\r\f\v]+)")
_EMAIL_PATTERN = re.compile(r"\b[\w.+-]+@[\w-]+\.[\w.-]+\b")


def utc_now() -> str:
    return datetime.utcnow().replace(microsecond=0).isoformat() + "Z"


def make_activity_id(prefix: str = "act") -> str:
    return f"{prefix}_{uuid.uuid4().hex[:12]}"


def _session_id() -> str:
    return os.environ.get("TULI_SESSION_ID", DEFAULT_SESSION_ID).strip() or DEFAULT_SESSION_ID


def _limit_text(text: str, *, max_chars: int = MAX_SUMMARY_CHARS) -> str:
    clean = " ".join(str(text).split())
    if len(clean) <= max_chars:
        return clean
    return clean[: max_chars - 3].rstrip() + "..."


def _coarsen(text: Optional[str]) -> Optional[str]:
    if text is None:
        return None
    clean = _EMAIL_PATTERN.sub("[email]", text)
    clean = _PATH_PATTERN.sub("[path]", clean)
    return _limit_text(clean)


def make_activity_record(
    *,
    kind: str,
    summary: str,
    source: str = DEFAULT_SOURCE,
    severity: str = "info",
    privacy_level: str = "coarse",
    app_name: Optional[str] = None,
    window_title: Optional[str] = None,
    turn_id: Optional[str] = None,
    command_name: Optional[str] = None,
    route: Optional[str] = None,
    model_used: Optional[str] = None,
    tags: Optional[Iterable[str]] = None,
    metadata: Optional[Mapping[str, Any]] = None,
) -> ActivityRecord:
    kind = kind.strip()
    source = source.strip()
    severity = severity.strip()
    privacy_level = privacy_level.strip()
    if kind not in ACTIVITY_KINDS:
        raise ValueError(f"invalid activity kind: {kind}")
    if source != DEFAULT_SOURCE and not source:
        raise ValueError("source must not be empty")
    if severity not in ACTIVITY_SEVERITIES:
        raise ValueError(f"invalid severity: {severity}")
    if privacy_level not in ACTIVITY_PRIVACY_LEVELS:
        raise ValueError(f"invalid privacy level: {privacy_level}")

    return ActivityRecord(
        activity_id=make_activity_id(),
        ts=utc_now(),
        session_id=_session_id(),
        source=source,
        kind=kind,
        summary=_limit_text(summary),
        severity=severity,
        privacy_level=privacy_level,
        app_name=_coarsen(app_name),
        window_title=_coarsen(window_title),
        turn_id=turn_id,
        command_name=command_name,
        route=route,
        model_used=model_used,
        tags=tuple(str(tag) for tag in (tags or ()) if str(tag).strip()),
        metadata=dict(metadata or {}),
    )


class ActivityWatcher:
    """Append-only, privacy-conscious local activity history."""

    def __init__(self, path: str | Path):
        self.path = Path(path).expanduser()

    def ensure_parent(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)

    def record(self, record: ActivityRecord) -> ActivityWriteResult:
        return self.record_many([record])

    def record_many(self, records: Sequence[ActivityRecord]) -> ActivityWriteResult:
        self.ensure_parent()
        written = write_jsonl_events(self.path, [record.to_dict() for record in records])
        return ActivityWriteResult(path=written["path"], written_count=written["written_count"], dropped_count=0)

    def record_turn(
        self,
        *,
        user_text: str,
        response_text: str,
        turn_id: Optional[str] = None,
        command_name: Optional[str] = None,
        route: Optional[str] = None,
        model_used: Optional[str] = None,
        mode: Optional[str] = None,
        app_name: Optional[str] = None,
        window_title: Optional[str] = None,
        metadata: Optional[Mapping[str, Any]] = None,
    ) -> ActivityWriteResult:
        summary_bits = [
            "turn completed",
            f"route={route or 'chat'}",
            f"mode={mode or 'instant'}",
            f"model={model_used or 'unknown'}",
        ]
        if command_name:
            summary_bits.insert(1, f"command={command_name}")
        if app_name:
            summary_bits.append(f"app={_coarsen(app_name) or 'unknown'}")
        record = make_activity_record(
            kind="turn",
            summary="; ".join(summary_bits),
            turn_id=turn_id,
            command_name=command_name,
            route=route,
            model_used=model_used,
            app_name=app_name,
            window_title=window_title,
            tags=("turn", "chat"),
            metadata={
                "response_chars": len(response_text.strip()),
                "user_chars": len(user_text.strip()),
                **dict(metadata or {}),
            },
        )
        return self.record(record)

    def last_opened_app(self, *, lines: int = 50) -> Optional[str]:
        for record in reversed(self.list_recent(lines=lines)):
            if record.kind != "turn":
                continue
            if record.command_name != "open":
                continue
            if record.app_name:
                return record.app_name
            maybe_app = record.metadata.get("app_name") if isinstance(record.metadata, Mapping) else None
            if isinstance(maybe_app, str) and maybe_app.strip():
                return maybe_app.strip()
        return None

    def record_app_focus(
        self,
        app_name: str,
        *,
        window_title: Optional[str] = None,
        source: str = "observer",
        severity: str = "info",
    ) -> ActivityWriteResult:
        record = make_activity_record(
            kind="app_focus",
            summary=f"frontmost app: {_coarsen(app_name) or 'unknown'}",
            source=source,
            severity=severity,
            app_name=app_name,
            window_title=window_title,
            tags=("focus",),
        )
        return self.record(record)

    def record_window_focus(
        self,
        app_name: str,
        *,
        window_title: Optional[str] = None,
        source: str = "observer",
        severity: str = "info",
    ) -> ActivityWriteResult:
        record = make_activity_record(
            kind="window_focus",
            summary=f"window focus changed in {_coarsen(app_name) or 'unknown'}",
            source=source,
            severity=severity,
            app_name=app_name,
            window_title=window_title,
            tags=("focus", "window"),
        )
        return self.record(record)

    def record_note(
        self,
        text: str,
        *,
        source: str = "manual",
        severity: str = "info",
        metadata: Optional[Mapping[str, Any]] = None,
    ) -> ActivityWriteResult:
        record = make_activity_record(
            kind="note",
            summary=text,
            source=source,
            severity=severity,
            privacy_level="manual",
            metadata=metadata,
            tags=("note",),
        )
        return self.record(record)

    def tail(self, *, lines: int = 20) -> List[Dict[str, Any]]:
        return [
            json.loads(line)
            for line in tail_jsonl_lines(self.path, lines=lines)
            if line.strip()
        ]

    def count(self) -> int:
        if not self.path.exists():
            return 0
        with self.path.open("r", encoding="utf-8") as stream:
            return sum(1 for line in stream if line.strip())

    def exists(self) -> bool:
        return self.path.exists()

    def list_recent(self, *, lines: int = 20) -> List[ActivityRecord]:
        if not self.path.exists():
            return []
        records: List[ActivityRecord] = []
        for line in tail_jsonl_lines(self.path, lines=lines):
            if not line.strip():
                continue
            try:
                data = json.loads(line)
            except json.JSONDecodeError:
                continue
            records.append(_record_from_dict(data))
        return records

    def summarize_recent(self, *, lines: int = 20) -> ActivitySummary:
        records = self.list_recent(lines=lines)
        if not records:
            return ActivitySummary(
                text="No recent activity.",
                session_id=_session_id(),
                source=DEFAULT_SOURCE,
            )

        counter = Counter(record.kind for record in records)
        recent_kinds = tuple(record.kind for record in records[-5:])
        last = records[-1]
        text = (
            f"{len(records)} recent activity items. "
            f"Latest: {last.kind}. "
            f"Top kinds: {', '.join(f'{kind}={count}' for kind, count in counter.most_common(3))}."
        )
        return ActivitySummary(
            text=text,
            session_id=_session_id(),
            source=DEFAULT_SOURCE,
            activity_ids=tuple(record.activity_id for record in records),
            recent_kinds=recent_kinds,
        )

    def context_block(self, *, lines: int = 10) -> str:
        summary = self.summarize_recent(lines=lines)
        return "\n".join(
            [
                "[Activity]",
                f"- {summary.text}",
            ]
        )

    def clear(self) -> None:
        if self.path.exists():
            self.path.write_text("", encoding="utf-8")

    def to_dict(self) -> Dict[str, Any]:
        return {"path": str(self.path), "exists": self.exists(), "count": self.count()}


def _record_from_dict(data: Mapping[str, Any]) -> ActivityRecord:
    return ActivityRecord(
        activity_id=str(data.get("activity_id") or make_activity_id()),
        ts=str(data.get("ts") or utc_now()),
        session_id=str(data.get("session_id") or _session_id()),
        source=str(data.get("source") or DEFAULT_SOURCE),
        kind=str(data.get("kind") or "note"),
        summary=str(data.get("summary") or ""),
        severity=str(data.get("severity") or "info"),
        privacy_level=str(data.get("privacy_level") or "coarse"),
        app_name=data.get("app_name"),
        window_title=data.get("window_title"),
        turn_id=data.get("turn_id"),
        command_name=data.get("command_name"),
        route=data.get("route"),
        model_used=data.get("model_used"),
        tags=tuple(str(tag) for tag in data.get("tags", []) if str(tag).strip()),
        metadata=dict(data.get("metadata") or {}),
    )


def summarize_activity_records(records: Sequence[ActivityRecord]) -> ActivitySummary:
    if not records:
        return ActivitySummary(text="No recent activity.", session_id=_session_id(), source=DEFAULT_SOURCE)
    counter = Counter(record.kind for record in records)
    recent_kinds = tuple(record.kind for record in records[-5:])
    text = (
        f"{len(records)} activity items. "
        f"Top kinds: {', '.join(f'{kind}={count}' for kind, count in counter.most_common(3))}."
    )
    return ActivitySummary(
        text=text,
        session_id=_session_id(),
        source=DEFAULT_SOURCE,
        activity_ids=tuple(record.activity_id for record in records),
        recent_kinds=recent_kinds,
    )


def tail_activity_records(path: str | Path, *, lines: int = 20) -> List[Dict[str, Any]]:
    watcher = ActivityWatcher(path)
    return watcher.tail(lines=lines)
