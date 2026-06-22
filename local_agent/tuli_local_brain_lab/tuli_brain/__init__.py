"""Local-first brain package for Tuli."""

from .brain import respond
from .macos_control import MacOSControl, MacOSControlError, MacOSControlResult, MacOSObservation, observe_frontmost_state
from .macos_control import PermissionCheckResult, WindowBounds, WindowProbeResult, WindowRecord, check_macos_permissions, format_permissions_report, format_window_report, probe_visible_windows
from .config import TuliBrainConfig, load_config
from .models import DEFAULT_MODEL_CATALOG, ModelCatalog, ModelDecision, ModelRouteResult, ModelSpec, choose_model

__all__ = [
    "TuliBrainConfig",
    "load_config",
    "respond",
    "DEFAULT_MODEL_CATALOG",
    "ModelCatalog",
    "ModelDecision",
    "ModelRouteResult",
    "ModelSpec",
    "choose_model",
    "MacOSControl",
    "MacOSControlError",
    "MacOSControlResult",
    "MacOSObservation",
    "observe_frontmost_state",
    "PermissionCheckResult",
    "WindowBounds",
    "WindowProbeResult",
    "WindowRecord",
    "check_macos_permissions",
    "format_permissions_report",
    "format_window_report",
    "probe_visible_windows",
]
