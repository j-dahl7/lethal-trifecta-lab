"""
Trifecta Gate Audit Logging

Sends all gate decisions to Log Analytics custom table via Data Collection Rule.
"""

import logging
import os
from datetime import datetime, timezone
from azure.identity import DefaultAzureCredential
from azure.monitor.ingestion import LogsIngestionClient


async def log_gate_decision(
    session_id: str,
    tool_name: str,
    condition: str | None,
    decision: str,
    reason: str,
    conditions_before: list[str],
    conditions_after: list[str],
):
    """
    Log a gate decision to Log Analytics.

    Args:
        session_id: Session identifier
        tool_name: Name of the tool being evaluated
        condition: Trifecta condition for the tool (or None)
        decision: "ALLOW" or "BLOCK"
        reason: Human-readable explanation
        conditions_before: Active conditions before this evaluation
        conditions_after: Active conditions after this evaluation
    """
    dcr_endpoint = os.environ.get("DCR_ENDPOINT")
    dcr_rule_id = os.environ.get("DCR_RULE_ID")

    if not dcr_endpoint or not dcr_rule_id:
        logging.warning("DCR not configured, skipping audit log")
        return

    try:
        credential = DefaultAzureCredential()
        client = LogsIngestionClient(
            endpoint=dcr_endpoint,
            credential=credential,
        )

        log_entry = {
            "TimeGenerated": datetime.now(timezone.utc).isoformat(),
            "SessionId": session_id,
            "ToolName": tool_name,
            "Condition": condition or "",
            "Decision": decision,
            "Reason": reason,
            "ConditionsBefore": ",".join(conditions_before),
            "ConditionsAfter": ",".join(conditions_after),
            "ConditionsMetCount": len(conditions_after),
        }

        client.upload(
            rule_id=dcr_rule_id,
            stream_name="Custom-TrifectaAudit_CL",
            logs=[log_entry],
        )

        logging.info(f"Audit log sent: {decision} for {tool_name} in session {session_id}")

    except Exception as e:
        # Don't fail the gate decision if logging fails
        logging.error(f"Failed to send audit log: {e}")
