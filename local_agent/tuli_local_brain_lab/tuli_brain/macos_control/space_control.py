from __future__ import annotations

import re
import subprocess
from dataclasses import asdict, dataclass
from typing import Dict, Optional


SPACE_CONTROL_METHOD = "system_events_keyboard_shortcut"
DEFAULT_TIMEOUT_SECONDS = 5
DIRECT_DESKTOP_NOTE = "direct desktop shortcuts require Mission Control shortcuts enabled."
SPACE_STATUS_NOTE = "macOS uses internal ManagedSpaceID values, not simple Desktop numbers."

SPACE_KEY_CODES = {
    "next": 124,
    "previous": 123,
    "mission-control": 126,
    1: 18,
    2: 19,
    3: 20,
    4: 21,
    5: 23,
    6: 22,
    7: 26,
    8: 28,
    9: 25,
}


@dataclass(frozen=True)
class SpaceControlResult:
    action: str
    method: str = SPACE_CONTROL_METHOD
    success: bool = False
    key_code: Optional[int] = None
    note: Optional[str] = None
    reason: Optional[str] = None

    def to_dict(self) -> Dict[str, object]:
        return asdict(self)


@dataclass(frozen=True)
class SpaceStatusResult:
    success: bool
    method: str = "defaults_read_com_apple_spaces"
    monitors: Optional[int] = None
    current_space_managed_id: Optional[int] = None
    available_spaces_detected: Optional[int] = None
    note: str = SPACE_STATUS_NOTE
    reason: Optional[str] = None

    def to_dict(self) -> Dict[str, object]:
        return asdict(self)


class SpaceControl:
    """Safe macOS Spaces controls using Mission Control keyboard shortcuts."""

    def __init__(self, *, timeout_seconds: int = DEFAULT_TIMEOUT_SECONDS):
        self.timeout_seconds = timeout_seconds

    def next_space(self) -> SpaceControlResult:
        return self._send_shortcut("next", SPACE_KEY_CODES["next"])

    def previous_space(self) -> SpaceControlResult:
        return self._send_shortcut("previous", SPACE_KEY_CODES["previous"])

    def mission_control(self) -> SpaceControlResult:
        return self._send_shortcut("mission-control", SPACE_KEY_CODES["mission-control"])

    def switch_to_desktop(self, number: int) -> SpaceControlResult:
        key_code = SPACE_KEY_CODES.get(number)
        if not isinstance(number, int) or key_code is None:
            return SpaceControlResult(
                action=f"desktop {number}",
                success=False,
                reason="Unsupported desktop number. Use 1 through 9.",
                note=DIRECT_DESKTOP_NOTE,
            )
        return self._send_shortcut(f"desktop {number}", key_code, note=DIRECT_DESKTOP_NOTE)

    def status(self) -> SpaceStatusResult:
        try:
            result = subprocess.run(
                ["/usr/bin/defaults", "read", "com.apple.spaces"],
                check=True,
                capture_output=True,
                text=True,
                timeout=self.timeout_seconds,
            )
        except FileNotFoundError:
            return SpaceStatusResult(success=False, reason="defaults command is not available on this system")
        except subprocess.TimeoutExpired:
            return SpaceStatusResult(success=False, reason=f"defaults read timed out after {self.timeout_seconds}s")
        except subprocess.CalledProcessError as exc:
            stderr = (exc.stderr or exc.stdout or "").strip()
            return SpaceStatusResult(success=False, reason=stderr or f"defaults read failed with exit code {exc.returncode}")

        return _parse_space_defaults(result.stdout or "")

    def _send_shortcut(self, action: str, key_code: int, *, note: Optional[str] = None) -> SpaceControlResult:
        script = f'tell application "System Events" to key code {key_code} using control down'
        try:
            subprocess.run(
                ["/usr/bin/osascript", "-e", script],
                check=True,
                capture_output=True,
                text=True,
                timeout=self.timeout_seconds,
            )
        except FileNotFoundError:
            return SpaceControlResult(action=action, success=False, key_code=key_code, note=note, reason="osascript is not available on this system")
        except subprocess.TimeoutExpired:
            return SpaceControlResult(action=action, success=False, key_code=key_code, note=note, reason=f"osascript timed out after {self.timeout_seconds}s")
        except subprocess.CalledProcessError as exc:
            stderr = (exc.stderr or exc.stdout or "").strip()
            return SpaceControlResult(action=action, success=False, key_code=key_code, note=note, reason=_friendly_osascript_error(stderr or str(exc.returncode)))

        return SpaceControlResult(action=action, success=True, key_code=key_code, note=note)


def _parse_space_defaults(text: str) -> SpaceStatusResult:
    managed_ids = [int(match) for match in re.findall(r"ManagedSpaceID\s*=\s*(\d+)", text)]
    monitor_matches = re.findall(r'"?(?:Display Identifier|DisplayIdentifier|Display UUID|DisplayUUID)"?\s*=', text)
    current_match = re.search(r"Current Space[\s\S]{0,500}?ManagedSpaceID\s*=\s*(\d+)", text)
    current_id = int(current_match.group(1)) if current_match else None
    monitors = len(monitor_matches) if monitor_matches else None

    return SpaceStatusResult(
        success=True,
        monitors=monitors,
        current_space_managed_id=current_id,
        available_spaces_detected=len(set(managed_ids)) if managed_ids else None,
    )


def _friendly_osascript_error(message: str) -> str:
    if "-10827" in message:
        return "System Events could not send the Spaces keyboard shortcut."
    if "not allowed" in message.lower() or "not authorized" in message.lower():
        return "Automation or Accessibility permission is not available for System Events."
    return message or "System Events could not send the Spaces keyboard shortcut."


def format_space_control_result(result: SpaceControlResult) -> str:
    if result.success:
        lines = [
            "Space control:",
            f"- action: {result.action}",
            f"- method: {result.method}",
            "- success: true",
        ]
        if result.note:
            lines.append(f"- note: {result.note}")
        return "\n".join(lines)

    lines = [
        "Space control failed:",
        f"- action: {result.action}",
        f"- method: {result.method}",
        f"- reason: {result.reason or 'System Events could not send the Spaces keyboard shortcut.'}",
    ]
    if result.note:
        lines.append(f"- note: {result.note}")
    return "\n".join(lines)


def format_space_status_result(result: SpaceStatusResult) -> str:
    if result.success:
        return (
            "Space status:\n"
            f"- monitors: {result.monitors if result.monitors is not None else 'unknown'}\n"
            f"- current_space_managed_id: {result.current_space_managed_id if result.current_space_managed_id is not None else 'unknown'}\n"
            f"- available_spaces_detected: {result.available_spaces_detected if result.available_spaces_detected is not None else 'unknown'}\n"
            f"- note: {result.note}"
        )

    return (
        "Space status failed:\n"
        f"- method: {result.method}\n"
        f"- reason: {result.reason or 'Could not read macOS Spaces status.'}\n"
        f"- note: {result.note}"
    )
