import os
import pathlib
import sys
import unittest
from unittest import mock


FUNCTION_DIR = pathlib.Path(__file__).resolve().parents[1] / "function"
sys.path.insert(0, str(FUNCTION_DIR))

import session_tracker  # noqa: E402
from policy_engine import evaluate  # noqa: E402


class PolicyEngineTests(unittest.TestCase):
    def setUp(self):
        self.environment = mock.patch.dict(
            os.environ,
            {"COSMOS_ENDPOINT": "", "COSMOS_KEY": ""},
        )
        self.environment.start()
        session_tracker._sessions.clear()
        session_tracker._cosmos_container = None
        session_tracker._cosmos_initialized = False
        session_tracker._cosmos_init_error = None

    def tearDown(self):
        self.environment.stop()

    def test_blocks_unregistered_tools(self):
        result = evaluate("test-unknown", "unreviewed_tool")
        self.assertEqual("BLOCK", result.decision)
        self.assertIn("not in the reviewed registry", result.reason)

    def test_blocks_third_distinct_condition(self):
        self.assertEqual("ALLOW", evaluate("test-trifecta", "read_db").decision)
        self.assertEqual("ALLOW", evaluate("test-trifecta", "process_document").decision)
        result = evaluate("test-trifecta", "send_http")
        self.assertEqual("BLOCK", result.decision)
        self.assertEqual(
            ["private_data", "untrusted_content"],
            result.conditions_after,
        )

    def test_allows_repeated_existing_condition(self):
        self.assertEqual("ALLOW", evaluate("test-repeat", "read_db").decision)
        self.assertEqual("ALLOW", evaluate("test-repeat", "read_keyvault").decision)

    def test_configured_store_initialization_error_fails_closed(self):
        os.environ["COSMOS_ENDPOINT"] = "https://example.documents.azure.com:443/"
        session_tracker._cosmos_initialized = True
        session_tracker._cosmos_init_error = RuntimeError("simulated init failure")

        with self.assertRaises(session_tracker.SessionStoreUnavailable):
            session_tracker.get_session_state("test-init-failure")

    def test_configured_store_read_error_fails_closed(self):
        container = mock.Mock()
        container.read_item.side_effect = RuntimeError("simulated read failure")

        with mock.patch.object(
            session_tracker,
            "_get_cosmos_container",
            return_value=container,
        ):
            with self.assertRaises(session_tracker.SessionStoreUnavailable):
                session_tracker.get_session_state("test-read-failure")

    def test_configured_store_write_error_fails_closed(self):
        not_found = RuntimeError("simulated missing session")
        not_found.status_code = 404
        container = mock.Mock()
        container.read_item.side_effect = not_found
        container.upsert_item.side_effect = RuntimeError("simulated write failure")

        with mock.patch.object(
            session_tracker,
            "_get_cosmos_container",
            return_value=container,
        ):
            with self.assertRaises(session_tracker.SessionStoreUnavailable):
                session_tracker.record_tool_call(
                    "test-write-failure",
                    "read_db",
                    "private_data",
                )

    def test_readiness_fails_when_configured_store_is_unreachable(self):
        container = mock.Mock()
        container.read.side_effect = RuntimeError("simulated readiness failure")

        with mock.patch.object(
            session_tracker,
            "_get_cosmos_container",
            return_value=container,
        ):
            with self.assertRaises(session_tracker.SessionStoreUnavailable):
                session_tracker.check_session_store_ready()

    def test_unconfigured_local_store_is_ready_but_not_durable(self):
        result = session_tracker.check_session_store_ready()
        self.assertTrue(result["ready"])
        self.assertEqual("in_memory", result["mode"])
        self.assertFalse(result["durable"])


if __name__ == "__main__":
    unittest.main()
