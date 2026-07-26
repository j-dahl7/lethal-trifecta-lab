"""Policy engine for fail-closed Rule-of-Two evaluation."""

import logging
from dataclasses import dataclass

from session_tracker import evaluate_and_record
from tool_registry import get_condition_for_tool, is_known_tool


@dataclass(frozen=True)
class GateResult:
    decision: str
    tool_name: str
    condition: str | None
    reason: str
    session_id: str
    conditions_before: list[str]
    conditions_after: list[str]

    def to_dict(self) -> dict:
        return {
            "decision": self.decision,
            "tool_name": self.tool_name,
            "condition": self.condition,
            "reason": self.reason,
            "session_id": self.session_id,
            "conditions_before": self.conditions_before,
            "conditions_after": self.conditions_after,
        }


def evaluate(session_id: str, tool_name: str) -> GateResult:
    """Evaluate and atomically record a registered tool call."""
    if not is_known_tool(tool_name):
        logging.warning("Blocked an unregistered tool")
        return GateResult(
            decision="BLOCK",
            tool_name=tool_name,
            condition=None,
            reason="Tool is not registered; fail-closed policy blocked the call.",
            session_id=session_id,
            conditions_before=[],
            conditions_after=[],
        )

    condition = get_condition_for_tool(tool_name)
    transition = evaluate_and_record(session_id, tool_name, condition)
    before = list(transition.conditions_before)
    after = list(transition.conditions_after)

    if not transition.allowed:
        logging.warning("Blocked a tool call that would complete the trifecta")
        return GateResult(
            decision="BLOCK",
            tool_name=tool_name,
            condition=condition,
            reason=(
                f"Tool '{tool_name}' would satisfy condition '{condition}', "
                "completing all 3 trifecta conditions. Blocked by Rule of Two."
            ),
            session_id=session_id,
            conditions_before=before,
            conditions_after=after,
        )

    logging.info("Allowed registered tool call; active conditions=%d", len(after))
    return GateResult(
        decision="ALLOW",
        tool_name=tool_name,
        condition=condition,
        reason=f"Tool '{tool_name}' allowed. Condition '{condition}' recorded.",
        session_id=session_id,
        conditions_before=before,
        conditions_after=after,
    )
