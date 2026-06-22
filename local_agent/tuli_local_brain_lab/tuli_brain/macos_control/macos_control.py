from __future__ import annotations

import json
import plistlib
import subprocess
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, Optional

from .macos_control_types import MACOS_CONTROL_STATUS, MACOS_OBSERVATION_LEVELS, MacOSControlResult, MacOSObservation


DEFAULT_SOURCE = "macos_control"
DEFAULT_TIMEOUT_SECONDS = 5

_APPLICATION_ALIASES = {
    "safari": "Safari",
    "notes": "Notes",
    "notas": "Notes",
    "finder": "Finder",
    "terminal": "Terminal",
    "calendario": "Calendar",
    "calendar": "Calendar",
    "recordatorios": "Reminders",
    "reminders": "Reminders",
    "mensajes": "Messages",
    "messages": "Messages",
    "preview": "Preview",
    "textedit": "TextEdit",
    "texto": "TextEdit",
    "chrome": "Google Chrome",
    "google chrome": "Google Chrome",
    "vscode": "Visual Studio Code",
    "vs code": "Visual Studio Code",
    "code": "Visual Studio Code",
    "telegram": "Telegram",
    "slack": "Slack",
}

_KNOWN_APPLICATIONS = sorted({value for value in _APPLICATION_ALIASES.values()} | {
    "App Store",
    "Calculator",
    "Chess",
    "Contacts",
    "Dictionary",
    "FaceTime",
    "Mail",
    "Maps",
    "Music",
    "Photos",
    "Podcasts",
    "QuickTime Player",
    "Reminders",
    "Safari",
    "Shortcuts",
    "System Settings",
    "TextEdit",
    "TV",
    "Voice Memos",
    "Notes",
    "Calendar",
    "Finder",
    "Terminal",
})


class MacOSControlError(RuntimeError):
    """Raised when safe macOS observation cannot be completed."""


def utc_now() -> str:
    return datetime.utcnow().replace(microsecond=0).isoformat() + "Z"


def make_observation_id(prefix: str = "obs") -> str:
    return f"{prefix}_{uuid.uuid4().hex[:12]}"


def _sanitize_text(text: str) -> str:
    clean = " ".join(str(text).split())
    return clean[:180]


def _normalize_application_name(app_name: str) -> str:
    clean = _sanitize_text(app_name).strip().strip("\"'")
    clean = clean.removesuffix(".app").strip()
    lower = clean.lower()
    if lower in _APPLICATION_ALIASES:
        return _APPLICATION_ALIASES[lower]
    return clean


def _apple_script_string_literal(text: str) -> str:
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _candidate_application_bundle_paths(app_name: str) -> list[Path]:
    clean = _sanitize_text(app_name).strip().strip("\"'")
    bundle_name = f"{clean}.app"
    if bundle_name == ".app":
        return []

    candidates = [
        Path("/Applications") / bundle_name,
        Path.home() / "Applications" / bundle_name,
        Path("/System/Applications") / bundle_name,
    ]
    return [candidate for candidate in candidates if candidate.exists()]


def _bundle_executable_path(bundle_path: Path) -> Optional[Path]:
    info_plist = bundle_path / "Contents" / "Info.plist"
    if not info_plist.exists():
        return None

    try:
        with info_plist.open("rb") as handle:
            plist = plistlib.load(handle)
    except Exception:
        return None

    executable_name = plist.get("CFBundleExecutable")
    if not isinstance(executable_name, str) or not executable_name.strip():
        executable_name = bundle_path.stem

    executable_path = bundle_path / "Contents" / "MacOS" / executable_name
    return executable_path if executable_path.exists() else None


def list_known_applications() -> list[str]:
    """Return the app names Tuli recognizes by default."""
    return list(_KNOWN_APPLICATIONS)


class MacOSControl:
    """Very conservative macOS observation helper."""

    def __init__(self, *, timeout_seconds: int = DEFAULT_TIMEOUT_SECONDS):
        self.timeout_seconds = timeout_seconds

    def _run_osascript(self, script: str) -> str:
        try:
            result = subprocess.run(
                ["/usr/bin/osascript", "-e", script],
                check=True,
                capture_output=True,
                text=True,
                timeout=self.timeout_seconds,
            )
        except FileNotFoundError as exc:
            raise MacOSControlError("osascript is not available on this system") from exc
        except subprocess.TimeoutExpired as exc:
            raise MacOSControlError(f"osascript timed out after {self.timeout_seconds}s") from exc
        except subprocess.CalledProcessError as exc:
            stderr = (exc.stderr or exc.stdout or "").strip()
            raise MacOSControlError(f"osascript failed: {stderr or exc.returncode}") from exc
        return result.stdout.strip()

    def _visible_frame(self) -> Optional[Dict[str, int]]:
        swift_script = r'''
import AppKit
import Foundation

let screen = NSScreen.main ?? NSScreen.screens.first
guard let frame = screen?.visibleFrame else {
    exit(1)
}

let payload: [String: Double] = [
    "x": frame.origin.x,
    "y": frame.origin.y,
    "width": frame.size.width,
    "height": frame.size.height
]

let data = try JSONSerialization.data(withJSONObject: payload, options: [])
if let string = String(data: data, encoding: .utf8) {
    print(string)
}
'''
        try:
            result = subprocess.run(
                ["/usr/bin/swift", "-e", swift_script],
                check=True,
                capture_output=True,
                text=True,
                timeout=self.timeout_seconds,
            )
        except (FileNotFoundError, subprocess.TimeoutExpired, subprocess.CalledProcessError):
            return None

        output = (result.stdout or "").strip()
        if not output:
            return None

        try:
            raw = json.loads(output)
        except json.JSONDecodeError:
            return None

        try:
            return {
                "x": int(round(float(raw["x"]))),
                "y": int(round(float(raw["y"]))),
                "width": int(round(float(raw["width"]))),
                "height": int(round(float(raw["height"]))),
            }
        except (KeyError, TypeError, ValueError):
            return None

    def _fit_frontmost_window_to_visible_frame(self, app_name: str) -> bool:
        frame = self._visible_frame()
        if not frame:
            return False

        app_literal = _apple_script_string_literal(app_name)
        script = f'''
tell application "System Events"
    repeat with attempt from 1 to 30
        if exists process {app_literal} then
            exit repeat
        end if
        delay 0.1
    end repeat

    tell process {app_literal}
        set frontmost to true
        repeat with attempt from 1 to 30
            if (count of windows) > 0 then
                exit repeat
            end if
            delay 0.1
        end repeat

        if (count of windows) > 0 then
            set frontWindow to front window
            set position of frontWindow to {{{frame["x"]}, {frame["y"]}}}
            set size of frontWindow to {{{frame["width"]}, {frame["height"]}}}
            return "adjusted"
        end if
    end tell
end tell
return "no_window"
'''
        try:
            result = self._run_osascript(script)
        except MacOSControlError:
            return False
        return result == "adjusted"

    def _run_open_command(self, open_args: list[str]) -> None:
        subprocess.run(
            open_args,
            check=True,
            capture_output=True,
            text=True,
            timeout=self.timeout_seconds,
        )

    def _launch_bundle_executable(self, bundle_path: Path) -> bool:
        executable_path = _bundle_executable_path(bundle_path)
        if executable_path is None:
            return False

        try:
            subprocess.Popen([str(executable_path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return True
        except (FileNotFoundError, OSError):
            return False

    def observe_frontmost_state(self) -> MacOSObservation:
        script = r'''
        tell application "System Events"
            set frontApp to first application process whose frontmost is true
            set appName to name of frontApp
            set bundleId to bundle identifier of frontApp
            set windowName to ""
            try
                set windowName to name of front window of frontApp
            end try
            return appName & "||" & bundleId & "||" & windowName
        end tell
        '''
        raw = self._run_osascript(script)
        parts = raw.split("||")
        app_name = _sanitize_text(parts[0]) if len(parts) > 0 else None
        bundle_id = _sanitize_text(parts[1]) if len(parts) > 1 else None
        window_title = _sanitize_text(parts[2]) if len(parts) > 2 else None
        return MacOSObservation(
            observation_id=make_observation_id(),
            observed_at=utc_now(),
            source=DEFAULT_SOURCE,
            status="ok",
            privacy_level="safe",
            app_name=app_name or None,
            bundle_id=bundle_id or None,
            window_title=window_title or None,
            is_frontmost=True,
            notes="frontmost state observed safely",
            metadata={"raw": raw, "status_catalog": MACOS_CONTROL_STATUS, "privacy_catalog": MACOS_OBSERVATION_LEVELS},
        )

    def snapshot(self) -> MacOSControlResult:
        try:
            observation = self.observe_frontmost_state()
        except MacOSControlError as exc:
            return MacOSControlResult(
                ok=False,
                operation="observe_frontmost_state",
                status="unavailable",
                error={"message": str(exc), "source": DEFAULT_SOURCE},
            )
        return MacOSControlResult(
            ok=True,
            operation="observe_frontmost_state",
            observation=observation,
            status="ok",
        )

    def open_application(self, app_name: str) -> MacOSControlResult:
        normalized = _normalize_application_name(app_name)
        if not normalized:
            return MacOSControlResult(
                ok=False,
                operation="open_application",
                status="unavailable",
                error={"message": "application name must not be empty", "source": DEFAULT_SOURCE},
            )

        try:
            self._run_open_command(["/usr/bin/open", "-a", normalized])
        except FileNotFoundError as exc:
            return MacOSControlResult(
                ok=False,
                operation="open_application",
                status="unavailable",
                error={"message": "open command is not available on this system", "source": DEFAULT_SOURCE},
            )
        except subprocess.TimeoutExpired as exc:
            return MacOSControlResult(
                ok=False,
                operation="open_application",
                status="unavailable",
                error={"message": f"open timed out after {self.timeout_seconds}s", "source": DEFAULT_SOURCE},
            )
        except subprocess.CalledProcessError as exc:
            stderr = (exc.stderr or exc.stdout or "").strip()
            bundle_candidates = _candidate_application_bundle_paths(normalized)
            if "Unable to find application named" in stderr and bundle_candidates:
                try:
                    self._run_open_command(["/usr/bin/open", str(bundle_candidates[0])])
                except (FileNotFoundError, subprocess.TimeoutExpired, subprocess.CalledProcessError) as fallback_exc:
                    if not self._launch_bundle_executable(bundle_candidates[0]):
                        fallback_stderr = ""
                        if isinstance(fallback_exc, subprocess.CalledProcessError):
                            fallback_stderr = (fallback_exc.stderr or fallback_exc.stdout or "").strip()
                        return MacOSControlResult(
                            ok=False,
                            operation="open_application",
                            status="error",
                            error={"message": fallback_stderr or stderr or f"could not open {normalized}", "source": DEFAULT_SOURCE},
                        )
            else:
                return MacOSControlResult(
                    ok=False,
                    operation="open_application",
                    status="error",
                    error={"message": stderr or f"could not open {normalized}", "source": DEFAULT_SOURCE},
                )

        self._fit_frontmost_window_to_visible_frame(normalized)

        observation = None
        try:
            observation = self.observe_frontmost_state()
        except MacOSControlError:
            observation = None

        return MacOSControlResult(
            ok=True,
            operation="open_application",
            observation=observation,
            status="ok",
        )

    def record_activity(self, activity_watcher, *, observation: Optional[MacOSObservation] = None) -> MacOSControlResult:
        snapshot = observation or self.snapshot().observation
        if snapshot is None:
            return MacOSControlResult(
                ok=False,
                operation="record_activity",
                status="unavailable",
                error={"message": "no observation available", "source": DEFAULT_SOURCE},
            )

        if activity_watcher is None:
            return MacOSControlResult(
                ok=False,
                operation="record_activity",
                status="unavailable",
                error={"message": "activity watcher missing", "source": DEFAULT_SOURCE},
            )

        activity_watcher.record_app_focus(
            snapshot.app_name or "unknown",
            window_title=snapshot.window_title,
            source=DEFAULT_SOURCE,
        )
        return MacOSControlResult(ok=True, operation="record_activity", observation=snapshot, status="ok")


def observe_frontmost_state() -> Dict[str, Any]:
    return MacOSControl().snapshot().to_dict()
