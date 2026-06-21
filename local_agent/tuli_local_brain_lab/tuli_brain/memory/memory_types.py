from __future__ import annotations

from dataclasses import dataclass, field, asdict
from typing import Any, Dict, Iterable, List, Mapping, Optional, Tuple


MEMORY_KINDS = (
    "core",
    "preference",
    "project_rule",
    "technical_warning",
    "episodic",
    "task_context",
)


@dataclass(frozen=True)
class MemoryRecord:
    """Durable local memory record."""

    id: str
    kind: str
    text: str
    source: str
    created_at: str
    updated_at: str
    importance: float = 0.5
    confidence: float = 0.8
    tags: Tuple[str, ...] = ()
    project: Optional[str] = None
    session_id: Optional[str] = None
    ttl: Optional[str] = None
    archived: bool = False

    def to_dict(self) -> Dict[str, Any]:
        data = asdict(self)
        data["tags"] = list(self.tags)
        return data


@dataclass(frozen=True)
class SessionRecord:
    """Durable local session record used by the memory layer."""

    session_id: str
    source: str
    created_at: str
    updated_at: str
    label: Optional[str] = None
    turn_count: int = 0
    last_user_text: Optional[str] = None
    last_assistant_text: Optional[str] = None
    archived: bool = False
    metadata: Mapping[str, Any] = field(default_factory=dict)

    def to_dict(self) -> Dict[str, Any]:
        data = asdict(self)
        data["metadata"] = dict(self.metadata)
        return data


@dataclass(frozen=True)
class SessionSummary:
    """Compact summary for a stored local session."""

    session_id: str
    text: str
    source: str
    created_at: str
    updated_at: str
    memory_ids: Tuple[str, ...] = ()

    def to_dict(self) -> Dict[str, Any]:
        data = asdict(self)
        data["memory_ids"] = list(self.memory_ids)
        return data


@dataclass(frozen=True)
class MemoryWriteResult:
    """Result returned by a write operation in the memory store."""

    ok: bool
    kind: str
    item_id: Optional[str] = None
    session_id: Optional[str] = None
    source: Optional[str] = None
    created_at: Optional[str] = None
    updated_at: Optional[str] = None
    details: Mapping[str, Any] = field(default_factory=dict)
    error: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        data = asdict(self)
        data["details"] = dict(self.details)
        return data


@dataclass(frozen=True)
class MemoryQuery:
    """Filter used to retrieve memory records."""

    kind: Optional[str] = None
    text: Optional[str] = None
    project: Optional[str] = None
    session_id: Optional[str] = None
    include_archived: bool = False
    limit: int = 20

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True)
class MemorySummary:
    """Compact summary returned by the memory layer."""

    text: str
    source: str
    memory_ids: Tuple[str, ...] = ()
    session_id: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        data = asdict(self)
        data["memory_ids"] = list(self.memory_ids)
        return data
