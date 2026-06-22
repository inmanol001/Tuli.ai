from __future__ import annotations

from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

from ..macos_control.mac_window_probe import WindowProbeResult, WindowRecord, probe_visible_windows
from .models import LAYOUT_SLOT_IDS, LayoutPlan, LayoutSlot, LayoutState
from .presets import build_empty_state, build_normal_state, build_split_state, utc_now
from .state_store import LayoutStateStore


def _window_to_dict(window: WindowRecord) -> Dict[str, Any]:
    return window.to_dict()


def _pick_primary_window(windows: Sequence[WindowRecord]) -> Optional[WindowRecord]:
    if not windows:
        return None
    for window in windows:
        if window.is_frontmost:
            return window
    return windows[0]


def _warning_for_source(source: str) -> Optional[str]:
    if source != "quartz":
        return f"Inventory source is {source}; Quartz was not used."
    return None


def _state_line(slot: LayoutSlot) -> str:
    if not slot.occupied:
        return f"- {slot.slot_id}: free"
    title = slot.window_title or "[empty title]"
    return f"- {slot.slot_id}: {slot.app_name or 'unknown'} — {title}"


def _window_line(index: int, window: Mapping[str, Any]) -> str:
    title = str(window.get("window_title") or "[empty title]")
    bounds = window.get("bounds")
    if isinstance(bounds, Mapping):
        x = bounds.get("x", bounds.get("X", 0))
        y = bounds.get("y", bounds.get("Y", 0))
        width = bounds.get("width", bounds.get("Width", 0))
        height = bounds.get("height", bounds.get("Height", 0))
    else:
        x = y = width = height = 0
    return (
        f"{index}. {window.get('app_name', 'unknown')} — {title} | "
        f"bounds={{x:{x}, y:{y}, width:{width}, height:{height}}} | "
        f"frontmost={'true' if window.get('is_frontmost', False) else 'false'} | source={window.get('source', 'fallback')}"
    )


class LayoutManager:
    def __init__(self, *, state_store: Optional[LayoutStateStore] = None):
        self.state_store = state_store or LayoutStateStore()

    def get_state(self) -> LayoutState:
        return self.state_store.read_or_create()

    def status(self) -> LayoutState:
        return self.get_state()

    def clear(self) -> LayoutState:
        return self.state_store.clear()

    def preview(self) -> LayoutPlan:
        state = self.get_state()
        probe = probe_visible_windows()
        return self._build_plan(state=state, probe=probe, persist=False)

    def split(self) -> LayoutPlan:
        state = self.get_state()
        probe = probe_visible_windows()
        plan = self._build_plan(state=state, probe=probe, persist=True)
        return plan

    def _build_plan(self, *, state: LayoutState, probe: WindowProbeResult, persist: bool) -> LayoutPlan:
        windows = list(probe.windows)
        selected = _pick_primary_window(windows)
        warnings: List[str] = []
        errors: List[str] = []
        if probe.source != "quartz":
            warning = _warning_for_source(probe.source)
            if warning:
                warnings.append(warning)
        if probe.error is not None:
            errors.append(str(probe.error.get("message", "window probe error")))

        if state.mode not in {"normal", "split"}:
            state = build_normal_state(updated_at=state.updated_at)

        if persist:
            new_state = build_split_state(
                selected_window=selected.to_dict() if selected is not None else None,
                updated_at=utc_now(),
                active_screen_id=state.active_screen_id,
                source=probe.source,
            )
            self.state_store.write(new_state)

        if len(windows) > 1:
            warnings.append(f"{len(windows) - 1} additional visible window(s) are not assigned yet.")
        if selected is None:
            warnings.append("No visible window was selected for the left slot.")

        assignments = [
            LayoutSlot.free("main"),
            LayoutSlot(
                slot_id="left",
                occupied=selected is not None,
                app_name=selected.app_name if selected is not None else None,
                window_title=selected.window_title if selected is not None else None,
                window_id=selected.window_id if selected is not None else None,
                bounds=selected.bounds.to_dict() if selected is not None else None,
                source=selected.source if selected is not None else None,
                assigned_at=utc_now() if selected is not None else None,
            ),
            LayoutSlot.free("right"),
            LayoutSlot.free("free"),
        ]

        return LayoutPlan(
            mode="split" if persist else state.mode,
            dry_run=True,
            visible_windows_count=len(windows),
            detected_windows=tuple(_window_to_dict(window) for window in windows),
            assignments=tuple(assignments),
            warnings=tuple(warnings),
            errors=tuple(errors),
            source=probe.source,
            active_screen_id=state.active_screen_id,
        )

    def format_status(self, state: LayoutState) -> str:
        normalized = state.normalized()
        lines = [
            f"Layout mode: {normalized.mode}",
            f"Last updated: {normalized.updated_at or 'unknown'}",
            "Slots:",
        ]
        for slot_id in LAYOUT_SLOT_IDS:
            lines.append(_state_line(normalized.slots[slot_id]))
        return "\n".join(lines)

    def format_plan(self, plan: LayoutPlan, *, title: str = "Layout plan") -> str:
        lines = [
            f"Layout mode: {plan.mode}",
        ]
        if title and title != "Layout plan":
            lines.append(f"Plan: {title}")
        lines.extend(
            [
                f"Dry-run: {'true' if plan.dry_run else 'false'}",
                f"Detected windows: {plan.visible_windows_count}",
                "Assigned:",
            ]
        )
        for slot in plan.assignments:
            lines.append(_state_line(slot))
        if plan.warnings:
            lines.append("Warnings:")
            for warning in plan.warnings:
                lines.append(f"- {warning}")
        if plan.errors:
            lines.append("Errors:")
            for error in plan.errors:
                lines.append(f"- {error}")
        lines.append("No windows were moved.")
        return "\n".join(lines)

    def format_preview(self, plan: LayoutPlan) -> str:
        lines = [
            f"Layout mode: {plan.mode}",
            f"Dry-run: {'true' if plan.dry_run else 'false'}",
            f"Visible windows: {plan.visible_windows_count}",
            f"Source: {plan.source}",
            "Assignments:",
        ]
        for slot in plan.assignments:
            lines.append(_state_line(slot))
        if plan.warnings:
            lines.append("Warnings:")
            for warning in plan.warnings:
                lines.append(f"- {warning}")
        if plan.errors:
            lines.append("Errors:")
            for error in plan.errors:
                lines.append(f"- {error}")
        if plan.detected_windows:
            lines.append("Detected windows:")
            for index, window in enumerate(plan.detected_windows, start=1):
                lines.append(_window_line(index, window))
        return "\n".join(lines)
