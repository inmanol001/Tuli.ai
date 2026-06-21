#!/usr/bin/env python3
import argparse
import json
import os
import sys
import time
import uuid
from pathlib import Path


def default_stream_path() -> Path:
    override = os.environ.get("VROID_EVENT_STREAM_PATH", "").strip()
    if override:
        return Path(override).expanduser().resolve()

    app_support = os.environ.get("VROID_APP_SUPPORT", "").strip()
    base = Path(app_support).expanduser().resolve() if app_support else Path.home() / "Library" / "Application Support" / "VroidOverlay"
    base.mkdir(parents=True, exist_ok=True)
    return base / "openclaw_stream.jsonl"


def debug_enabled() -> bool:
    value = os.environ.get("VROID_DEBUG", "").strip().lower()
    return value in {"1", "true", "yes", "on"}


def default_debug_log_path() -> Path:
    override = os.environ.get("VROID_DEBUG_LOG_PATH", "").strip()
    if override:
        return Path(override).expanduser().resolve()

    app_support = os.environ.get("VROID_APP_SUPPORT", "").strip()
    base = Path(app_support).expanduser().resolve() if app_support else Path.home() / "Library" / "Application Support" / "VroidOverlay"
    base.mkdir(parents=True, exist_ok=True)
    return base / "bridge_debug.log"


def write_debug_line(log_path: Path, line: str) -> None:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("a", encoding="utf-8") as handle:
        handle.write(line)
        handle.write("\n")
        handle.flush()


def bridge_log(log_path: Path, level: str, message: str, **fields) -> None:
    if not debug_enabled():
        return
    payload = {
        "ts": time.time(),
        "level": level,
        "message": message,
    }
    payload.update({k: v for k, v in fields.items() if v is not None})
    line = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    write_debug_line(log_path, line)
    print(line, file=sys.stdout, flush=True)


def append_event(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    with path.open("a", encoding="utf-8") as handle:
        handle.write(line)
        handle.write("\n")
        handle.flush()


def emit_event(path: Path, event_id: str, debug_log_path: Path, event_type: str, **fields) -> None:
    payload = {"type": event_type, "id": event_id, "ts": time.time()}
    payload.update({k: v for k, v in fields.items() if v is not None})
    append_event(path, payload)
    bridge_log(
        debug_log_path,
        "info",
        "event_emitted",
        event_type=event_type,
        event_id=event_id,
        raw_payload=payload,
        result="appended",
        stream_path=str(path),
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Emit local JSONL avatar events for VroidOverlay."
    )
    parser.add_argument("--stream-path", dest="stream_path", default="", help="JSONL file to append to.")
    parser.add_argument("--id", dest="event_id", default="", help="Stable message id.")
    parser.add_argument("--emotion", default="", help="Emotion hint: happy, sad, surprised, neutral.")
    parser.add_argument("--text", default="", help="Single-shot text to emit.")
    parser.add_argument("--bubble", action="store_true", help="Show bubble on start.")
    parser.add_argument("--no-bubble", action="store_true", help="Do not show bubble.")
    parser.add_argument("--start-only", action="store_true", help="Emit speech_start only.")
    parser.add_argument("--end-only", action="store_true", help="Emit speech_end only.")
    parser.add_argument("--mode", choices=("emit", "stream"), default="emit", help="Emit a single response or stream stdin chunks.")
    return parser


def normalized_emotion(emotion: str) -> str:
    value = (emotion or "").strip().lower()
    if value in {"happy", "joy", "smile"}:
        return "happy"
    if value in {"sad", "sorrow", "down"}:
        return "sad"
    if value in {"surprised", "surprise", "wow"}:
        return "surprised"
    return "neutral"


def emit_single_shot(path: Path, event_id: str, text: str, emotion: str, bubble: bool, start_only: bool, end_only: bool) -> int:
    debug_log_path = default_debug_log_path()
    if not start_only and not end_only:
        emit_event(path, event_id, debug_log_path, "speech_start", text=text)
        if bubble:
            emit_event(path, event_id, debug_log_path, "bubble_show", text=text)
        if text:
            emit_event(path, event_id, debug_log_path, "text_delta", text=text)
        emit_event(path, event_id, debug_log_path, "emotion_hint", emotion=normalized_emotion(emotion), intensity=0.7)
        emit_event(path, event_id, debug_log_path, "speech_end")
        return 0

    if start_only:
        emit_event(path, event_id, debug_log_path, "speech_start", text=text)
        if bubble:
            emit_event(path, event_id, debug_log_path, "bubble_show", text=text)
        return 0

    if end_only:
        emit_event(path, event_id, debug_log_path, "speech_end")
        return 0

    return 0


def emit_stream(path: Path, event_id: str, emotion: str, bubble: bool) -> int:
    debug_log_path = default_debug_log_path()
    emit_event(path, event_id, debug_log_path, "speech_start")
    if bubble:
        emit_event(path, event_id, debug_log_path, "bubble_show")
    if emotion:
        emit_event(path, event_id, debug_log_path, "emotion_hint", emotion=normalized_emotion(emotion), intensity=0.7)

    for chunk in sys.stdin:
        if chunk == "":
            continue
        text = chunk.rstrip("\n")
        if text:
            emit_event(path, event_id, debug_log_path, "text_delta", text=text)

    emit_event(path, event_id, debug_log_path, "speech_end")
    if bubble:
        emit_event(path, event_id, debug_log_path, "bubble_hide")
    return 0


def main() -> int:
    args = build_parser().parse_args()
    stream_path = Path(args.stream_path).expanduser().resolve() if args.stream_path else default_stream_path()
    event_id = args.event_id.strip() or f"msg_{uuid.uuid4().hex[:8]}"
    bubble = (True if not args.no_bubble else False) if not args.bubble else True
    debug_log_path = default_debug_log_path()

    bridge_log(
        debug_log_path,
        "info",
        "bridge_start",
        mode=args.mode,
        stream_path=str(stream_path),
        event_id=event_id,
        bubble=bubble,
        emotion=args.emotion,
        argv=sys.argv[1:],
    )

    if args.mode == "stream":
        return emit_stream(stream_path, event_id, args.emotion, bubble)

    return emit_single_shot(
        stream_path,
        event_id,
        args.text,
        args.emotion,
        bubble,
        args.start_only,
        args.end_only,
    )


if __name__ == "__main__":
    raise SystemExit(main())
