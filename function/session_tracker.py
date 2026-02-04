"""
Session Tracker - Per-session state tracking for the Lethal Trifecta gate.

Tracks which trifecta conditions have been satisfied in each session.
In-memory storage resets on cold start (acknowledged lab limitation).
"""

import logging
from datetime import datetime, timezone

ALL_CONDITIONS = frozenset(["private_data", "untrusted_content", "exfiltration_vector"])

# In-memory session store: session_id -> SessionState
_sessions: dict[str, dict] = {}


def get_or_create_session(session_id: str) -> dict:
    """Get existing session state or create a new one."""
    if session_id not in _sessions:
        _sessions[session_id] = {
            "session_id": session_id,
            "active_conditions": set(),
            "tool_history": [],
            "created_at": datetime.now(timezone.utc).isoformat(),
            "call_count": 0,
        }
        logging.info(f"New session created: {session_id}")
    return _sessions[session_id]


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


def get_all_sessions() -> list[dict]:
    """Return state for all active sessions."""
    return [get_session_state(sid) for sid in _sessions]
