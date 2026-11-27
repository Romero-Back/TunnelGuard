from io import BytesIO
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "gated_native", Path(__file__).resolve().parents[1] / "Scripts/tunnelguard-native.py"
)
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)


class DesktopGateTests(unittest.TestCase):
    def request(self, **overrides):
        body = dict(mode="session", expected=["8.8.8.8"], pid=123, publish=False)
        body.update(overrides)
        return BytesIO(json.dumps(body).encode() + b"\n")

    def test_unprivileged_direct_gate_requires_the_private_group(self):
        with patch.object(native.os, "geteuid", return_value=501), \
             patch.object(native.os, "getegid", return_value=888), \
             patch.object(native.Path, "is_file", return_value=False), \
             patch.object(native.grp, "getgrnam") as group, \
             patch.object(native.os, "execv") as run:
            group.return_value.gr_gid = 888
            with self.assertRaises(OSError):
                native.gated_request(self.request())
            run.assert_not_called()

    def test_route_failure_cannot_execute_and_success_runs_the_fixed_copy(self):
        expected = native.guard.expected_egress("8.8.8.8")
        with patch.object(native.os, "geteuid", return_value=501), \
             patch.object(native.os, "getegid", return_value=888), \
             patch.object(native.grp, "getgrnam") as group, \
             patch.object(native.Path, "is_file", return_value=True), \
             patch.object(native, "ensure_not_running"), \
             patch.object(native.control, "access_state", return_value=("initial", False)), \
             patch.object(native.control, "require_access"), \
             patch.object(native.guard, "v2pro_interface", return_value=("utun9", 19)), \
             patch.object(native.guard.EgressPolicy, "authorize", return_value=expected), \
             patch.object(native, "verify_group_connection", side_effect=[OSError("unverified"), None]), \
             patch.object(native, "report_blocked", return_value=75), \
             patch.object(native.os, "execv") as run:
            group.return_value.gr_gid = 888
            with self.assertRaises(OSError):
                native.gated_request(self.request(command="/bin/sh"))
            self.assertEqual(native.gated_request(self.request()), 75)
            run.assert_not_called()
            native.gated_request(self.request())
            run.assert_called_once_with(native.GATED_APP, [native.GATED_APP])

    def test_installed_gate_never_falls_back_to_the_legacy_launcher(self):
        expected = native.guard.expected_egress("8.8.8.8")
        with patch.object(native.os.path, "lexists", return_value=True), \
             patch.object(native, "request_gated_launch", return_value=77) as request, \
             patch.object(native.Path, "is_file") as legacy:
            self.assertEqual(native.run("session", native.guard.EgressPolicy([expected]), None), 77)
            request.assert_called_once_with("session", frozenset([expected]), None)
            legacy.assert_not_called()


if __name__ == "__main__":
    unittest.main()
