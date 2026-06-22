from __future__ import annotations

from datetime import datetime
from typing import Mapping, Optional, Sequence

from .models import LAYOUT_SLOT_IDS, LayoutSlot, LayoutState


def utc_now() -> str:
    return datetime.utcnow().replace(microsecond=0).isoformat() + "Z"


def build_empty_state(*, mode: str = "normal", updated_at: Optional[str] = None, dry_run: bool = False) -> LayoutState:
    slots = {slot_id: LayoutSlot.free(slot_id) for slot_id in LAYOUT_SLOT_IDS}
    return LayoutState(
        mode=mode,
        slots=slots,
        active_screen_id=None,
        dry_run=dry_run,
        updated_at=updated_at or utc_now(),
    )


def build_normal_state(*, updated_at: Optional[str] = None) -> LayoutState:
    return build_empty_state(mode="normal", updated_at=updated_at, dry_run=False)


def build_split_state(
    *,
    selected_window: Optional[Mapping[str, object]],
    updated_at: Optional[str] = None,
    active_screen_id: Optional[str] = None,
    source: str = "fallback",
) -> LayoutState:
    slots = {slot_id: LayoutSlot.free(slot_id) for slot_id in LAYOUT_SLOT_IDS}
    if selected_window is not None:
        slots["left"] = LayoutSlot(
            slot_id="left",
            occupied=True,
            app_name=str(selected_window.get("app_name") or "unknown"),
            window_title=selected_window.get("window_title") or None,
            window_id=selected_window.get("window_id") if isinstance(selected_window.get("window_id"), int) else None,
            bounds=selected_window.get("bounds") if isinstance(selected_window.get("bounds"), Mapping) else None,
            source=str(selected_window.get("source") or source),
            assigned_at=updated_at or utc_now(),
        )

    return LayoutState(
        mode="split",
        slots=slots,
        active_screen_id=active_screen_id,
        dry_run=True,
        updated_at=updated_at or utc_now(),
    )
