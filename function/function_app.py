"""
Lethal Trifecta Gate - Azure Function App

Enforces the Rule of Two: blocks AI agent tool calls that would complete
all 3 conditions for data exfiltration (private data + untrusted content +
exfiltration vector).

Endpoints:
  POST /api/evaluate     - Evaluate a tool call (core gate)
  GET  /api/session/{id} - Get session state
  GET  /api/tools        - List tool registry
  GET  /api/health       - Health check
"""

import azure.functions as func
import logging
import json
from datetime import datetime, timezone

from policy_engine import evaluate
from tool_registry import get_all_tools, get_conditions_metadata
from session_tracker import get_session_state, get_all_sessions
from audit import log_gate_decision

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)


# =============================================================================
# POST /api/evaluate - Core gate endpoint
# =============================================================================

@app.route(route="api/evaluate", methods=["POST"])
async def evaluate_tool_call(req: func.HttpRequest) -> func.HttpResponse:
    """
    Evaluate a tool call against the trifecta policy.

    Request body:
    {
        "session_id": "unique-session-identifier",
        "tool_name": "read_db"
    }

    Returns 200 with ALLOW decision, or 403 with BLOCK decision.
    """
    logging.info("Evaluate request received")

    try:
        body = req.get_json()
    except ValueError:
        return func.HttpResponse(
            json.dumps({"error": "Invalid JSON body"}),
            status_code=400,
            mimetype="application/json",
        )

    # Validate required fields
    missing = [f for f in ["session_id", "tool_name"] if f not in body]
    if missing:
        return func.HttpResponse(
            json.dumps({"error": f"Missing required fields: {missing}"}),
            status_code=400,
            mimetype="application/json",
        )

    session_id = body["session_id"]
    tool_name = body["tool_name"]

    # Evaluate against policy
    result = evaluate(session_id, tool_name)

    # Audit log (fire and forget)
    await log_gate_decision(
        session_id=result.session_id,
        tool_name=result.tool_name,
        condition=result.condition,
        decision=result.decision,
        reason=result.reason,
        conditions_before=result.conditions_before,
        conditions_after=result.conditions_after,
    )

    status_code = 200 if result.decision == "ALLOW" else 403

    return func.HttpResponse(
        json.dumps(result.to_dict()),
        status_code=status_code,
        mimetype="application/json",
    )


# =============================================================================
# GET /api/session/{id} - Session state endpoint
# =============================================================================

@app.route(route="api/session/{session_id}", methods=["GET"])
def get_session(req: func.HttpRequest) -> func.HttpResponse:
    """Return the current state of a session."""
    session_id = req.route_params.get("session_id")

    if not session_id:
        return func.HttpResponse(
            json.dumps({"error": "session_id is required"}),
            status_code=400,
            mimetype="application/json",
        )

    state = get_session_state(session_id)

    return func.HttpResponse(
        json.dumps(state),
        status_code=200,
        mimetype="application/json",
    )


# =============================================================================
# GET /api/tools - Tool registry endpoint
# =============================================================================

@app.route(route="api/tools", methods=["GET"])
def list_tools(req: func.HttpRequest) -> func.HttpResponse:
    """Return the full tool registry with condition mappings."""
    return func.HttpResponse(
        json.dumps({
            "tools": get_all_tools(),
            "conditions": get_conditions_metadata(),
        }),
        status_code=200,
        mimetype="application/json",
    )


# =============================================================================
# GET /api/health - Health check endpoint
# =============================================================================

@app.route(route="api/health", methods=["GET"])
def health_check(req: func.HttpRequest) -> func.HttpResponse:
    """Health check endpoint."""
    return func.HttpResponse(
        json.dumps({
            "status": "healthy",
            "service": "trifecta-gate",
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "version": "1.0.0",
        }),
        status_code=200,
        mimetype="application/json",
    )
