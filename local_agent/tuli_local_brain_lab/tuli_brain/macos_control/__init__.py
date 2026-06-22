"""Safe macOS observation helpers for Tuli."""

from .macos_control import MacOSControl, MacOSControlError, list_known_applications, observe_frontmost_state
from .macos_control_types import MacOSControlResult, MacOSObservation
from .mac_window_probe import WindowBounds, WindowProbeResult, WindowRecord, format_window_report, probe_visible_windows
from .native_window_tiling import NativeTilingResult, NativeWindowTiling, format_native_tiling_result
from .permissions_check import PermissionCheckResult, check_accessibility, check_macos_permissions, check_screen_recording, check_system_events_automation, format_permissions_report
from .space_control import SpaceControl, SpaceControlResult, SpaceStatusResult, format_space_control_result, format_space_status_result

__all__ = [
    "MacOSControl",
    "MacOSControlError",
    "MacOSControlResult",
    "MacOSObservation",
    "NativeTilingResult",
    "NativeWindowTiling",
    "PermissionCheckResult",
    "SpaceControl",
    "SpaceControlResult",
    "SpaceStatusResult",
    "WindowBounds",
    "WindowProbeResult",
    "WindowRecord",
    "check_accessibility",
    "check_macos_permissions",
    "check_screen_recording",
    "check_system_events_automation",
    "format_permissions_report",
    "format_native_tiling_result",
    "format_space_control_result",
    "format_space_status_result",
    "format_window_report",
    "list_known_applications",
    "observe_frontmost_state",
    "probe_visible_windows",
]
