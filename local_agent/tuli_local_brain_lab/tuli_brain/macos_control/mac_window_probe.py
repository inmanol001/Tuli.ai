from __future__ import annotations

import subprocess
from dataclasses import asdict, dataclass
from typing import Any, Dict, List, Mapping, Optional, Tuple

import AppKit
import Quartz

from .permissions_check import PermissionCheckResult, check_macos_permissions


DEFAULT_TIMEOUT_SECONDS = 5


@dataclass(frozen=True)
class WindowBounds:
    x: int
    y: int
    width: int
    height: int

    def to_dict(self) -> Dict[str, int]:
        return asdict(self)


@dataclass(frozen=True)
class WindowRecord:
    app_name: str
    window_title: Optional[str]
    bounds: WindowBounds
    is_frontmost: bool
    source: str
    window_id: Optional[int] = None
    bundle_id: Optional[str] = None
    error: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        data = asdict(self)
        data["bounds"] = self.bounds.to_dict()
        return data


@dataclass(frozen=True)
class WindowProbeResult:
    ok: bool
    source: str
    permissions: PermissionCheckResult
    windows: Tuple[WindowRecord, ...] = ()
    error: Optional[Mapping[str, Any]] = None

    def to_dict(self) -> Dict[str, Any]:
        return {
            "ok": self.ok,
            "source": self.source,
            "permissions": self.permissions.to_dict(),
            "windows": [window.to_dict() for window in self.windows],
            "error": dict(self.error) if self.error is not None else None,
        }


def _run_osascript(script: str, *, timeout_seconds: int = DEFAULT_TIMEOUT_SECONDS) -> str:
    result = subprocess.run(
        ["/usr/bin/osascript", "-e", script],
        check=True,
        capture_output=True,
        text=True,
        timeout=timeout_seconds,
    )
    return (result.stdout or "").strip()


def _parse_bounds(raw: Mapping[str, Any]) -> Optional[WindowBounds]:
    try:
        x = int(round(float(raw["X"])))
        y = int(round(float(raw["Y"])))
        width = int(round(float(raw["Width"])))
        height = int(round(float(raw["Height"])))
    except (KeyError, TypeError, ValueError):
        return None
    return WindowBounds(x=x, y=y, width=width, height=height)


def _parse_quartz_windows(raw_windows: Any) -> List[WindowRecord]:
    if not raw_windows:
        return []

    try:
        workspace = AppKit.NSWorkspace.sharedWorkspace()
        front_app = workspace.frontmostApplication() if workspace is not None else None
        front_pid = int(front_app.processIdentifier()) if front_app is not None else -1
    except Exception:
        front_pid = -1

    windows: List[WindowRecord] = []
    for item in raw_windows:
        if not isinstance(item, dict):
            continue
        bounds_raw = item.get(Quartz.kCGWindowBounds)
        if not isinstance(bounds_raw, dict):
            continue
        bounds = _parse_bounds(bounds_raw)
        if bounds is None or bounds.width <= 0 or bounds.height <= 0:
            continue

        app_name = str(item.get(Quartz.kCGWindowOwnerName) or "").strip()
        if not app_name:
            continue

        window_title_raw = item.get(Quartz.kCGWindowName)
        window_title = str(window_title_raw).strip() if isinstance(window_title_raw, str) and window_title_raw.strip() else None
        window_id_raw = item.get(Quartz.kCGWindowNumber)
        owner_pid_raw = item.get(Quartz.kCGWindowOwnerPID)
        owner_pid = int(owner_pid_raw) if isinstance(owner_pid_raw, int) else -1

        bundle_id = None
        try:
            running_app = AppKit.NSRunningApplication.runningApplicationWithProcessIdentifier_(owner_pid)
            if running_app is not None and running_app.bundleIdentifier() is not None:
                bundle_id = str(running_app.bundleIdentifier()).strip() or None
        except Exception:
            bundle_id = None

        windows.append(
            WindowRecord(
                app_name=app_name,
                window_title=window_title,
                bounds=bounds,
                is_frontmost=owner_pid == front_pid,
                source="quartz",
                window_id=window_id_raw if isinstance(window_id_raw, int) else None,
                bundle_id=bundle_id,
            )
        )
    return windows


def _parse_system_events_windows(output: str) -> List[WindowRecord]:
    windows: List[WindowRecord] = []
    for line in output.splitlines():
        cleaned = line.strip()
        if not cleaned:
            continue
        parts = cleaned.split("||")
        if len(parts) < 7:
            continue
        app_name = parts[0].strip()
        window_title = parts[1].strip() or None
        try:
            x = int(float(parts[2].strip()))
            y = int(float(parts[3].strip()))
            width = int(float(parts[4].strip()))
            height = int(float(parts[5].strip()))
        except ValueError:
            continue
        is_frontmost = parts[6].strip().lower() in {"true", "1", "yes"}
        if not app_name or width <= 0 or height <= 0:
            continue
        windows.append(
            WindowRecord(
                app_name=app_name,
                window_title=window_title,
                bounds=WindowBounds(x=x, y=y, width=width, height=height),
                is_frontmost=is_frontmost,
                source="system_events",
            )
        )
    return windows


def _quartz_windows(
    *,
    timeout_seconds: int = DEFAULT_TIMEOUT_SECONDS,
    permissions: Optional[PermissionCheckResult] = None,
) -> Tuple[List[WindowRecord], PermissionCheckResult]:
    permissions = permissions or check_macos_permissions(timeout_seconds=timeout_seconds)
    try:
        window_info = Quartz.CGWindowListCopyWindowInfo(
            Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
            Quartz.kCGNullWindowID,
        )
    except Exception:
        return [], permissions

    try:
        windows = _parse_quartz_windows(window_info)
    except Exception:
        return [], permissions
    return windows, permissions


def _system_events_windows(
    *,
    timeout_seconds: int = DEFAULT_TIMEOUT_SECONDS,
    permissions: Optional[PermissionCheckResult] = None,
) -> Tuple[List[WindowRecord], PermissionCheckResult]:
    permissions = permissions or check_macos_permissions(timeout_seconds=timeout_seconds)
    if permissions.accessibility != "granted":
        return [], permissions

    script = r'''
tell application "System Events"
    set output to {}
    repeat with p in application processes
        try
            if visible of p is true then
                set processName to name of p
                set frontState to frontmost of p
                repeat with w in windows of p
                    try
                        set windowName to ""
                        try
                            set windowName to name of w
                        end try
                        set pos to position of w
                        set siz to size of w
                        set end of output to processName & "||" & windowName & "||" & (item 1 of pos) & "||" & (item 2 of pos) & "||" & (item 1 of siz) & "||" & (item 2 of siz) & "||" & frontState
                    end try
                end repeat
            end if
        end try
    end repeat
    return output
end tell
'''
    try:
        output = _run_osascript(script, timeout_seconds=timeout_seconds)
    except (FileNotFoundError, subprocess.TimeoutExpired, subprocess.CalledProcessError):
        return [], permissions
    return _parse_system_events_windows(output), permissions


def probe_visible_windows(*, timeout_seconds: int = DEFAULT_TIMEOUT_SECONDS) -> WindowProbeResult:
    permissions = check_macos_permissions(timeout_seconds=timeout_seconds)
    quartz_windows, permissions = _quartz_windows(timeout_seconds=timeout_seconds, permissions=permissions)
    if quartz_windows:
        return WindowProbeResult(ok=True, source="quartz", permissions=permissions, windows=tuple(quartz_windows))

    system_windows, permissions = _system_events_windows(timeout_seconds=timeout_seconds, permissions=permissions)
    if system_windows:
        return WindowProbeResult(ok=True, source="system_events", permissions=permissions, windows=tuple(system_windows))

    notes: List[str] = []
    if permissions.screen_recording != "granted":
        notes.append("Screen Recording is missing, so Quartz/CGWindow may return empty or nil.")
    if permissions.accessibility != "granted":
        notes.append("Accessibility is missing, so AX/System Events cannot inspect window bounds.")
    if permissions.automation_system_events != "available":
        notes.append("System Events automation fallback is not confirmed.")
    if not notes:
        notes.append("No visible windows were returned by Quartz or System Events.")

    return WindowProbeResult(
        ok=False,
        source="fallback",
        permissions=permissions,
        windows=(),
        error={
            "message": "window probe could not enumerate visible windows",
            "notes": notes,
            "permissions": permissions.to_dict(),
        },
    )


def format_window_report(result: WindowProbeResult) -> str:
    lines = [
        f"Visible windows probe: source={result.source}",
        f"Accessibility: {result.permissions.accessibility}",
        f"Screen Recording: {result.permissions.screen_recording}",
        f"Automation/System Events: {result.permissions.automation_system_events}",
    ]

    if result.windows:
        lines.append("Windows:")
        for index, window in enumerate(result.windows, start=1):
            title = window.window_title or "[empty]"
            frontmost = "true" if window.is_frontmost else "false"
            lines.append(
                f"{index}. app_name={window.app_name} | window_title={title} | "
                f"bounds={{x:{window.bounds.x}, y:{window.bounds.y}, width:{window.bounds.width}, height:{window.bounds.height}}} | "
                f"is_frontmost={frontmost} | source={window.source}"
            )
    elif result.error is not None:
        lines.append(f"Error: {result.error.get('message', 'unknown error')}")
        for note in result.error.get("notes", []):
            lines.append(f"- {note}")
    else:
        lines.append("No visible windows were returned.")

    return "\n".join(lines)
