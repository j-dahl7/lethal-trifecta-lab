"""Authenticated HTTP surface for the Lethal Trifecta Gate."""

import json
import logging
import os
from datetime import datetime, timezone

import azure.functions as func

from audit import audit_is_configured, log_gate_decision
from policy_engine import evaluate
from session_tracker import (
    SessionLimitExceeded,
    SessionNotFound,
    SessionStoreUnavailable,
    get_session_state,
    get_store_status,
)
from tool_registry import get_all_tools, get_conditions_metadata
from validation import (
    MAX_REQUEST_BYTES,
    RequestValidationError,
    validate_evaluation_payload,
    validate_session_id,
)

# Gate and state endpoints require a host/function key. Only health is anonymous.
app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)


def _response(payload: dict, status_code: int, extra_headers: dict | None = None):
    headers = {
        "Cache-Control": "no-store",
        "X-Content-Type-Options": "nosniff",
    }
    if extra_headers:
        headers.update(extra_headers)
    return func.HttpResponse(
        json.dumps(payload),
        status_code=status_code,
        mimetype="application/json",
        headers=headers,
    )


def _gate_unavailable_response(message: str):
    return _response(
        {"decision": "BLOCK", "error": "gate_unavailable", "message": message},
        503,
        {"Retry-After": "5"},
    )


@app.route(route="api/evaluate", methods=["POST"])
async def evaluate_tool_call(req: func.HttpRequest) -> func.HttpResponse:
    """Evaluate one bounded, registered tool call against the gate."""
    raw_body = req.get_body()
    if len(raw_body) > MAX_REQUEST_BYTES:
        return _response({"error": "Request body is too large"}, 413)
    try:
        body = json.loads(raw_body.decode("utf-8"))
        session_id, tool_name = validate_evaluation_payload(body)
    except (UnicodeDecodeError, json.JSONDecodeError):
        return _response({"error": "Invalid JSON body"}, 400)
    except RequestValidationError as exc:
        return _response({"error": str(exc)}, 400)

    try:
        result = evaluate(session_id, tool_name)
    except SessionLimitExceeded:
        return _response(
            {
                "decision": "BLOCK",
                "error": "session_limit_reached",
                "message": "Session limit reached; start a new bounded session.",
            },
            429,
        )
    except SessionStoreUnavailable:
        logging.exception("Authoritative session store unavailable")
        return _gate_unavailable_response(
            "Authoritative session state is unavailable; the tool call was not allowed."
        )

    audit_ok = await log_gate_decision(
        session_id=result.session_id,
        tool_name=result.tool_name,
        condition=result.condition,
        decision=result.decision,
        reason=result.reason,
        conditions_before=result.conditions_before,
        conditions_after=result.conditions_after,
    )
    audit_required = os.environ.get("AUDIT_REQUIRED", "true").lower() == "true"
    if not audit_ok and audit_required and result.decision == "ALLOW":
        return _gate_unavailable_response(
            "Required audit logging is unavailable; the tool call was not allowed."
        )

    return _response(result.to_dict(), 200 if result.decision == "ALLOW" else 403)


@app.route(route="api/session/{session_id}", methods=["GET"])
def get_session(req: func.HttpRequest) -> func.HttpResponse:
    """Return bounded state for an existing session."""
    try:
        session_id = validate_session_id(req.route_params.get("session_id"))
        state = get_session_state(session_id)
        return _response(state, 200)
    except RequestValidationError as exc:
        return _response({"error": str(exc)}, 400)
    except SessionNotFound:
        return _response({"error": "Session not found"}, 404)
    except SessionStoreUnavailable:
        logging.exception("Authoritative session store unavailable")
        return _gate_unavailable_response("Authoritative session state is unavailable.")


@app.route(route="api/tools", methods=["GET"])
def list_tools(req: func.HttpRequest) -> func.HttpResponse:
    """Return the validated tool registry."""
    return _response(
        {"tools": get_all_tools(), "conditions": get_conditions_metadata()}, 200
    )


@app.route(
    route="api/health", methods=["GET"], auth_level=func.AuthLevel.ANONYMOUS
)
def health_check(req: func.HttpRequest) -> func.HttpResponse:
    """Return configuration readiness without disclosing endpoints or secrets."""
    store = get_store_status()
    audit_required = os.environ.get("AUDIT_REQUIRED", "true").lower() == "true"
    audit_ready = audit_is_configured()
    ready = store["configured"] and (audit_ready or not audit_required)
    return _response(
        {
            "status": "healthy" if ready else "not_ready",
            "service": "trifecta-gate",
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "version": "2.0.0",
            "session_store": store["mode"],
            "audit_required": audit_required,
        },
        200 if ready else 503,
    )
