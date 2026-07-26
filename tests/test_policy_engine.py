import os
import logging
import sys
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Barrier


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "function"))

import session_tracker  # noqa: E402
from policy_engine import evaluate  # noqa: E402
from session_tracker import (  # noqa: E402
    SessionLimitExceeded,
    SessionNotFound,
    SessionStoreUnavailable,
    get_session_state,
)
from validation import (  # noqa: E402
    RequestValidationError,
    validate_evaluation_payload,
    validate_session_id,
)


class PolicyEngineTests(unittest.TestCase):
    def setUp(self):
        logging.disable(logging.CRITICAL)
        self.original_environment = os.environ.copy()
        os.environ["SESSION_STORE"] = "memory"
        os.environ["ALLOW_IN_MEMORY_SESSION_STORE"] = "true"
        session_tracker._reset_state_for_tests()

    def tearDown(self):
        logging.disable(logging.NOTSET)
        os.environ.clear()
        os.environ.update(self.original_environment)
        session_tracker._reset_state_for_tests()

    def test_rule_of_two_records_only_two_conditions(self):
        session_id = "rule-of-two"
        self.assertEqual(evaluate(session_id, "read_db").decision, "ALLOW")
        self.assertEqual(
            evaluate(session_id, "process_document").decision, "ALLOW"
        )
        blocked = evaluate(session_id, "send_http")
        self.assertEqual(blocked.decision, "BLOCK")
        state = get_session_state(session_id)
        self.assertEqual(state["conditions_met"], 2)
        self.assertFalse(state["trifecta_complete"])
        self.assertEqual(state["call_count"], 2)

    def test_unregistered_tool_fails_closed_without_creating_session(self):
        result = evaluate("unknown-tool-session", "unregistered_tool")
        self.assertEqual(result.decision, "BLOCK")
        with self.assertRaises(SessionNotFound):
            get_session_state("unknown-tool-session")

    def test_concurrent_three_condition_attempt_allows_exactly_two(self):
        barrier = Barrier(3)

        def call(tool_name):
            barrier.wait(timeout=5)
            return evaluate("concurrent-session", tool_name).decision

        with ThreadPoolExecutor(max_workers=3) as executor:
            decisions = list(
                executor.map(call, ["read_db", "process_document", "send_http"])
            )
        self.assertEqual(decisions.count("ALLOW"), 2)
        self.assertEqual(decisions.count("BLOCK"), 1)
        self.assertEqual(get_session_state("concurrent-session")["conditions_met"], 2)

    def test_history_is_bounded_while_call_count_remains_total(self):
        for _ in range(150):
            self.assertEqual(evaluate("bounded-history", "read_db").decision, "ALLOW")
        state = get_session_state("bounded-history")
        self.assertEqual(state["call_count"], 150)
        self.assertEqual(len(state["tool_history"]), 100)

    def test_session_call_limit_fails_closed(self):
        original_limit = session_tracker.MAX_SESSION_CALLS
        session_tracker.MAX_SESSION_CALLS = 2
        try:
            evaluate("call-limit", "read_db")
            evaluate("call-limit", "read_db")
            with self.assertRaises(SessionLimitExceeded):
                evaluate("call-limit", "read_db")
        finally:
            session_tracker.MAX_SESSION_CALLS = original_limit

    def test_cosmos_misconfiguration_does_not_fall_back_to_memory(self):
        os.environ["SESSION_STORE"] = "cosmos"
        os.environ.pop("COSMOS_ENDPOINT", None)
        session_tracker._reset_state_for_tests()
        with self.assertRaises(SessionStoreUnavailable):
            evaluate("must-fail-closed", "read_db")

    def test_tampered_cosmos_endpoint_is_rejected_before_credentials(self):
        os.environ["SESSION_STORE"] = "cosmos"
        os.environ["COSMOS_ENDPOINT"] = "https://attacker.example.invalid/"
        session_tracker._reset_state_for_tests()
        with self.assertRaises(SessionStoreUnavailable):
            evaluate("invalid-endpoint", "read_db")

    def test_cosmos_etag_conflict_rechecks_policy_before_write(self):
        class PreconditionFailed(Exception):
            status_code = 412

        class ConflictContainer:
            def __init__(self):
                self.replace_calls = 0
                self.active = ["private_data"]
                self.etag = "etag-1"

            def read_item(self, item, partition_key):
                return {
                    "id": item,
                    "session_id": item,
                    "active_conditions": list(self.active),
                    "tool_history": [],
                    "created_at": "2026-07-25T00:00:00+00:00",
                    "updated_at": "2026-07-25T00:00:00+00:00",
                    "call_count": len(self.active),
                    "schema_version": 1,
                    "_etag": self.etag,
                }

            def replace_item(self, **kwargs):
                self.replace_calls += 1
                self.active = ["private_data", "untrusted_content"]
                self.etag = "etag-2"
                raise PreconditionFailed()

        container = ConflictContainer()
        os.environ["SESSION_STORE"] = "cosmos"
        os.environ["COSMOS_ENDPOINT"] = "https://lab.documents.azure.com/"
        session_tracker._cosmos_container = container
        session_tracker._cosmos_initialized = True
        result = evaluate("cosmos-race", "send_http")
        self.assertEqual(result.decision, "BLOCK")
        self.assertEqual(container.replace_calls, 1)
        self.assertEqual(
            result.conditions_before, ["private_data", "untrusted_content"]
        )

    def test_memory_store_requires_explicit_test_opt_in(self):
        os.environ.pop("ALLOW_IN_MEMORY_SESSION_STORE", None)
        session_tracker._reset_state_for_tests()
        with self.assertRaises(SessionStoreUnavailable):
            evaluate("memory-not-authorized", "read_db")


class ValidationTests(unittest.TestCase):
    def test_accepts_exact_bounded_payload(self):
        self.assertEqual(
            validate_evaluation_payload(
                {"session_id": "session-1", "tool_name": "read_db"}
            ),
            ("session-1", "read_db"),
        )

    def test_rejects_extra_missing_and_invalid_fields(self):
        bad_payloads = [
            {"session_id": "x"},
            {"session_id": "x", "tool_name": "read_db", "extra": True},
            {"session_id": [], "tool_name": "read_db"},
            {"session_id": "x", "tool_name": "READ DB"},
        ]
        for payload in bad_payloads:
            with self.subTest(payload=payload):
                with self.assertRaises(RequestValidationError):
                    validate_evaluation_payload(payload)

    def test_session_identifier_has_hard_length_and_character_bounds(self):
        self.assertEqual(validate_session_id("a" * 128), "a" * 128)
        for value in ("a" * 129, "../session", " space", ""):
            with self.subTest(value=value):
                with self.assertRaises(RequestValidationError):
                    validate_session_id(value)


if __name__ == "__main__":
    unittest.main()
