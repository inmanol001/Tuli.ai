from __future__ import annotations

import ctypes
import subprocess
from dataclasses import asdict, dataclass
from typing import Any, Dict, Mapping, Optional, Tuple


DEFAULT_SOURCE = "macos_permissions"
DEFAULT_TIMEOUT_SECONDS = 5


@dataclass(frozen=True)
class PermissionCheckResult:
    """Safe read-only macOS permission snapshot."""

    source: str
    accessibility: str
    screen_recording: str
    automation_system_events: str
    notes: Tuple[str, ...] = ()
    error: Optional[Mapping[str, Any]] = None

    def to_dict(self) -> Dict[str, Any]:
        data = asdict(self)
        if self.error is not None:
            data["error"] = dict(self.error)
        return data


def _run_osascript(script: str, *, timeout_seconds: int = DEFAULT_TIMEOUT_SECONDS) -> str:
    result = subprocess.run(
        ["/usr/bin/osascript", "-e", script],
        check=True,
        capture_output=True,
        text=True,
        timeout=timeout_seconds,
    )
    return (result.stdout or "").strip()


def check_accessibility(*, timeout_seconds: int = DEFAULT_TIMEOUT_SECONDS) -> str:
    try:
        framework = ctypes.CDLL("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices")
        func = framework.AXIsProcessTrusted
        func.restype = ctypes.c_bool
        func.argtypes = []
        return "granted" if bool(func()) else "missing"
    except OSError:
        return "unknown"


def check_screen_recording(*, timeout_seconds: int = DEFAULT_TIMEOUT_SECONDS) -> str:
    try:
        framework = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
        func = framework.CGPreflightScreenCaptureAccess
        func.restype = ctypes.c_bool
        func.argtypes = []
        return "granted" if bool(func()) else "missing"
    except OSError:
        return "unknown"


def check_system_events_automation(*, timeout_seconds: int = DEFAULT_TIMEOUT_SECONDS) -> str:
    script = r'''
tell application "System Events"
    return name of first process
end tell
'''
    try:
        output = _run_osascript(script, timeout_seconds=timeout_seconds)
        return "available" if output else "unknown"
    except FileNotFoundError:
        return "missing"
    except subprocess.TimeoutExpired:
        return "unknown"
    except subprocess.CalledProcessError as exc:
        stderr = (exc.stderr or exc.stdout or "").strip().lower()
        if any(token in stderr for token in ("-1743", "not authorized", "permission", "not permitted", "-10827")):
            return "missing"
        return "unknown"


def check_macos_permissions(*, timeout_seconds: int = DEFAULT_TIMEOUT_SECONDS) -> PermissionCheckResult:
    accessibility = check_accessibility(timeout_seconds=timeout_seconds)
    screen_recording = check_screen_recording(timeout_seconds=timeout_seconds)
    automation_system_events = check_system_events_automation(timeout_seconds=timeout_seconds)

    notes = []
    if accessibility != "granted":
        notes.append("Accessibility is required to inspect and control window bounds safely.")
    if screen_recording != "granted":
        notes.append("Screen Recording is needed for reliable Quartz/CGWindow window inventory.")
    if automation_system_events != "available":
        notes.append("Automation/System Events is not confirmed; AppleScript fallback may fail.")

    return PermissionCheckResult(
        source=DEFAULT_SOURCE,
        accessibility=accessibility,
        screen_recording=screen_recording,
        automation_system_events=automation_system_events,
        notes=tuple(notes),
    )


def format_permissions_report(result: PermissionCheckResult) -> str:
    lines = [
        "macOS permissions:",
        f"- Accessibility: {result.accessibility}",
        f"- Screen Recording: {result.screen_recording}",
        f"- Automation/System Events: {result.automation_system_events}",
    ]
    if result.screen_recording != "granted":
        lines.append("- Quartz/CGWindow may return empty or nil when Screen Recording is missing.")
    if result.accessibility != "granted":
        lines.append("- AX cannot inspect or control windows until Accessibility is granted.")
    if result.automation_system_events != "available":
        lines.append("- System Events automation fallback is not confirmed on this machine.")
    return "\n".join(lines)
