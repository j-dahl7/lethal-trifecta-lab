"""
Session Tracker - Per-session state tracking for the Lethal Trifecta gate.

Tracks which trifecta conditions have been satisfied in each session.
Uses Cosmos DB for persistence across Function App instances.
Falls back to in-memory storage if Cosmos DB is not configured or unavailable.
"""

import logging
import os
from datetime import datetime, timezone

ALL_CONDITIONS = frozenset(["private_data", "untrusted_content", "exfiltration_vector"])

# Cosmos DB client (lazy init)
_cosmos_container = None
_cosmos_initialized = False

# In-memory fallback
_sessions: dict[str, dict] = {}


def _get_cosmos_container():
    """Get or create the Cosmos DB sessions container client."""
    global _cosmos_container, _cosmos_initialized

    if _cosmos_initialized:
        return _cosmos_container

    _cosmos_initialized = True
    endpoint = os.environ.get("COSMOS_ENDPOINT")
    database_name = os.environ.get("COSMOS_DATABASE_NAME", "trifecta-db")
    key = os.environ.get("COSMOS_KEY")

    if not endpoint:
        logging.warning("COSMOS_ENDPOINT not set, using in-memory session state")
        return None

    try:
        from azure.cosmos import CosmosClient

        if key:
            client = CosmosClient(endpoint, credential=key)
        else:
            from azure.identity import DefaultAzureCredential
            client = CosmosClient(endpoint, credential=DefaultAzureCredential())

        database = client.get_database_client(database_name)
        _cosmos_container = database.get_container_client("sessions")
        logging.info("Cosmos DB session store initialized")
        return _cosmos_container
    except Exception as e:
        logging.error(f"Failed to initialize Cosmos DB session store: {e}")
        return None


def _load_session(session_id: str) -> dict | None:
    """Load session from Cosmos DB, or from in-memory fallback."""
    container = _get_cosmos_container()

    if container:
        try:
            from azure.cosmos import exceptions as cosmos_exceptions
            item = container.read_item(item=session_id, partition_key=session_id)
            item["active_conditions"] = set(item.get("active_conditions", []))
            return item
        except Exception as e:
            # Check if it's a not-found error
            if hasattr(e, 'status_code') and e.status_code == 404:
                return None
            logging.error(f"Failed to load session {session_id}: {e}")
            return None

    # In-memory fallback
    return _sessions.get(session_id)


def _save_session(session: dict):
    """Save session to Cosmos DB, or to in-memory fallback."""
    container = _get_cosmos_container()

    if container:
        try:
            doc = {
                "id": session["session_id"],
                "session_id": session["session_id"],
                "active_conditions": sorted(session["active_conditions"]),
                "tool_history": session["tool_history"],
                "created_at": session["created_at"],
                "call_count": session["call_count"],
            }
            container.upsert_item(doc)
        except Exception as e:
            logging.error(f"Failed to save session {session['session_id']}: {e}")
        return

    # In-memory fallback
    _sessions[session["session_id"]] = session


def get_or_create_session(session_id: str) -> dict:
    """Get existing session state or create a new one."""
    session = _load_session(session_id)
    if session:
        return session

    session = {
        "session_id": session_id,
        "active_conditions": set(),
        "tool_history": [],
        "created_at": datetime.now(timezone.utc).isoformat(),
        "call_count": 0,
    }
    logging.info(f"New session created: {session_id}")
    return session


def record_tool_call(session_id: str, tool_name: str, condition: str) -> dict:
    """Record a tool call and its condition in the session."""
    session = get_or_create_session(session_id)
    session["active_conditions"].add(condition)
    session["tool_history"].append({
        "tool": tool_name,
        "condition": condition,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    })
    session["call_count"] += 1
    _save_session(session)
    return session


def would_complete_trifecta(session_id: str, new_condition: str) -> bool:
    """
    Check if adding this condition would complete all 3 trifecta conditions.

    Returns True if the session already has the other 2 conditions
    and this call would add the 3rd (completing the trifecta).
    """
    session = get_or_create_session(session_id)
    hypothetical = session["active_conditions"] | {new_condition}
    return hypothetical == ALL_CONDITIONS


def get_session_state(session_id: str) -> dict:
    """Return a serializable view of the session state."""
    session = get_or_create_session(session_id)
    active = session["active_conditions"]
    missing = ALL_CONDITIONS - active
    return {
        "session_id": session_id,
        "active_conditions": sorted(active),
        "missing_conditions": sorted(missing),
        "conditions_met": len(active),
        "conditions_total": len(ALL_CONDITIONS),
        "trifecta_complete": active == ALL_CONDITIONS,
        "call_count": session["call_count"],
        "tool_history": session["tool_history"],
        "created_at": session["created_at"],
    }
