"""Bounded Log Analytics audit ingestion for gate decisions."""

import asyncio
import logging
import os
import re
import threading
from datetime import datetime, timezone
from urllib.parse import urlparse

from azure.identity import DefaultAzureCredential
from azure.monitor.ingestion import LogsIngestionClient

_DCR_RULE_ID = re.compile(r"^dcr-[A-Za-z0-9-]{8,128}$")
_client = None
_client_lock = threading.Lock()


def _audit_config() -> tuple[str, str] | None:
    endpoint = os.environ.get("DCR_ENDPOINT", "").strip()
    rule_id = os.environ.get("DCR_RULE_ID", "").strip()
    parsed = urlparse(endpoint)
    if (
        not endpoint
        or not rule_id
        or parsed.scheme != "https"
        or not parsed.hostname
        or not parsed.hostname.endswith(".ingest.monitor.azure.com")
        or not _DCR_RULE_ID.fullmatch(rule_id)
    ):
        return None
    return endpoint, rule_id


def audit_is_configured() -> bool:
    return _audit_config() is not None


def _get_client(endpoint: str):
    global _client
    if _client is not None:
        return _client
    with _client_lock:
        if _client is None:
            credential = DefaultAzureCredential(
                exclude_interactive_browser_credential=True
            )
            _client = LogsIngestionClient(endpoint=endpoint, credential=credential)
    return _client


async def log_gate_decision(
    session_id: str,
    tool_name: str,
    condition: str | None,
    decision: str,
    reason: str,
    conditions_before: list[str],
    conditions_after: list[str],
) -> bool:
    """Upload one decision, returning False when required telemetry is unavailable."""
    config = _audit_config()
    if config is None:
        logging.error("DCR audit configuration is missing or invalid")
        return False
    endpoint, rule_id = config
    log_entry = {
        "TimeGenerated": datetime.now(timezone.utc).isoformat(),
        "SessionId": session_id,
        "ToolName": tool_name,
        "Condition": condition or "",
        "Decision": decision,
        "Reason": reason[:512],
        "ConditionsBefore": ",".join(conditions_before),
        "ConditionsAfter": ",".join(conditions_after),
        "ConditionsMetCount": len(conditions_after),
    }
    try:
        client = _get_client(endpoint)
        await asyncio.to_thread(
            client.upload,
            rule_id=rule_id,
            stream_name="Custom-TrifectaAudit_CL",
            logs=[log_entry],
        )
        return True
    except Exception:
        logging.exception("Failed to send required gate audit log")
        return False
