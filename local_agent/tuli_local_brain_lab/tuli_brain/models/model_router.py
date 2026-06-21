from __future__ import annotations

from dataclasses import dataclass, asdict
from typing import Any, Dict, Optional

from ..commands.command_types import ParsedCommand
from ..modes.mode_types import ModeDecision
from .model_catalog import DEFAULT_MODEL_CATALOG, ModelCatalog, ModelSpec


@dataclass(frozen=True)
class ModelDecision:
    """Chosen model for a Tuli turn."""

    requested_model: Optional[str]
    resolved_model: str
    provider: str
    reason: str
    purpose: str
    latency_tier: str

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True)
class ModelRouteResult:
    """Routing result from command + mode + model catalog."""

    command_name: Optional[str]
    route: str
    mode: str
    model: ModelDecision

    def to_dict(self) -> Dict[str, Any]:
        return {
            "command_name": self.command_name,
            "route": self.route,
            "mode": self.mode,
            "model": self.model.to_dict(),
        }


def default_model_for_route(route: str, *, mode: str = "instant", catalog: ModelCatalog = DEFAULT_MODEL_CATALOG) -> ModelSpec:
    spec = catalog.default_for(route, mode=mode)
    if spec is not None:
        return spec
    fallback = catalog.get("qwen3:1.7b")
    if fallback is None:
        raise RuntimeError("default model catalog is missing qwen3:1.7b")
    return fallback


def _purpose_from_route(route: str, mode: str) -> str:
    if route in {"dev_task", "debug_deep"}:
        return "code"
    if route in {"workflow", "memory_analysis"}:
        return "reasoning"
    if route in {"mac_action", "skill_routing"}:
        return "skill_routing"
    if mode == "thinking":
        return "reasoning"
    return "chat"


def choose_model(
    *,
    command_name: Optional[str],
    route: str,
    mode: str,
    parsed: Optional[ParsedCommand] = None,
    mode_decision: Optional[ModeDecision] = None,
    requested_model: Optional[str] = None,
    catalog: ModelCatalog = DEFAULT_MODEL_CATALOG,
) -> ModelRouteResult:
    if requested_model:
        spec = catalog.get(requested_model)
        if spec is None:
            spec = default_model_for_route(route, mode=mode, catalog=catalog)
            reason = f"requested model unavailable; using {spec.name}"
        else:
            reason = "requested model"
    else:
        spec = default_model_for_route(route, mode=mode, catalog=catalog)
        reason = "route default"

    purpose = _purpose_from_route(route, mode)
    if purpose == "code" and not spec.supports_code:
        code_model = catalog.get("qwen2.5-coder:7b")
        if code_model is not None:
            spec = code_model
            reason = "route requires code-capable model"
    if purpose == "skill_routing" and not spec.supports_skill_routing:
        skill_model = catalog.get("cmdmbox/skill-expert:latest")
        if skill_model is not None:
            spec = skill_model
            reason = "route requires skill routing model"

    return ModelRouteResult(
        command_name=command_name,
        route=route,
        mode=mode,
        model=ModelDecision(
            requested_model=requested_model,
            resolved_model=spec.name,
            provider=spec.provider,
            reason=reason,
            purpose=purpose,
            latency_tier=spec.latency_tier,
        ),
    )


def model_route_summary(result: ModelRouteResult) -> Dict[str, Any]:
    return result.to_dict()


def model_route_label(result: ModelRouteResult) -> str:
    return result.model.resolved_model

