#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import uuid
from pathlib import Path


BASE_DIR = Path(__file__).resolve().parent
BRIDGE_PATH = BASE_DIR.parent / "openclaw_vroid_bridge.py"


def default_stream_path() -> Path:
    override = os.environ.get("VROID_EVENT_STREAM_PATH", "").strip()
    if override:
        return Path(override).expanduser().resolve()
    app_support = os.environ.get("VROID_APP_SUPPORT", "").strip()
    if app_support:
        return Path(app_support).expanduser().resolve() / "openclaw_stream.jsonl"
    return Path.home() / "Library" / "Application Support" / "VroidOverlay" / "openclaw_stream.jsonl"


def append_jsonl(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
        handle.write("\n")
        handle.flush()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Send a local avatar event to VroidOverlay.")
    parser.add_argument("--text", default="", help="Spoken text to send through the bridge.")
    parser.add_argument("--emotion", default="neutral", help="Emotion hint.")
    parser.add_argument("--gesture", default="", help="Gesture name for silent events.")
    parser.add_argument("--event-type", default="", help="Event type label for silent events.")
    parser.add_argument("--priority", default="", help="Event priority label.")
    parser.add_argument("--intent", default="", help="Short intent label.")
    parser.add_argument("--source", default="", help="Event source label.")
    parser.add_argument("--bubble", action="store_true", help="Show speech bubble.")
    parser.add_argument("--voice", action="store_true", help="Use voice if the bridge/app supports it.")
    parser.add_argument("--stream-path", default="", help="Override the JSONL stream path.")
    return parser


def send_text(args: argparse.Namespace) -> int:
    bridge_args = [
        sys.executable,
        str(BRIDGE_PATH),
        "--text",
        args.text,
        "--emotion",
        args.emotion or "neutral",
    ]
    if args.stream_path:
        bridge_args.extend(["--stream-path", args.stream_path])
    if args.bubble:
        bridge_args.append("--bubble")
    return subprocess.run(bridge_args, check=False).returncode


def send_raw(args: argparse.Namespace) -> int:
    stream_path = Path(args.stream_path).expanduser().resolve() if args.stream_path else default_stream_path()
    payload = {
        "type": args.event_type or "agent_event",
        "id": f"evt_{uuid.uuid4().hex[:10]}",
        "ts": time.time(),
        "emotion": args.emotion or "neutral",
        "gesture": args.gesture or "",
        "intent": args.intent or "",
        "priority": args.priority or "",
        "source": args.source or "local_agent",
        "speak": False,
        "bubble": False,
        "voice": False,
    }
    append_jsonl(stream_path, payload)
    return 0


def main() -> int:
    args = build_parser().parse_args()
    if args.text.strip():
        return send_text(args)
    return send_raw(args)


if __name__ == "__main__":
    raise SystemExit(main())
