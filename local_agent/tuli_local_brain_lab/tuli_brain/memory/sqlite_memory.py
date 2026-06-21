from __future__ import annotations

import json
import sqlite3
import uuid
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional

from .memory_types import MemoryQuery, MemorySummary, MemoryWriteResult, SessionRecord, SessionSummary

SCHEMA_VERSION = 2
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
                CREATE TABLE IF NOT EXISTS sessions (
                  session_id TEXT PRIMARY KEY,
                  source TEXT NOT NULL,
                  label TEXT,
                  created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL,
                  turn_count INTEGER DEFAULT 0,
                  last_user_text TEXT,
                  last_assistant_text TEXT,
                  archived INTEGER DEFAULT 0,
                  metadata_json TEXT DEFAULT '{}'
                )
                """
            )
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS session_summaries (
                  session_id TEXT PRIMARY KEY,
                  text TEXT NOT NULL,
                  source TEXT NOT NULL,
                  created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL,
                  memory_ids_json TEXT DEFAULT '[]',
                  FOREIGN KEY(session_id) REFERENCES sessions(session_id)
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
            conn.execute("CREATE INDEX IF NOT EXISTS idx_sessions_updated_at ON sessions(updated_at)")
            conn.execute("CREATE INDEX IF NOT EXISTS idx_sessions_archived ON sessions(archived)")
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

    def upsert_session(
        self,
        session_id: str,
        *,
        source: str = "brain.respond",
        label: Optional[str] = None,
        last_user_text: Optional[str] = None,
        last_assistant_text: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
        archived: Optional[bool] = None,
        count_turn: bool = False,
    ) -> SessionRecord:
        session_id = session_id.strip()
        source = source.strip()
        if not session_id:
            raise ValueError("session_id must not be empty")
        if not source:
            raise ValueError("source must not be empty")

        now = utc_now()
        metadata = dict(metadata or {})
        turn_increment = 1 if count_turn and (last_user_text is not None or last_assistant_text is not None) else 0

        with self.connect() as conn:
            current = conn.execute(
                "SELECT * FROM sessions WHERE session_id = ?",
                (session_id,),
            ).fetchone()
            if current is None:
                conn.execute(
                    """
                    INSERT INTO sessions (
                      session_id, source, label, created_at, updated_at,
                      turn_count, last_user_text, last_assistant_text, archived, metadata_json
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        session_id,
                        source,
                        label,
                        now,
                        now,
                        turn_increment,
                        last_user_text,
                        last_assistant_text,
                        int(bool(archived)) if archived is not None else 0,
                        json.dumps(metadata, ensure_ascii=False),
                    ),
                )
            else:
                new_metadata = metadata or self._safe_json_loads(current["metadata_json"] or "{}")
                conn.execute(
                    """
                    UPDATE sessions
                    SET source = ?,
                        label = COALESCE(?, label),
                        updated_at = ?,
                        turn_count = turn_count + ?,
                        last_user_text = COALESCE(?, last_user_text),
                        last_assistant_text = COALESCE(?, last_assistant_text),
                        archived = COALESCE(?, archived),
                        metadata_json = ?
                    WHERE session_id = ?
                    """,
                    (
                        source,
                        label,
                        now,
                        turn_increment,
                        last_user_text,
                        last_assistant_text,
                        int(archived) if archived is not None else None,
                        json.dumps(new_metadata, ensure_ascii=False),
                        session_id,
                    ),
                )
            conn.commit()

        return self.get_session(session_id) or SessionRecord(
            session_id=session_id,
            source=source,
            created_at=now,
            updated_at=now,
        )

    def get_session(self, session_id: str) -> Optional[SessionRecord]:
        session_id = session_id.strip()
        if not session_id:
            raise ValueError("session_id must not be empty")
        with self.connect() as conn:
            row = conn.execute("SELECT * FROM sessions WHERE session_id = ?", (session_id,)).fetchone()
        if row is None:
            return None
        return self._row_to_session(row)

    def list_sessions(
        self,
        *,
        limit: int = 20,
        include_archived: bool = False,
    ) -> List[SessionRecord]:
        where = "" if include_archived else "WHERE archived = 0"
        with self.connect() as conn:
            rows = conn.execute(
                f"""
                SELECT * FROM sessions
                {where}
                ORDER BY updated_at DESC
                LIMIT ?
                """,
                (int(limit),),
            ).fetchall()
        return [self._row_to_session(row) for row in rows]

    def count_sessions(self, *, include_archived: bool = False) -> int:
        where = "" if include_archived else "WHERE archived = 0"
        with self.connect() as conn:
            return int(conn.execute(f"SELECT COUNT(*) AS count FROM sessions {where}").fetchone()["count"])

    def count_session_summaries(self) -> int:
        with self.connect() as conn:
            return int(conn.execute("SELECT COUNT(*) AS count FROM session_summaries").fetchone()["count"])

    def get_session_summary(self, session_id: str) -> Optional[SessionSummary]:
        session_id = session_id.strip()
        if not session_id:
            raise ValueError("session_id must not be empty")
        with self.connect() as conn:
            row = conn.execute(
                "SELECT * FROM session_summaries WHERE session_id = ?",
                (session_id,),
            ).fetchone()
        if row is None:
            return None
        return self._row_to_session_summary(row)

    def save_session_summary(
        self,
        session_id: str,
        text: str,
        *,
        source: str = "memory.summarizer",
        memory_ids: Optional[Iterable[str]] = None,
    ) -> SessionSummary:
        session_id = session_id.strip()
        text = text.strip()
        source = source.strip()
        if not session_id:
            raise ValueError("session_id must not be empty")
        if not text:
            raise ValueError("summary text must not be empty")
        if not source:
            raise ValueError("source must not be empty")

        now = utc_now()
        memory_ids_tuple = tuple(str(item).strip() for item in (memory_ids or ()) if str(item).strip())

        self.upsert_session(session_id, source=source)

        with self.connect() as conn:
            conn.execute(
                """
                INSERT INTO session_summaries (
                  session_id, text, source, created_at, updated_at, memory_ids_json
                ) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(session_id) DO UPDATE SET
                  text = excluded.text,
                  source = excluded.source,
                  updated_at = excluded.updated_at,
                  memory_ids_json = excluded.memory_ids_json
                """,
                (
                    session_id,
                    text,
                    source,
                    now,
                    now,
                    json.dumps(list(memory_ids_tuple), ensure_ascii=False),
                ),
            )
            conn.execute(
                "UPDATE sessions SET updated_at = ? WHERE session_id = ?",
                (now, session_id),
            )
            conn.commit()

        return SessionSummary(
            session_id=session_id,
            text=text,
            source=source,
            created_at=now,
            updated_at=now,
            memory_ids=memory_ids_tuple,
        )

    def query_memories(self, query: MemoryQuery) -> List[MemoryItem]:
        clauses = []
        params: List[Any] = []

        if query.kind:
            clauses.append("kind = ?")
            params.append(query.kind)
        if query.project:
            clauses.append("project = ?")
            params.append(query.project)
        if query.session_id:
            clauses.append("session_id = ?")
            params.append(query.session_id)
        if query.text:
            terms = [
                term.lower().strip(".,!?¿¡:;()[]{}\"'")
                for term in query.text.split()
                if len(term) >= 3
            ]
            terms = [term for term in terms if term and term not in SEARCH_STOPWORDS]
            if terms:
                clauses.extend(["text LIKE ?" for _ in terms])
                params.extend([f"%{term}%" for term in terms])
        if not query.include_archived:
            clauses.append("archived = 0")

        where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
        params.append(int(query.limit))
        sql = f"""
            SELECT * FROM memories
            {where}
            ORDER BY importance DESC, updated_at DESC
            LIMIT ?
        """
        with self.connect() as conn:
            rows = conn.execute(sql, params).fetchall()
        return [self._row_to_item(row) for row in rows]

    def record_turn(
        self,
        *,
        session_id: str,
        user_text: str,
        assistant_text: str,
        source: str = "brain.respond",
        importance: float = 0.45,
        confidence: float = 0.8,
        tags: Optional[Iterable[str]] = None,
        project: Optional[str] = None,
        summarize: bool = False,
    ) -> MemoryWriteResult:
        session_id = session_id.strip()
        user_text = user_text.strip()
        assistant_text = assistant_text.strip()
        source = source.strip()
        if not session_id:
            raise ValueError("session_id must not be empty")
        if not user_text or not assistant_text:
            raise ValueError("user_text and assistant_text must not be empty")

        session = self.upsert_session(
            session_id,
            source=source,
            last_user_text=user_text,
            last_assistant_text=assistant_text,
            count_turn=True,
        )
        if summarize:
            summary_text = f"User: {user_text}\nTuli: {assistant_text}"
            summary = self.save_session_summary(
                session_id,
                summary_text,
                source=source,
                memory_ids=(),
            )
            return MemoryWriteResult(
                ok=True,
                kind="session_summary",
                item_id=session_id,
                session_id=session_id,
                source=source,
                created_at=summary.created_at,
                updated_at=summary.updated_at,
                details={"summary": summary.to_dict()},
            )

        memory = self.add_memory(
            kind="episodic",
            text=f"User: {user_text}\nTuli: {assistant_text}",
            source=source,
            importance=importance,
            confidence=confidence,
            tags=list(tags or ("turn", "chat")),
            project=project,
            session_id=session_id,
        )
        return MemoryWriteResult(
            ok=True,
            kind=memory.kind,
            item_id=memory.id,
            session_id=session_id,
            source=source,
            created_at=memory.created_at,
            updated_at=memory.updated_at,
            details={"memory": memory.to_dict(), "session": session.to_dict()},
        )

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

    @staticmethod
    def _safe_json_loads(value: str) -> Dict[str, Any]:
        try:
            parsed = json.loads(value or "{}")
        except json.JSONDecodeError:
            return {}
        return parsed if isinstance(parsed, dict) else {}

    @staticmethod
    def _row_to_session(row: sqlite3.Row) -> SessionRecord:
        metadata = SQLiteMemoryStore._safe_json_loads(row["metadata_json"] or "{}")
        return SessionRecord(
            session_id=row["session_id"],
            source=row["source"],
            created_at=row["created_at"],
            updated_at=row["updated_at"],
            label=row["label"],
            turn_count=int(row["turn_count"] or 0),
            last_user_text=row["last_user_text"],
            last_assistant_text=row["last_assistant_text"],
            archived=bool(row["archived"]),
            metadata=metadata,
        )

    @staticmethod
    def _row_to_session_summary(row: sqlite3.Row) -> SessionSummary:
        try:
            memory_ids = json.loads(row["memory_ids_json"] or "[]")
        except json.JSONDecodeError:
            memory_ids = []
        if not isinstance(memory_ids, list):
            memory_ids = []
        return SessionSummary(
            session_id=row["session_id"],
            text=row["text"],
            source=row["source"],
            created_at=row["created_at"],
            updated_at=row["updated_at"],
            memory_ids=tuple(str(item) for item in memory_ids if str(item).strip()),
        )
