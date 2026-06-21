from __future__ import annotations

from dataclasses import dataclass, field, asdict
from typing import Any, Dict, List, Optional, Tuple


MODEL_PURPOSES = ("chat", "fast_triage", "reasoning", "code", "skill_routing")


@dataclass(frozen=True)
class ModelSpec:
    """Metadata about one local model available to Tuli."""

    name: str
    provider: str = "ollama_local"
    purpose: str = "chat"
    description: str = ""
    latency_tier: str = "balanced"
    default_for: Tuple[str, ...] = ()
    supports_thinking: bool = True
    supports_code: bool = False
    supports_skill_routing: bool = False

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


@dataclass
class ModelCatalog:
    """Canonical model catalog for routing decisions."""

    models: Dict[str, ModelSpec] = field(default_factory=dict)

    @classmethod
    def with_defaults(cls) -> "ModelCatalog":
        catalog = cls()
        catalog.register(
            ModelSpec(
                name="qwen3-0.6b-ud-q8-k-xl-local:latest",
                purpose="fast_triage",
                description="Very fast local triage model for intent detection.",
                latency_tier="fast",
                default_for=("triage",),
                supports_thinking=False,
            )
        )
        catalog.register(
            ModelSpec(
                name="qwen3:1.7b",
                purpose="chat",
                description="Default local chat model for Tuli.",
                latency_tier="fast",
                default_for=("chat", "simple_command", "instant"),
                supports_thinking=True,
            )
        )
        catalog.register(
            ModelSpec(
                name="qwen3:4b",
                purpose="reasoning",
                description="Deeper reasoning model for complex thinking turns.",
                latency_tier="balanced",
                default_for=("thinking", "workflow", "memory_analysis"),
                supports_thinking=True,
            )
        )
        catalog.register(
            ModelSpec(
                name="qwen2.5-coder:7b",
                purpose="code",
                description="Coding and debugging model.",
                latency_tier="slower",
                default_for=("dev_task", "debug_deep"),
                supports_thinking=True,
                supports_code=True,
            )
        )
        catalog.register(
            ModelSpec(
                name="cmdmbox/skill-expert:latest",
                purpose="skill_routing",
                description="Model for command and skill normalization.",
                latency_tier="balanced",
                default_for=("skill_routing", "workflow"),
                supports_thinking=True,
                supports_skill_routing=True,
            )
        )
        return catalog

    def register(self, spec: ModelSpec) -> None:
        if spec.purpose not in MODEL_PURPOSES:
            raise ValueError(f"invalid model purpose: {spec.purpose}")
        self.models[spec.name] = spec

    def get(self, name: str) -> Optional[ModelSpec]:
        return self.models.get(name)

    def list(self) -> List[ModelSpec]:
        return sorted(self.models.values(), key=lambda spec: (spec.purpose, spec.name))

    def default_for(self, route: str, *, mode: str = "instant") -> Optional[ModelSpec]:
        if mode == "instant":
            return self.models.get("qwen3:1.7b")
        if route in {"dev_task", "debug_deep"}:
            return self.models.get("qwen2.5-coder:7b")
        if route in {"workflow", "memory_analysis"}:
            return self.models.get("qwen3:4b")
        if route in {"mac_action", "skill_routing"}:
            return self.models.get("cmdmbox/skill-expert:latest")
        if route == "fast_chat":
            return self.models.get("qwen3:1.7b")
        return self.models.get("qwen3:4b")

    def supports_code(self, name: str) -> bool:
        spec = self.get(name)
        return bool(spec.supports_code) if spec is not None else False

    def supports_skill_routing(self, name: str) -> bool:
        spec = self.get(name)
        return bool(spec.supports_skill_routing) if spec is not None else False

    def model_names(self) -> Tuple[str, ...]:
        return tuple(spec.name for spec in self.list())


DEFAULT_MODEL_CATALOG = ModelCatalog.with_defaults()

