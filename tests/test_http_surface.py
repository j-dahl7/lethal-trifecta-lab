import asyncio
import json
import logging
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch

import azure.functions as func


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "function"))

import function_app  # noqa: E402
import session_tracker  # noqa: E402


class FunctionMetadataTests(unittest.TestCase):
    def test_generated_trigger_metadata_has_one_anonymous_route(self):
        routes = {}
        for function in function_app.app.get_functions():
            metadata = json.loads(function.get_function_json())
            trigger = next(
                binding
                for binding in metadata["bindings"]
                if binding["type"] == "httpTrigger"
            )
            routes[trigger["route"]] = trigger["authLevel"]
        self.assertEqual(
            routes,
            {
                "api/evaluate": "FUNCTION",
                "api/session/{session_id}": "FUNCTION",
                "api/tools": "FUNCTION",
                "api/health": "ANONYMOUS",
            },
        )


class HttpBehaviorTests(unittest.TestCase):
    def setUp(self):
        logging.disable(logging.CRITICAL)
        self.original_environment = os.environ.copy()
        os.environ["SESSION_STORE"] = "memory"
        os.environ["ALLOW_IN_MEMORY_SESSION_STORE"] = "true"
        os.environ["AUDIT_REQUIRED"] = "false"
        session_tracker._reset_state_for_tests()

    def tearDown(self):
        logging.disable(logging.NOTSET)
        os.environ.clear()
        os.environ.update(self.original_environment)
        session_tracker._reset_state_for_tests()

    def request(self, body: bytes):
        return func.HttpRequest(
            method="POST",
            url="https://example.invalid/api/evaluate",
            headers={"content-type": "application/json"},
            params={},
            route_params={},
            body=body,
        )

    def evaluate(self, body: bytes):
        return asyncio.run(function_app.evaluate_tool_call(self.request(body)))

    def test_invalid_and_oversized_bodies_are_rejected_before_policy(self):
        invalid = self.evaluate(b"not-json")
        oversized = self.evaluate(b"{" + (b"x" * 4096) + b"}")
        self.assertEqual(invalid.status_code, 400)
        self.assertEqual(oversized.status_code, 413)

    def test_registered_sequence_returns_two_allows_then_block(self):
        decisions = []
        for tool_name in ("read_db", "process_document", "send_http"):
            response = self.evaluate(
                json.dumps(
                    {"session_id": "http-sequence", "tool_name": tool_name}
                ).encode()
            )
            decisions.append((response.status_code, json.loads(response.get_body())))
        self.assertEqual([item[0] for item in decisions], [200, 200, 403])
        self.assertEqual(
            [item[1]["decision"] for item in decisions],
            ["ALLOW", "ALLOW", "BLOCK"],
        )

    def test_store_failure_returns_blocking_503(self):
        os.environ["SESSION_STORE"] = "cosmos"
        os.environ.pop("COSMOS_ENDPOINT", None)
        session_tracker._reset_state_for_tests()
        response = self.evaluate(
            b'{"session_id":"unavailable","tool_name":"read_db"}'
        )
        body = json.loads(response.get_body())
        self.assertEqual(response.status_code, 503)
        self.assertEqual(body["decision"], "BLOCK")

    def test_required_audit_failure_converts_allow_to_blocking_503(self):
        os.environ["AUDIT_REQUIRED"] = "true"
        with patch.object(
            function_app, "log_gate_decision", new=AsyncMock(return_value=False)
        ):
            response = self.evaluate(
                b'{"session_id":"audit-required","tool_name":"read_db"}'
            )
        body = json.loads(response.get_body())
        self.assertEqual(response.status_code, 503)
        self.assertEqual(body["decision"], "BLOCK")


if __name__ == "__main__":
    unittest.main()
