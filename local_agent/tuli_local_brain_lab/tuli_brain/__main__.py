from __future__ import annotations

import argparse
import json
import subprocess
import time
from pathlib import Path
from typing import Any

from .actions.event_bridge import emit_response_events
from .brain import respond
from .config import load_config
from .memory.memory_policy import should_store_episodic_turn
from .memory.sqlite_memory import SQLiteMemoryStore
from .persona.context_builder import build_context
from .providers.kokoro_local import synthesize_speech


def _print_json(payload: Any) -> None:
    print(json.dumps(payload, ensure_ascii=False, indent=2))


def _respond_with_optional_emit(user_text: str, *, speak: bool, emit: bool) -> dict:
    response = respond(user_text, speak=speak)
    if emit:
        emit_result = emit_response_events(response, load_config().event_stream_path)
        response = dict(response)
        response["_emit"] = emit_result.to_dict()
    return response


def _find_latest_audio(speech_output_dir: str) -> Path:
    directory = Path(speech_output_dir).expanduser()
    if not directory.exists():
        raise FileNotFoundError(f"speech output directory does not exist: {directory}")
    candidates = [
        path for path in directory.iterdir()
        if path.is_file() and path.suffix.lower() in {".mp3", ".wav", ".ogg", ".flac"}
    ]
    if not candidates:
        raise FileNotFoundError(f"no audio files found in: {directory}")
    return max(candidates, key=lambda path: path.stat().st_mtime)


def _tail_file(path: str, *, lines: int, follow: bool) -> None:
    event_path = Path(path).expanduser()
    if not event_path.exists():
        print("")
        return

    with event_path.open("r", encoding="utf-8") as stream:
        entries = stream.readlines()
        for line in entries[-lines:]:
            print(line.rstrip())
        if not follow:
            return
        while True:
            line = stream.readline()
            if line:
                print(line.rstrip(), flush=True)
            else:
                time.sleep(0.5)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Tuli local brain lab CLI")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("config", help="Print resolved local-first configuration.")

    ask_parser = sub.add_parser("ask", help="Ask Tuli with friendly CLI defaults.")
    ask_parser.add_argument("user_text", help="User text for Tuli.")
    ask_parser.add_argument("--voice", action="store_true", help="Generate Kokoro speech for this answer.")
    ask_parser.add_argument("--emit", action="store_true", help="Append response actions to the local JSONL event stream.")
    ask_parser.add_argument("--json", action="store_true", help="Print the full response JSON instead of only Tuli's text.")

    respond_parser = sub.add_parser("respond", help="Return a provisional brain response JSON.")
    respond_parser.add_argument("user_text", help="User text for Tuli.")
    respond_parser.add_argument("--speak", action="store_true", help="Include speech_start in returned actions.")
    respond_parser.add_argument("--emit", action="store_true", help="Append response actions to the local JSONL event stream.")

    tail_parser = sub.add_parser("tail-events", help="Print recent local event stream lines.")
    tail_parser.add_argument("--lines", type=int, default=20, help="Number of recent event lines to print.")
    tail_parser.add_argument("--follow", action="store_true", help="Keep watching for new events.")

    context_parser = sub.add_parser("context", help="Print the prompt context that would be sent to Ollama.")
    context_parser.add_argument("user_text", help="User text for context retrieval.")

    speech_parser = sub.add_parser("speech", help="Use local Kokoro to synthesize speech.")
    speech_sub = speech_parser.add_subparsers(dest="speech_command", required=True)
    synth_parser = speech_sub.add_parser("synthesize", help="Synthesize text with Kokoro local.")
    synth_parser.add_argument("text", help="Text to synthesize.")
    synth_parser.add_argument("--voice", help="Override Kokoro voice.")
    play_parser = speech_sub.add_parser("play-last", help="Play the latest generated speech file with afplay.")
    play_parser.add_argument("--path", help="Audio path to play instead of latest generated speech.")

    memory_parser = sub.add_parser("memory", help="Inspect the clean local SQLite memory.")
    memory_sub = memory_parser.add_subparsers(dest="memory_command", required=True)

    memory_sub.add_parser("stats", help="Initialize memory and print counts.")

    list_parser = memory_sub.add_parser("list", help="List recent memories.")
    list_parser.add_argument("--kind", help="Filter by memory kind.")
    list_parser.add_argument("--limit", type=int, default=20, help="Maximum memories to print.")

    archive_parser = memory_sub.add_parser("archive", help="Archive a memory by id.")
    archive_parser.add_argument("memory_id", help="Memory id to archive.")

    memory_sub.add_parser("archive-trivial", help="Archive active trivial episodic turns.")

    return parser


def main() -> int:
    args = build_parser().parse_args()

    if args.command == "config":
        _print_json(load_config().to_dict())
        return 0

    if args.command == "ask":
        response = _respond_with_optional_emit(args.user_text, speak=args.voice, emit=args.emit)
        if args.json:
            _print_json(response)
        else:
            print(response["text"])
        return 0

    if args.command == "respond":
        _print_json(_respond_with_optional_emit(args.user_text, speak=args.speak, emit=args.emit))
        return 0

    if args.command == "tail-events":
        config = load_config()
        _tail_file(config.event_stream_path, lines=args.lines, follow=args.follow)
        return 0

    if args.command == "context":
        config = load_config()
        store = SQLiteMemoryStore(config.memory_db_path)
        store.initialize()
        _print_json(build_context(args.user_text, store).to_dict())
        return 0

    if args.command == "speech":
        config = load_config()
        if args.speech_command == "synthesize":
            result = synthesize_speech(args.text, config, voice=args.voice)
            _print_json(result.to_dict())
            return 0
        if args.speech_command == "play-last":
            audio_path = Path(args.path).expanduser() if args.path else _find_latest_audio(config.speech_output_dir)
            subprocess.run(["/usr/bin/afplay", str(audio_path)], check=True)
            _print_json({"played": str(audio_path)})
            return 0

    if args.command == "memory":
        config = load_config()
        store = SQLiteMemoryStore(config.memory_db_path)
        store.initialize()

        if args.memory_command == "stats":
            _print_json(
                {
                    "path": store.path(),
                    "count": store.count(),
                    "active_count": store.count(),
                    "total_count": store.count(include_archived=True),
                    "count_by_kind": store.count_by_kind(),
                }
            )
            return 0

        if args.memory_command == "list":
            memories = store.list_memories(kind=args.kind, limit=args.limit) if args.kind else store.list_recent(limit=args.limit)
            _print_json([item.to_dict() for item in memories])
            return 0

        if args.memory_command == "archive":
            _print_json({"id": args.memory_id, "archived": store.archive_memory(args.memory_id)})
            return 0

        if args.memory_command == "archive-trivial":
            archived = []
            for item in store.list_memories(kind="episodic", limit=500):
                user_text = ""
                assistant_text = ""
                for line in item.text.splitlines():
                    if line.startswith("User:"):
                        user_text = line.removeprefix("User:").strip()
                    if line.startswith("Tuli:"):
                        assistant_text = line.removeprefix("Tuli:").strip()
                if user_text and assistant_text and not should_store_episodic_turn(user_text, assistant_text):
                    if store.archive_memory(item.id):
                        archived.append(item.id)
            _print_json({"archived_count": len(archived), "archived_ids": archived})
            return 0

    raise SystemExit(f"Unknown command: {args.command}")


if __name__ == "__main__":
    raise SystemExit(main())
