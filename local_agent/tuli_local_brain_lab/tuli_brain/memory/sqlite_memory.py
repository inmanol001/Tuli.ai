from __future__ import annotations

import json
import sqlite3
import uuid
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional


SCHEMA_VERSION = 1
SEED_SOURCE = "tuli_brain_seed_v1"


SEED_CORE_MEMORIES = [
    "The avatar's name is Tuli.",
    "Tuli is the user's local floating desktop companion.",
    "Tuli should be concise, warm, playful, and non-invasive.",
    "Tuli should not invent facts.",
    "Tuli should say she does not know when context is missing.",
    "Tuli should use local-first memory only.",
    "Tuli uses local Ollama for text generation by default.",
    "Tuli uses local Kokoro voice af_bella by default.",
]


VALID_MEMORY_KINDS = frozenset(
    {
        "core",
        "preference",
        "project_rule",
        "technical_warning",
        "episodic",
        "task_context",
    }
)

SEARCH_STOPWORDS = frozenset(
    {
        "hola",
        "hello",
        "hey",
        "tuli",
        "por",
        "para",
        "con",
        "que",
        "qué",
        "como",
        "cómo",
        "the",
        "and",
        "you",
        "are",
        "what",
        "how",
    }
)


def utc_now() -> str:
    return datetime.utcnow().replace(microsecond=0).isoformat() + "Z"


def make_memory_id() -> str:
    return "mem_" + uuid.uuid4().hex[:12]


@dataclass(frozen=True)
class MemoryItem:
    id: str
    kind: str
    text: str
    source: str
    created_at: str
    updated_at: str
    importance: float = 0.5
    confidence: float = 0.8
    tags: List[str] = field(default_factory=list)
    project: Optional[str] = None
    session_id: Optional[str] = None
    ttl: Optional[str] = None
    archived: bool = False

    def to_dict(self) -> Dict[str, Any]:
        return {
            "id": self.id,
            "kind": self.kind,
            "text": self.text,
            "source": self.source,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
            "importance": self.importance,
            "confidence": self.confidence,
            "tags": list(self.tags or []),
            "project": self.project,
            "session_id": self.session_id,
            "ttl": self.ttl,
            "archived": self.archived,
        }


class SQLiteMemoryStore:
    def __init__(self, db_path: str | Path):
        self.db_path = Path(db_path).expanduser()

    def connect(self) -> sqlite3.Connection:
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(str(self.db_path))
        conn.row_factory = sqlite3.Row
        return conn

    def initialize(self) -> None:
        with self.connect() as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS metadata (
                  key TEXT PRIMARY KEY,
                  value TEXT NOT NULL
                )
                """
            )
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS memories (
                  id TEXT PRIMARY KEY,
                  kind TEXT NOT NULL,
                  text TEXT NOT NULL,
                  source TEXT,
                  created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL,
                  importance REAL DEFAULT 0.5,
                  confidence REAL DEFAULT 0.8,
                  tags_json TEXT DEFAULT '[]',
                  project TEXT,
                  session_id TEXT,
                  ttl TEXT,
                  archived INTEGER DEFAULT 0
                )
                """
            )
            conn.execute("CREATE INDEX IF NOT EXISTS idx_memories_kind ON memories(kind)")
            conn.execute("CREATE INDEX IF NOT EXISTS idx_memories_archived ON memories(archived)")
            conn.execute("CREATE INDEX IF NOT EXISTS idx_memories_updated_at ON memories(updated_at)")
            conn.execute(
                "INSERT OR REPLACE INTO metadata(key, value) VALUES (?, ?)",
                ("schema_version", str(SCHEMA_VERSION)),
            )
            conn.commit()
        self.ensure_seed()

    def path(self) -> str:
        return str(self.db_path)

    def ensure_seed(self) -> None:
        with self.connect() as conn:
            existing = conn.execute(
                "SELECT COUNT(*) AS count FROM memories WHERE source = ?",
                (SEED_SOURCE,),
            ).fetchone()["count"]
            if existing:
                return
            now = utc_now()
            for text in SEED_CORE_MEMORIES:
                conn.execute(
                    """
                    INSERT INTO memories (
                      id, kind, text, source, created_at, updated_at,
                      importance, confidence, tags_json, archived
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
                    """,
                    (
                        make_memory_id(),
                        "core",
                        text,
                        SEED_SOURCE,
                        now,
                        now,
                        1.0,
                        1.0,
                        json.dumps(["seed", "identity"], ensure_ascii=False),
                    ),
                )
            conn.commit()

    def add_memory(
        self,
        *,
        kind: str,
        text: str,
        source: str,
        importance: float = 0.5,
        confidence: float = 0.8,
        tags: Optional[Iterable[str]] = None,
        project: Optional[str] = None,
        session_id: Optional[str] = None,
        ttl: Optional[str] = None,
    ) -> MemoryItem:
        kind = kind.strip()
        text = text.strip()
        source = source.strip()
        if kind not in VALID_MEMORY_KINDS:
            raise ValueError(f"invalid memory kind: {kind}")
        if not text:
            raise ValueError("memory text must not be empty")
        if not source:
            raise ValueError("memory source must not be empty")

        now = utc_now()
        item = MemoryItem(
            id=make_memory_id(),
            kind=kind,
            text=text,
            source=source,
            created_at=now,
            updated_at=now,
            importance=float(importance),
            confidence=float(confidence),
            tags=list(tags or []),
            project=project,
            session_id=session_id,
            ttl=ttl,
            archived=False,
        )
        with self.connect() as conn:
            conn.execute(
                """
                INSERT INTO memories (
                  id, kind, text, source, created_at, updated_at,
                  importance, confidence, tags_json, project, session_id, ttl, archived
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
                """,
                (
                    item.id,
                    item.kind,
                    item.text,
                    item.source,
                    item.created_at,
                    item.updated_at,
                    item.importance,
                    item.confidence,
                    json.dumps(item.tags or [], ensure_ascii=False),
                    item.project,
                    item.session_id,
                    item.ttl,
                ),
            )
            conn.commit()
        return item

    def list_memories(
        self,
        *,
        kind: Optional[str] = None,
        include_archived: bool = False,
        limit: int = 50,
    ) -> List[MemoryItem]:
        clauses = []
        params: List[Any] = []
        if kind:
            clauses.append("kind = ?")
            params.append(kind)
        if not include_archived:
            clauses.append("archived = 0")
        where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
        params.append(int(limit))
        query = f"""
            SELECT * FROM memories
            {where}
            ORDER BY importance DESC, updated_at DESC
            LIMIT ?
        """
        with self.connect() as conn:
            rows = conn.execute(query, params).fetchall()
        return [self._row_to_item(row) for row in rows]

    def list_recent(self, *, limit: int = 20, include_archived: bool = False) -> List[MemoryItem]:
        clauses = []
        params: List[Any] = []
        if not include_archived:
            clauses.append("archived = 0")
        where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
        params.append(int(limit))
        query = f"""
            SELECT * FROM memories
            {where}
            ORDER BY updated_at DESC
            LIMIT ?
        """
        with self.connect() as conn:
            rows = conn.execute(query, params).fetchall()
        return [self._row_to_item(row) for row in rows]

    def search_memories(self, query: str, *, limit: int = 10) -> List[MemoryItem]:
        terms = [
            term.lower().strip(".,!?¿¡:;()[]{}\"'")
            for term in query.split()
            if len(term) >= 3
        ]
        terms = [term for term in terms if term and term not in SEARCH_STOPWORDS]
        if not terms:
            return self.list_memories(limit=limit)
        candidates = self.list_memories(limit=200)
        scored = []
        for item in candidates:
            lowered = item.text.lower()
            score = sum(1 for term in terms if term in lowered)
            if score:
                scored.append((score, item.importance, item.updated_at, item))
        scored.sort(key=lambda row: (row[0], row[1], row[2]), reverse=True)
        return [row[3] for row in scored[:limit]]

    def count(self, *, include_archived: bool = False) -> int:
        where = "" if include_archived else "WHERE archived = 0"
        with self.connect() as conn:
            return int(conn.execute(f"SELECT COUNT(*) AS count FROM memories {where}").fetchone()["count"])

    def count_by_kind(self) -> Dict[str, int]:
        with self.connect() as conn:
            rows = conn.execute(
                """
                SELECT kind, COUNT(*) AS count
                FROM memories
                WHERE archived = 0
                GROUP BY kind
                ORDER BY kind
                """
            ).fetchall()
        return {str(row["kind"]): int(row["count"]) for row in rows}

    def archive_memory(self, memory_id: str) -> bool:
        memory_id = memory_id.strip()
        if not memory_id:
            raise ValueError("memory_id must not be empty")
        with self.connect() as conn:
            cursor = conn.execute(
                """
                UPDATE memories
                SET archived = 1, updated_at = ?
                WHERE id = ? AND archived = 0
                """,
                (utc_now(), memory_id),
            )
            conn.commit()
        return cursor.rowcount > 0

    @staticmethod
    def _row_to_item(row: sqlite3.Row) -> MemoryItem:
        try:
            tags = json.loads(row["tags_json"] or "[]")
        except json.JSONDecodeError:
            tags = []
        if not isinstance(tags, list):
            tags = []
        return MemoryItem(
            id=row["id"],
            kind=row["kind"],
            text=row["text"],
            source=row["source"] or "",
            created_at=row["created_at"],
            updated_at=row["updated_at"],
            importance=float(row["importance"]),
            confidence=float(row["confidence"]),
            tags=[str(tag) for tag in tags],
            project=row["project"],
            session_id=row["session_id"],
            ttl=row["ttl"],
            archived=bool(row["archived"]),
        )
