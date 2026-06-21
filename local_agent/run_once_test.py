#!/usr/bin/env python3
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


BASE_DIR = Path(__file__).resolve().parent


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run one local agent event and print the result.")
    parser.add_argument("event_type", help="Event type from schedules.json.")
    parser.add_argument("--force-text", default="", help="Force a spoken line.")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    daemon = BASE_DIR / "vroid_agent_daemon.py"
    command = [sys.executable, str(daemon), "--once", args.event_type]
    if args.force_text.strip():
        command.extend(["--force-text", args.force_text.strip()])
    return subprocess.run(command, check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
