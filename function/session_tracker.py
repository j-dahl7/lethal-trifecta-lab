"""Fail-closed, concurrency-safe session state for the Trifecta Gate.

Production uses Cosmos DB with managed identity and optimistic concurrency.
An in-memory store is available only when explicitly enabled for local tests.
There is deliberately no automatic fallback from Cosmos DB to process memory.
"""

from __future__ import annotations

import logging
import os
import re
import threading
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from urllib.parse import urlparse

ALL_CONDITIONS = frozenset(
    {"private_data", "untrusted_content", "exfiltration_vector"}
)
MAX_TOOL_HISTORY = 100
MAX_SESSION_CALLS = 10_000
MAX_IN_MEMORY_SESSIONS = 1_000
MEMORY_SESSION_TTL = timedelta(hours=1)
MAX_CONCURRENCY_RETRIES = 8
_RESOURCE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")


class SessionStoreUnavailable(RuntimeError):
    """The authoritative session store cannot safely serve the request."""


class SessionNotFound(LookupError):
    """The requested session does not exist."""


class SessionLimitExceeded(RuntimeError):
    """A bounded session or local-store limit was reached."""


@dataclass(frozen=True)
class SessionTransition:
    allowed: bool
    conditions_before: tuple[str, ...]
    conditions_after: tuple[str, ...]
    call_count: int


_cosmos_container = None
_cosmos_initialized = False
_cosmos_init_lock = threading.Lock()
_memory_lock = threading.RLock()
_sessions: dict[str, dict] = {}


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _iso_now() -> str:
    return _utc_now().isoformat()


def _store_mode() -> str:
    mode = os.environ.get("SESSION_STORE", "cosmos").strip().lower()
    if mode not in {"cosmos", "memory"}:
        raise SessionStoreUnavailable("SESSION_STORE must be 'cosmos' or 'memory'")
    if mode == "memory" and os.environ.get(
        "ALLOW_IN_MEMORY_SESSION_STORE", ""
    ).lower() != "true":
        raise SessionStoreUnavailable(
            "In-memory state is disabled; set ALLOW_IN_MEMORY_SESSION_STORE=true "
            "only for isolated local tests"
        )
    return mode


def get_store_status() -> dict:
    """Return non-secret configuration status for the anonymous health route."""
    try:
        mode = _store_mode()
    except SessionStoreUnavailable as exc:
        return {"configured": False, "mode": "invalid", "error": str(exc)}

    if mode == "memory":
        return {"configured": True, "mode": "memory"}
    return {
        "configured": _valid_cosmos_endpoint(os.environ.get("COSMOS_ENDPOINT", "")),
        "mode": "cosmos",
    }


def _valid_cosmos_endpoint(endpoint: str) -> bool:
    parsed = urlparse(endpoint)
    return bool(
        parsed.scheme == "https"
        and parsed.hostname
        and parsed.hostname.endswith(".documents.azure.com")
        and not parsed.username
        and not parsed.password
        and parsed.path in {"", "/"}
        and not parsed.query
        and not parsed.fragment
    )


def _get_cosmos_container():
    """Initialize the Cosmos container client or fail closed."""
    global _cosmos_container, _cosmos_initialized

    if _cosmos_initialized:
        if _cosmos_container is None:
            raise SessionStoreUnavailable("Cosmos DB session store is unavailable")
        return _cosmos_container

    with _cosmos_init_lock:
        if _cosmos_initialized:
            if _cosmos_container is None:
                raise SessionStoreUnavailable("Cosmos DB session store is unavailable")
            return _cosmos_container

        endpoint = os.environ.get("COSMOS_ENDPOINT", "").strip()
        database_name = os.environ.get("COSMOS_DATABASE_NAME", "trifecta-db").strip()
        container_name = os.environ.get("COSMOS_CONTAINER_NAME", "sessions").strip()
        if not _valid_cosmos_endpoint(endpoint):
            _cosmos_initialized = True
            raise SessionStoreUnavailable("COSMOS_ENDPOINT is missing or invalid")
        if not _RESOURCE_NAME.fullmatch(database_name) or not _RESOURCE_NAME.fullmatch(
            container_name
        ):
            _cosmos_initialized = True
            raise SessionStoreUnavailable("Cosmos database or container name is invalid")

        try:
            from azure.cosmos import CosmosClient
            from azure.identity import DefaultAzureCredential

            credential = DefaultAzureCredential(
                exclude_interactive_browser_credential=True
            )
            client = CosmosClient(endpoint, credential=credential)
            database = client.get_database_client(database_name)
            _cosmos_container = database.get_container_client(container_name)
            _cosmos_initialized = True
            logging.info("Cosmos DB session store client initialized")
            return _cosmos_container
        except Exception as exc:
            _cosmos_container = None
            _cosmos_initialized = True
            logging.exception("Cosmos DB session store initialization failed")
            raise SessionStoreUnavailable(
                "Cosmos DB session store initialization failed"
            ) from exc


def _status_code(exc: Exception) -> int | None:
    return getattr(exc, "status_code", None)


def _new_session(session_id: str) -> dict:
    now = _iso_now()
    return {
        "id": session_id,
        "session_id": session_id,
        "active_conditions": set(),
        "tool_history": [],
        "created_at": now,
        "updated_at": now,
        "call_count": 0,
        "schema_version": 1,
    }


def _deserialize_session(item: dict, expected_session_id: str) -> dict:
    try:
        if item.get("id") != expected_session_id or item.get(
            "session_id"
        ) != expected_session_id:
            raise ValueError("session identity mismatch")
        active = set(item.get("active_conditions", []))
        if not active.issubset(ALL_CONDITIONS):
            raise ValueError("unknown active condition")
        history = item.get("tool_history", [])
        call_count = item.get("call_count", 0)
        if not isinstance(history, list) or len(history) > MAX_TOOL_HISTORY:
            raise ValueError("invalid tool history")
        for entry in history:
            if (
                not isinstance(entry, dict)
                or not isinstance(entry.get("tool"), str)
                or len(entry["tool"]) > 64
                or entry.get("condition") not in ALL_CONDITIONS
                or not isinstance(entry.get("timestamp"), str)
                or len(entry["timestamp"]) > 64
            ):
                raise ValueError("invalid tool history entry")
        if not isinstance(call_count, int) or call_count < 0:
            raise ValueError("invalid call count")
        for field in ("created_at", "updated_at"):
            if not isinstance(item.get(field), str) or len(item[field]) > 64:
                raise ValueError(f"invalid {field}")
        return {
            **item,
            "active_conditions": active,
            "tool_history": list(history),
            "call_count": call_count,
        }
    except (AttributeError, TypeError, ValueError) as exc:
        raise SessionStoreUnavailable("Session document failed validation") from exc


def _serialize_session(session: dict) -> dict:
    return {
        "id": session["session_id"],
        "session_id": session["session_id"],
        "active_conditions": sorted(session["active_conditions"]),
        "tool_history": list(session["tool_history"]),
        "created_at": session["created_at"],
        "updated_at": session["updated_at"],
        "call_count": session["call_count"],
        "schema_version": 1,
    }


def _transition(session: dict, tool_name: str, condition: str) -> SessionTransition:
    before = tuple(sorted(session["active_conditions"]))
    hypothetical = session["active_conditions"] | {condition}
    if hypothetical == ALL_CONDITIONS:
        return SessionTransition(False, before, before, session["call_count"])
    if session["call_count"] >= MAX_SESSION_CALLS:
        raise SessionLimitExceeded("Session call limit reached")

    session["active_conditions"] = hypothetical
    session["tool_history"] = (
        session["tool_history"]
        + [
            {
                "tool": tool_name,
                "condition": condition,
                "timestamp": _iso_now(),
            }
        ]
    )[-MAX_TOOL_HISTORY:]
    session["call_count"] += 1
    session["updated_at"] = _iso_now()
    after = tuple(sorted(session["active_conditions"]))
    return SessionTransition(True, before, after, session["call_count"])


def _prune_memory_sessions() -> None:
    cutoff = _utc_now() - MEMORY_SESSION_TTL
    expired = []
    for session_id, session in _sessions.items():
        try:
            updated = datetime.fromisoformat(session["updated_at"])
            if updated.tzinfo is None or updated < cutoff:
                expired.append(session_id)
        except (KeyError, TypeError, ValueError):
            expired.append(session_id)
    for session_id in expired:
        _sessions.pop(session_id, None)


def _evaluate_memory(
    session_id: str, tool_name: str, condition: str
) -> SessionTransition:
    with _memory_lock:
        _prune_memory_sessions()
        session = _sessions.get(session_id)
        if session is None:
            if len(_sessions) >= MAX_IN_MEMORY_SESSIONS:
                raise SessionLimitExceeded("In-memory session limit reached")
            session = _new_session(session_id)
        transition = _transition(session, tool_name, condition)
        if transition.allowed:
            _sessions[session_id] = session
        return transition


def _evaluate_cosmos(
    session_id: str, tool_name: str, condition: str
) -> SessionTransition:
    container = _get_cosmos_container()
    for _ in range(MAX_CONCURRENCY_RETRIES):
        existing = True
        try:
            item = container.read_item(item=session_id, partition_key=session_id)
            session = _deserialize_session(item, session_id)
        except Exception as exc:
            if _status_code(exc) == 404:
                existing = False
                session = _new_session(session_id)
            else:
                logging.exception("Cosmos session read failed")
                raise SessionStoreUnavailable("Cosmos DB session read failed") from exc

        transition = _transition(session, tool_name, condition)
        if not transition.allowed:
            return transition

        document = _serialize_session(session)
        try:
            if existing:
                from azure.core import MatchConditions

                container.replace_item(
                    item=session_id,
                    body=document,
                    partition_key=session_id,
                    etag=item.get("_etag"),
                    match_condition=MatchConditions.IfNotModified,
                )
            else:
                container.create_item(body=document)
            return transition
        except Exception as exc:
            if _status_code(exc) in {409, 412}:
                continue
            logging.exception("Cosmos session write failed")
            raise SessionStoreUnavailable("Cosmos DB session write failed") from exc

    raise SessionStoreUnavailable("Session update contention limit reached")


def evaluate_and_record(
    session_id: str, tool_name: str, condition: str
) -> SessionTransition:
    """Atomically decide and, when allowed, record a condition transition."""
    if condition not in ALL_CONDITIONS:
        raise ValueError("Unknown trifecta condition")
    if _store_mode() == "memory":
        return _evaluate_memory(session_id, tool_name, condition)
    return _evaluate_cosmos(session_id, tool_name, condition)


def _get_memory_session(session_id: str) -> dict:
    with _memory_lock:
        _prune_memory_sessions()
        session = _sessions.get(session_id)
        if session is None:
            raise SessionNotFound(session_id)
        return _deserialize_session(_serialize_session(session), session_id)


def _get_cosmos_session(session_id: str) -> dict:
    try:
        item = _get_cosmos_container().read_item(
            item=session_id, partition_key=session_id
        )
        return _deserialize_session(item, session_id)
    except SessionStoreUnavailable:
        raise
    except Exception as exc:
        if _status_code(exc) == 404:
            raise SessionNotFound(session_id) from exc
        logging.exception("Cosmos session read failed")
        raise SessionStoreUnavailable("Cosmos DB session read failed") from exc


def get_session_state(session_id: str) -> dict:
    """Return a bounded, serializable view of an existing session."""
    session = (
        _get_memory_session(session_id)
        if _store_mode() == "memory"
        else _get_cosmos_session(session_id)
    )
    active = session["active_conditions"]
    return {
        "session_id": session_id,
        "active_conditions": sorted(active),
        "missing_conditions": sorted(ALL_CONDITIONS - active),
        "conditions_met": len(active),
        "conditions_total": len(ALL_CONDITIONS),
        "trifecta_complete": active == ALL_CONDITIONS,
        "call_count": session["call_count"],
        "tool_history": list(session["tool_history"]),
        "created_at": session["created_at"],
        "updated_at": session["updated_at"],
    }


def _reset_state_for_tests() -> None:
    """Reset module state for deterministic unit tests."""
    global _cosmos_container, _cosmos_initialized
    with _memory_lock:
        _sessions.clear()
    with _cosmos_init_lock:
        _cosmos_container = None
        _cosmos_initialized = False
