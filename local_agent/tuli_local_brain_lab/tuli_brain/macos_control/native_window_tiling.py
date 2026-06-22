from __future__ import annotations

import subprocess
from dataclasses import asdict, dataclass
from typing import Dict, Mapping, Optional


NATIVE_TILING_METHOD = "system_events_window_menu"
NATIVE_TILING_ACTIONS = (
    "fill",
    "center",
    "left",
    "right",
    "top",
    "bottom",
    "top-left",
    "top-right",
    "bottom-left",
    "bottom-right",
    "left-right",
    "quarters",
    "return",
)
NATIVE_TILING_METHODS = (NATIVE_TILING_METHOD, "unsupported")
DEFAULT_TIMEOUT_SECONDS = 5

NATIVE_TILING_MENU_ACTIONS: Dict[str, Mapping[str, str]] = {
    "fill": {"menu": "Window", "item": "Fill"},
    "center": {"menu": "Window", "item": "Center"},
    "left": {"menu": "Window", "submenu": "Move & Resize", "item": "Left"},
    "right": {"menu": "Window", "submenu": "Move & Resize", "item": "Right"},
    "top": {"menu": "Window", "submenu": "Move & Resize", "item": "Top"},
    "bottom": {"menu": "Window", "submenu": "Move & Resize", "item": "Bottom"},
    "top-left": {"menu": "Window", "submenu": "Move & Resize", "item": "Top Left"},
    "top-right": {"menu": "Window", "submenu": "Move & Resize", "item": "Top Right"},
    "bottom-left": {"menu": "Window", "submenu": "Move & Resize", "item": "Bottom Left"},
    "bottom-right": {"menu": "Window", "submenu": "Move & Resize", "item": "Bottom Right"},
    "left-right": {"menu": "Window", "submenu": "Move & Resize", "item": "Left & Right"},
    "quarters": {"menu": "Window", "submenu": "Move & Resize", "item": "Quarters"},
    "return": {"menu": "Window", "submenu": "Move & Resize", "item": "Return to Previous Size"},
}


@dataclass(frozen=True)
class NativeTilingResult:
    action: str
    target: str = "frontmost window"
    method: str = "unsupported"
    success: bool = False
    menu_path: Optional[str] = None
    frontmost_app: Optional[str] = None
    reason: Optional[str] = None
    suggestion: Optional[str] = None

    def to_dict(self) -> Dict[str, object]:
        return asdict(self)


class NativeWindowTiling:
    """Invoke macOS native window tiling controls without manual bounds."""

    def __init__(self, *, timeout_seconds: int = DEFAULT_TIMEOUT_SECONDS):
        self.timeout_seconds = timeout_seconds

    def apply(self, action: str) -> NativeTilingResult:
        normalized = str(action or "").strip().lower()
        menu_action = NATIVE_TILING_MENU_ACTIONS.get(normalized)
        if menu_action is None:
            return NativeTilingResult(
                action=normalized or "unknown",
                method="unsupported",
                success=False,
                reason=f"Unsupported native tiling action: {action}",
                suggestion=f"Use one of: {', '.join(NATIVE_TILING_ACTIONS)}.",
            )

        result = self._click_window_menu_item(normalized, menu_action)
        if result.success:
            return result

        return NativeTilingResult(
            action=normalized,
            method=NATIVE_TILING_METHOD,
            success=False,
            menu_path=result.menu_path,
            frontmost_app=result.frontmost_app,
            reason=result.reason or "menu item not found or System Events denied access",
            suggestion="Try enabling Accessibility/Automation for System Events, or choose an app/window that exposes this native Window menu item.",
        )

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
            raise RuntimeError("osascript is not available on this system") from exc
        except subprocess.TimeoutExpired as exc:
            raise RuntimeError(f"osascript timed out after {self.timeout_seconds}s") from exc
        except subprocess.CalledProcessError as exc:
            stderr = (exc.stderr or exc.stdout or "").strip()
            raise RuntimeError(stderr or f"osascript failed with exit code {exc.returncode}") from exc
        return result.stdout.strip()

    def _click_window_menu_item(self, action: str, menu_action: Mapping[str, str]) -> NativeTilingResult:
        menu = menu_action["menu"]
        submenu = menu_action.get("submenu")
        item = menu_action["item"]
        menu_path = " > ".join(part for part in (menu, submenu, item) if part)
        menu_literal = _apple_script_string_literal(menu)
        submenu_literal = _apple_script_string_literal(submenu) if submenu else ""
        item_literal = _apple_script_string_literal(item)
        if submenu:
            click_block = f'''
    if not (exists menu item {submenu_literal} of windowMenu) then error "menu item not found: {menu_path}"
    set targetMenu to menu 1 of menu item {submenu_literal} of windowMenu
    if not (exists menu item {item_literal} of targetMenu) then error "menu item not found: {menu_path}"
    click menu item {item_literal} of targetMenu
'''
        else:
            click_block = f'''
    if not (exists menu item {item_literal} of windowMenu) then error "menu item not found: {menu_path}"
    click menu item {item_literal} of windowMenu
'''
        script = f'''
tell application "System Events"
    set frontApp to first application process whose frontmost is true
    set appName to name of frontApp
    if not (exists menu bar 1 of frontApp) then error "Frontmost app has no accessible menu bar."
    if not (exists menu bar item {menu_literal} of menu bar 1 of frontApp) then error "menu item not found: {menu}"
    set windowMenu to menu 1 of menu bar item {menu_literal} of menu bar 1 of frontApp
{click_block}
    return appName & "||" & { _apple_script_string_literal(menu_path) }
end tell
'''
        try:
            raw = self._run_osascript(script)
        except RuntimeError as exc:
            reason = _friendly_osascript_error(str(exc))
            return NativeTilingResult(
                action=action,
                method=NATIVE_TILING_METHOD,
                success=False,
                menu_path=menu_path,
                reason=reason,
            )

        parts = raw.split("||")
        frontmost_app = parts[0].strip() if parts else None
        returned_menu_path = parts[1].strip() if len(parts) > 1 and parts[1].strip() else menu_path
        return NativeTilingResult(
            action=action,
            method=NATIVE_TILING_METHOD,
            success=True,
            menu_path=returned_menu_path,
            frontmost_app=frontmost_app or None,
        )


def _apple_script_string_literal(text: str) -> str:
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _friendly_osascript_error(message: str) -> str:
    if "-10827" in message:
        return "menu item not found or System Events denied access"
    if "-1719" in message or "Invalid index" in message:
        return "menu item not found or System Events denied access"
    if "not allowed" in message.lower() or "not authorized" in message.lower():
        return "Automation or Accessibility permission is not available for System Events."
    if "menu item not found" in message.lower():
        return "menu item not found or System Events denied access"
    return message or "menu item not found or System Events denied access"


def format_native_tiling_result(result: NativeTilingResult) -> str:
    if result.success:
        lines = [
            "Native window tiling:",
            f"- action: {result.action}",
            f"- target: {result.target}",
            f"- method: {result.method}",
            f"- menu_path: {result.menu_path or 'unknown'}",
        ]
        if result.frontmost_app:
            lines.append(f"- frontmost_app: {result.frontmost_app}")
        lines.append("- success: true")
        return "\n".join(lines)

    return (
        "Native window tiling failed:\n"
        f"- action: {result.action}\n"
        f"- method: {result.method}\n"
        f"- reason: {result.reason or 'menu item not found or System Events denied access'}"
    )
