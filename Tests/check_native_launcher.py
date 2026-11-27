import contextlib
import importlib.util
import io
import ipaddress
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch


spec = importlib.util.spec_from_file_location(
    "tunnelguard_native", Path(__file__).resolve().parents[1] / "Scripts/tunnelguard-native.py"
)
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)


class NativeLauncherTest(unittest.TestCase):
    tunnel = ("utun9", 19)
    allowed = ipaddress.ip_address("8.8.8.8")
    unexpected = ipaddress.ip_address("9.9.9.9")

    def setUp(self):
        state = patch.object(native.control, "access_state", return_value=("initial", False))
        state.start()
        self.addCleanup(state.stop)

    def test_start_refuses_missing_tunnel_or_unexpected_egress(self):
        cases = [(OSError("no tunnel"), (self.allowed, self.allowed)),
                 (self.tunnel, (self.unexpected, self.unexpected)),
                 (self.tunnel, (self.allowed, self.unexpected))]
        for interface, reports in cases:
            with self.subTest(interface=interface, reports=reports), \
                 patch.object(native.Path, "is_file", return_value=True), \
                 patch.object(native.subprocess, "check_output", return_value=""), \
                 patch.object(native.guard, "v2pro_interface", side_effect=[interface]), \
                 patch.object(native.guard, "observe_egress", return_value=reports), \
                 patch.object(native.subprocess, "run") as launch, \
                 contextlib.redirect_stderr(io.StringIO()):
                result = native.run("session", native.guard.EgressPolicy([self.allowed]), None)
                self.assertEqual(result, native.NETWORK_BLOCKED)
                launch.assert_not_called()

    def test_probe_checks_the_group_on_the_verified_tunnel_without_starting_claude(self):
        with patch.object(native.Path, "is_file", return_value=True), \
             patch.object(native.guard, "v2pro_interface", return_value=self.tunnel), \
             patch.object(native.guard, "observe_egress", return_value=(self.allowed, self.allowed)), \
             patch.object(native.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as group, \
             contextlib.redirect_stdout(io.StringIO()) as output:
            result = native.run("probe", native.guard.EgressPolicy([self.allowed]), None)
            self.assertEqual(result, 0)
            self.assertEqual(output.getvalue().strip(), str(self.allowed))
            self.assertIn("--child probe ", group.call_args.kwargs["input"])
            self.assertTrue(f"utun9 19 {self.allowed} --access-generation " in group.call_args.kwargs["input"])

        with patch.object(native, "assert_filter") as check_filter, \
             patch.object(native.guard, "connect_bound") as connect, \
             patch.object(native.os, "execv") as launch:
            connection = Mock()
            connect.return_value = (connection, self.tunnel)
            self.assertEqual(native.child("probe", 12345, 42, *self.tunnel, str(self.allowed)), 0)
            check_filter.assert_called_once_with(12345)
            connect.assert_called_once_with(native.guard.DOH_ADDRESSES[0], 443, self.tunnel)
            connection.close.assert_called_once()
            launch.assert_not_called()

    def test_filter_or_route_failure_does_not_publish_or_exec(self):
        for check_filter_error, connect_error in [(OSError("PF failed"), None), (None, OSError("route changed"))]:
            with self.subTest(filter_error=check_filter_error, route_error=connect_error), \
                 patch.object(native, "assert_filter", side_effect=check_filter_error), \
                 patch.object(native.guard, "connect_bound", side_effect=connect_error) as connect, \
                 patch.object(native, "publish") as publish, \
                 patch.object(native.os, "execv") as launch, \
                 contextlib.redirect_stderr(io.StringIO()):
                result = native.child("session", 12345, 42, *self.tunnel, str(self.allowed), "ready.json")
                self.assertEqual(result, native.NETWORK_BLOCKED)
                if check_filter_error:
                    connect.assert_not_called()
                publish.assert_not_called()
                launch.assert_not_called()

    def test_success_publishes_the_verified_address_before_exec(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(native, "assert_filter"), \
             patch.object(native.guard, "connect_bound", return_value=(Mock(), self.tunnel)), \
             patch.object(native.os, "execv") as launch:
            ready = Path(directory, "ready.json")

            def check_ready(_executable, _arguments):
                self.assertEqual(json.loads(ready.read_text()),
                                 {"pid": 42, "appPid": os.getpid(), "verifiedIPv4": str(self.allowed)})

            launch.side_effect = check_ready
            native.child("session", 12345, 42, *self.tunnel, str(self.allowed), str(ready))
            launch.assert_called_once_with(native.APP, [native.APP])


if __name__ == "__main__":
    unittest.main()
