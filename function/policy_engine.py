"""
Policy Engine - Evaluates tool calls against the Rule of Two.

The Rule of Two: Any 2 of the 3 trifecta conditions are allowed.
The 3rd condition (which would complete the trifecta) is blocked.
"""

import logging
from dataclasses import dataclass

from tool_registry import get_condition_for_tool, is_known_tool
from session_tracker import (
    would_complete_trifecta,
    record_tool_call,
    get_session_state,
)


@dataclass
class GateResult:
    decision: str  # "ALLOW" or "BLOCK"
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
    """
    Evaluate a tool call against the trifecta policy.

    Returns a GateResult with ALLOW or BLOCK decision.
    """
    # Get current session state before evaluation
    state_before = get_session_state(session_id)
    conditions_before = state_before["active_conditions"]

    # Unknown tools are allowed (they don't map to any condition)
    if not is_known_tool(tool_name):
        logging.info(f"Unknown tool '{tool_name}' allowed (no condition mapping)")
        return GateResult(
            decision="ALLOW",
            tool_name=tool_name,
            condition=None,
            reason=f"Tool '{tool_name}' is not in the registry; no condition applies",
            session_id=session_id,
            conditions_before=conditions_before,
            conditions_after=conditions_before,
        )

    condition = get_condition_for_tool(tool_name)

    # Check if this would complete the trifecta
    if would_complete_trifecta(session_id, condition):
        logging.warning(
            f"BLOCKED: Tool '{tool_name}' (condition: {condition}) would complete "
            f"the trifecta in session {session_id}"
        )
        return GateResult(
            decision="BLOCK",
            tool_name=tool_name,
            condition=condition,
            reason=(
                f"Tool '{tool_name}' would satisfy condition '{condition}', "
                f"completing all 3 trifecta conditions. Blocked by Rule of Two."
            ),
            session_id=session_id,
            conditions_before=conditions_before,
            conditions_after=conditions_before,  # No change on block
        )

    # Allow and record the tool call
    record_tool_call(session_id, tool_name, condition)
    state_after = get_session_state(session_id)

    logging.info(
        f"ALLOWED: Tool '{tool_name}' (condition: {condition}) in session "
        f"{session_id}. Conditions: {state_after['conditions_met']}/3"
    )

    return GateResult(
        decision="ALLOW",
        tool_name=tool_name,
        condition=condition,
        reason=f"Tool '{tool_name}' allowed. Condition '{condition}' recorded.",
        session_id=session_id,
        conditions_before=conditions_before,
        conditions_after=state_after["active_conditions"],
    )
