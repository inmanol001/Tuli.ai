from __future__ import annotations

import argparse
import json
import time
import uuid
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, Iterable, List, Set

from tuli_brain.actions.event_bridge import emit_response_events
from tuli_brain.brain import respond
from tuli_brain.config import load_config


REQUEST_SCHEMA = "tuli_request.v1"
RESPONSE_SCHEMA = "tuli_daemon_response.v1"


def utc_now() -> str:
    return datetime.utcnow().replace(microsecond=0).isoformat() + "Z"


def make_id(prefix: str) -> str:
    return prefix + "_" + uuid.uuid4().hex[:12]


def append_jsonl(path: str | Path, payload: Dict[str, Any]) -> None:
    target = Path(path).expanduser()
    target.parent.mkdir(parents=True, exist_ok=True)
    with target.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")


def read_jsonl(path: str | Path) -> List[Dict[str, Any]]:
    target = Path(path).expanduser()
    if not target.exists():
        return []
    rows: List[Dict[str, Any]] = []
    with target.open("r", encoding="utf-8") as stream:
        for line_no, line in enumerate(stream, start=1):
            clean = line.strip()
            if not clean:
                continue
            try:
                data = json.loads(clean)
            except json.JSONDecodeError as exc:
                rows.append(
                    {
                        "schema": REQUEST_SCHEMA,
                        "id": f"invalid_line_{line_no}",
                        "invalid": True,
                        "error": f"invalid JSON: {exc}",
                    }
                )
                continue
            if isinstance(data, dict):
                rows.append(data)
    return rows


def tail_jsonl(path: str | Path, *, lines: int, follow: bool) -> None:
    target = Path(path).expanduser()
    if not target.exists():
        print("")
        return
    with target.open("r", encoding="utf-8") as stream:
        existing = stream.readlines()
        for line in existing[-lines:]:
            print(line.rstrip())
        if not follow:
            return
        while True:
            line = stream.readline()
            if line:
                print(line.rstrip(), flush=True)
            else:
                time.sleep(0.5)


@dataclass(frozen=True)
class DaemonConfig:
    request_stream_path: str
    response_stream_path: str
    event_stream_path: str
    poll_seconds: float


def load_daemon_config(*, poll_seconds: float) -> DaemonConfig:
    config = load_config()
    return DaemonConfig(
        request_stream_path=config.request_stream_path,
        response_stream_path=config.response_stream_path,
        event_stream_path=config.event_stream_path,
        poll_seconds=poll_seconds,
    )


def make_request(text: str, *, voice: bool, emit: bool) -> Dict[str, Any]:
    clean = text.strip()
    if not clean:
        raise ValueError("request text must not be empty")
    return {
        "schema": REQUEST_SCHEMA,
        "id": make_id("req"),
        "created_at": utc_now(),
        "source": "tuli_brain_daemon.send",
        "text": clean,
        "voice": bool(voice),
        "emit": bool(emit),
    }


def load_processed_ids(response_stream_path: str | Path) -> Set[str]:
    processed = set()
    for row in read_jsonl(response_stream_path):
        request_id = row.get("request_id")
        if isinstance(request_id, str) and request_id:
            processed.add(request_id)
    return processed


def pending_requests(request_stream_path: str | Path, processed_ids: Set[str]) -> Iterable[Dict[str, Any]]:
    for request in read_jsonl(request_stream_path):
        request_id = request.get("id")
        if not isinstance(request_id, str) or not request_id:
            continue
        if request_id in processed_ids:
            continue
        yield request


def process_request(request: Dict[str, Any], config: DaemonConfig) -> Dict[str, Any]:
    request_id = str(request.get("id", ""))
    text = str(request.get("text", "")).strip()
    voice = bool(request.get("voice", False))
    emit = bool(request.get("emit", True))

    started_at = utc_now()
    try:
        if request.get("invalid"):
            raise ValueError(str(request.get("error", "invalid request")))
        if not request_id:
            raise ValueError("request id is missing")
        if not text:
            raise ValueError("request text is missing")

        brain_response = respond(text, speak=voice)
        emit_result = None
        if emit:
            emit_result = emit_response_events(brain_response, config.event_stream_path).to_dict()

        return {
            "schema": RESPONSE_SCHEMA,
            "id": make_id("res"),
            "request_id": request_id,
            "created_at": utc_now(),
            "started_at": started_at,
            "ok": True,
            "text": brain_response["text"],
            "response": brain_response,
            "emit": emit_result,
        }
    except Exception as exc:  # noqa: BLE001 - daemon must log failures as data.
        return {
            "schema": RESPONSE_SCHEMA,
            "id": make_id("res"),
            "request_id": request_id,
            "created_at": utc_now(),
            "started_at": started_at,
            "ok": False,
            "error": str(exc),
        }


def run_once(config: DaemonConfig) -> int:
    processed_ids = load_processed_ids(config.response_stream_path)
    count = 0
    for request in pending_requests(config.request_stream_path, processed_ids):
        response = process_request(request, config)
        append_jsonl(config.response_stream_path, response)
        processed_ids.add(str(request.get("id", "")))
        count += 1
        print(json.dumps(response, ensure_ascii=False), flush=True)
    return count


def run_loop(config: DaemonConfig) -> None:
    print(
        json.dumps(
            {
                "status": "running",
                "request_stream_path": config.request_stream_path,
                "response_stream_path": config.response_stream_path,
                "event_stream_path": config.event_stream_path,
                "poll_seconds": config.poll_seconds,
            },
            ensure_ascii=False,
        ),
        flush=True,
    )
    while True:
        run_once(config)
        time.sleep(config.poll_seconds)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Manual local daemon for Tuli brain requests.")
    sub = parser.add_subparsers(dest="command", required=True)

    run_parser = sub.add_parser("run", help="Process request JSONL entries.")
    run_parser.add_argument("--once", action="store_true", help="Process pending requests once and exit.")
    run_parser.add_argument("--poll", type=float, default=0.75, help="Polling interval in seconds for loop mode.")

    send_parser = sub.add_parser("send", help="Append a request to the daemon request stream.")
    send_parser.add_argument("text", help="Text to send to Tuli.")
    send_parser.add_argument("--voice", action="store_true", help="Generate Kokoro speech.")
    send_parser.add_argument("--no-emit", action="store_true", help="Do not emit actions to the event stream.")

    tail_parser = sub.add_parser("tail", help="Tail daemon responses.")
    tail_parser.add_argument("--lines", type=int, default=20)
    tail_parser.add_argument("--follow", action="store_true")

    sub.add_parser("paths", help="Print daemon paths.")

    return parser


def main() -> int:
    args = build_parser().parse_args()
    config = load_daemon_config(poll_seconds=getattr(args, "poll", 0.75))

    if args.command == "paths":
        print(
            json.dumps(
                {
                    "request_stream_path": config.request_stream_path,
                    "response_stream_path": config.response_stream_path,
                    "event_stream_path": config.event_stream_path,
                },
                ensure_ascii=False,
                indent=2,
            )
        )
        return 0

    if args.command == "send":
        request = make_request(args.text, voice=args.voice, emit=not args.no_emit)
        append_jsonl(config.request_stream_path, request)
        print(json.dumps(request, ensure_ascii=False, indent=2))
        return 0

    if args.command == "tail":
        tail_jsonl(config.response_stream_path, lines=args.lines, follow=args.follow)
        return 0

    if args.command == "run":
        if args.once:
            processed = run_once(config)
            print(json.dumps({"processed": processed}, ensure_ascii=False))
            return 0
        run_loop(config)
        return 0

    raise SystemExit(f"Unknown command: {args.command}")


if __name__ == "__main__":
    raise SystemExit(main())
