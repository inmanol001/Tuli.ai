from __future__ import annotations

from typing import List

from .sqlite_memory import MemoryItem, SQLiteMemoryStore


KIND_ORDER = [
    "core",
    "project_rule",
    "technical_warning",
    "preference",
    "episodic",
    "task_context",
]


def retrieve_relevant_memories(
    store: SQLiteMemoryStore,
    user_text: str,
    *,
    limit: int = 8,
) -> List[MemoryItem]:
    store.initialize()
    selected: List[MemoryItem] = []
    seen = set()

    for kind in KIND_ORDER[:3]:
        for item in store.list_memories(kind=kind, limit=4):
            if item.id not in seen:
                selected.append(item)
                seen.add(item.id)

    for item in store.search_memories(user_text, limit=limit):
        if item.id not in seen:
            selected.append(item)
            seen.add(item.id)
        if len(selected) >= limit:
            break

    return selected[:limit]


def format_memory_block(memories: List[MemoryItem]) -> str:
    if not memories:
        return "[Memory]\n- none"
    lines = ["[Memory]"]
    for item in memories:
        lines.append(f"- {item.kind}: {item.text}")
    return "\n".join(lines)
