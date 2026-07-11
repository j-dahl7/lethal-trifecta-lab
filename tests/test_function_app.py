import json
import pathlib
import sys
import unittest
from unittest import mock


FUNCTION_DIR = pathlib.Path(__file__).resolve().parents[1] / "function"
sys.path.insert(0, str(FUNCTION_DIR))

import function_app  # noqa: E402
from session_tracker import SessionStoreUnavailable  # noqa: E402


class FunctionAppFailureTests(unittest.IsolatedAsyncioTestCase):
    async def test_evaluate_returns_503_when_session_store_is_unavailable(self):
        request = mock.Mock()
        request.get_json.return_value = {
            "session_id": "http-store-failure",
            "tool_name": "read_db",
        }

        with mock.patch.object(
            function_app,
            "evaluate",
            side_effect=SessionStoreUnavailable("simulated failure"),
        ):
            response = await function_app.evaluate_tool_call(request)

        self.assertEqual(503, response.status_code)
        payload = json.loads(response.get_body())
        self.assertEqual(
            "Session store unavailable; request denied",
            payload["error"],
        )

    def test_readiness_returns_503_when_durable_store_is_unavailable(self):
        with mock.patch.object(
            function_app,
            "check_session_store_ready",
            side_effect=SessionStoreUnavailable("simulated failure"),
        ):
            response = function_app.readiness_check(mock.Mock())

        self.assertEqual(503, response.status_code)
        payload = json.loads(response.get_body())
        self.assertEqual("not_ready", payload["status"])
        self.assertFalse(payload["ready"])
        self.assertTrue(payload["durable"])

    def test_readiness_reports_local_memory_mode_explicitly(self):
        with mock.patch.object(
            function_app,
            "check_session_store_ready",
            return_value={
                "ready": True,
                "mode": "in_memory",
                "durable": False,
            },
        ):
            response = function_app.readiness_check(mock.Mock())

        self.assertEqual(200, response.status_code)
        payload = json.loads(response.get_body())
        self.assertEqual("ready", payload["status"])
        self.assertEqual("in_memory", payload["mode"])
        self.assertFalse(payload["durable"])


if __name__ == "__main__":
    unittest.main()
