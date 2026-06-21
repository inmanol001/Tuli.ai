"""Model selection and routing for Tuli."""

from .model_catalog import DEFAULT_MODEL_CATALOG, ModelCatalog, ModelSpec
from .model_router import (
    ModelDecision,
    ModelRouteResult,
    choose_model,
    default_model_for_route,
    model_route_label,
    model_route_summary,
)

__all__ = [
    "DEFAULT_MODEL_CATALOG",
    "ModelCatalog",
    "ModelSpec",
    "ModelDecision",
    "ModelRouteResult",
    "choose_model",
    "default_model_for_route",
    "model_route_label",
    "model_route_summary",
]
