from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Any, Dict, Iterable, List, Mapping, Optional, Tuple


LAYOUT_MODES = ("normal", "split")
LAYOUT_SLOT_IDS = ("main", "left", "right", "free")


def _slot_defaults(slot_id: str) -> Dict[str, Any]:
    return {
        "slot_id": slot_id,
        "occupied": False,
        "app_name": None,
        "window_title": None,
        "window_id": None,
        "bounds": None,
        "source": None,
        "assigned_at": None,
    }


@dataclass(frozen=True)
class LayoutSlot:
    slot_id: str
    occupied: bool = False
    app_name: Optional[str] = None
    window_title: Optional[str] = None
    window_id: Optional[int] = None
    bounds: Optional[Mapping[str, Any]] = None
    source: Optional[str] = None
    assigned_at: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        data = asdict(self)
        if self.bounds is not None:
            data["bounds"] = dict(self.bounds)
        return data

    @classmethod
    def free(cls, slot_id: str) -> "LayoutSlot":
        return cls(slot_id=slot_id)

    @classmethod
    def from_dict(cls, payload: Mapping[str, Any]) -> "LayoutSlot":
        bounds = payload.get("bounds")
        return cls(
            slot_id=str(payload.get("slot_id") or "").strip() or "free",
            occupied=bool(payload.get("occupied", False)),
            app_name=payload.get("app_name") or None,
            window_title=payload.get("window_title") or None,
            window_id=payload.get("window_id") if isinstance(payload.get("window_id"), int) else None,
            bounds=dict(bounds) if isinstance(bounds, Mapping) else None,
            source=payload.get("source") or None,
            assigned_at=payload.get("assigned_at") or None,
        )


@dataclass(frozen=True)
class LayoutState:
    mode: str
    slots: Mapping[str, LayoutSlot] = field(default_factory=dict)
    active_screen_id: Optional[str] = None
    dry_run: bool = False
    updated_at: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        return {
            "mode": self.mode,
            "slots": {slot_id: slot.to_dict() for slot_id, slot in self.slots.items()},
            "active_screen_id": self.active_screen_id,
            "dry_run": self.dry_run,
            "updated_at": self.updated_at,
        }

    @classmethod
    def from_dict(cls, payload: Mapping[str, Any]) -> "LayoutState":
        slots_raw = payload.get("slots")
        slots: Dict[str, LayoutSlot] = {}
        if isinstance(slots_raw, Mapping):
            for slot_id, slot_payload in slots_raw.items():
                if isinstance(slot_payload, Mapping):
                    slots[str(slot_id)] = LayoutSlot.from_dict({**slot_payload, "slot_id": slot_id})
        return cls(
            mode=str(payload.get("mode") or "normal"),
            slots=slots,
            active_screen_id=payload.get("active_screen_id") or None,
            dry_run=bool(payload.get("dry_run", False)),
            updated_at=payload.get("updated_at") or None,
        )

    def normalized(self) -> "LayoutState":
        slots = {slot_id: self.slots.get(slot_id, LayoutSlot.free(slot_id)) for slot_id in LAYOUT_SLOT_IDS}
        return LayoutState(
            mode=self.mode if self.mode in LAYOUT_MODES else "normal",
            slots=slots,
            active_screen_id=self.active_screen_id,
            dry_run=self.dry_run,
            updated_at=self.updated_at,
        )


@dataclass(frozen=True)
class LayoutPlan:
    mode: str
    dry_run: bool
    visible_windows_count: int
    detected_windows: Tuple[Mapping[str, Any], ...] = ()
    assignments: Tuple[LayoutSlot, ...] = ()
    warnings: Tuple[str, ...] = ()
    errors: Tuple[str, ...] = ()
    source: str = "fallback"
    active_screen_id: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        return {
            "mode": self.mode,
            "dry_run": self.dry_run,
            "visible_windows_count": self.visible_windows_count,
            "detected_windows": [dict(item) for item in self.detected_windows],
            "assignments": [assignment.to_dict() for assignment in self.assignments],
            "warnings": list(self.warnings),
            "errors": list(self.errors),
            "source": self.source,
            "active_screen_id": self.active_screen_id,
        }
