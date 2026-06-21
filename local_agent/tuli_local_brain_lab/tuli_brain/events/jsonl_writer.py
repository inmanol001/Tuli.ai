from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Sequence

from .event_schema import EventRecord


def _coerce_event_dict(event: EventRecord | Mapping[str, Any]) -> Dict[str, Any]:
    if isinstance(event, EventRecord):
        return event.to_dict()
    return dict(event)


def write_jsonl_events(
    event_stream_path: str | Path,
    events: Sequence[EventRecord | Mapping[str, Any]],
) -> Dict[str, Any]:
    path = Path(event_stream_path).expanduser()
    path.parent.mkdir(parents=True, exist_ok=True)

    written = 0
    with path.open("a", encoding="utf-8") as stream:
        for event in events:
            stream.write(
                json.dumps(_coerce_event_dict(event), ensure_ascii=False, separators=(",", ":"))
                + "\n"
            )
            written += 1

    return {"path": str(path), "written_count": written}


def append_jsonl_event(
    event_stream_path: str | Path,
    event: EventRecord | Mapping[str, Any],
) -> Dict[str, Any]:
    return write_jsonl_events(event_stream_path, [event])


def tail_jsonl_lines(event_stream_path: str | Path, *, lines: int = 20) -> List[str]:
    path = Path(event_stream_path).expanduser()
    if not path.exists():
        return []
    with path.open("r", encoding="utf-8") as stream:
        return [line.rstrip("\n") for line in stream.readlines()[-lines:]]

