from __future__ import annotations

from dataclasses import dataclass

from ..tools import DEFAULT_TOOL_CATALOG, ToolCall, ToolCatalog
from .intent_types import ActionPlan, IntentResult


@dataclass
class ActionPlanner:
    catalog: ToolCatalog = DEFAULT_TOOL_CATALOG

    def plan(self, intent: IntentResult) -> ActionPlan:
        if intent.confidence < 0.65:
            return ActionPlan(
                should_execute=False,
                requires_confirmation=intent.requires_confirmation,
                reason="low_confidence",
                bubble_text=intent.bubble_text or "I am not confident enough yet.",
                console_text=f"Intent confidence too low: {intent.confidence:.2f}",
            )

        if intent.requires_confirmation:
            return ActionPlan(
                should_execute=False,
                requires_confirmation=True,
                reason="requires_confirmation",
                bubble_text=intent.bubble_text or "I need confirmation first.",
                console_text=f"Intent requires confirmation for tool {intent.tool_name}",
            )

        tool_spec = self.catalog.get(intent.tool_name)
        if tool_spec is None:
            return ActionPlan(
                should_execute=False,
                requires_confirmation=False,
                reason="tool_not_found",
                bubble_text="I could not find that tool.",
                console_text=f"Tool not found: {intent.tool_name}",
            )

        if tool_spec.risk_level not in {"safe", "low_risk"}:
            return ActionPlan(
                should_execute=False,
                requires_confirmation=tool_spec.requires_confirmation,
                reason="unsupported_risk_level",
                bubble_text=intent.bubble_text or "I need to review that action first.",
                console_text=f"Tool risk level is not auto-executable: {tool_spec.risk_level}",
            )

        tool_call = ToolCall(
            tool_name=intent.tool_name,
            arguments=dict(intent.arguments),
            source_text=intent.source_text,
            confidence=intent.confidence,
            requires_confirmation=intent.requires_confirmation,
            response_text=intent.response_text,
            bubble_text=intent.bubble_text,
            console_text=f"Planned tool call for {intent.tool_name}",
        )
        return ActionPlan(
            should_execute=True,
            tool_call=tool_call,
            requires_confirmation=False,
            reason="ready",
            bubble_text=intent.bubble_text,
            console_text=f"Action plan ready for {intent.tool_name}",
        )
