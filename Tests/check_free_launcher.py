import contextlib
import errno
import http.client
import importlib.util
import ipaddress
import os
import select
import signal
import socket
import subprocess
import sys
import threading
import unittest
from pathlib import Path
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "tunnelguard", Path(__file__).resolve().parents[1] / "Scripts/tunnelguard-run.py"
)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class LauncherTest(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "darwin", "requires the macOS sandbox")
    def test_child_socket_access(self):
        with socket.socket() as permitted, socket.socket() as denied:
            for server in (permitted, denied):
                server.bind(("127.0.0.1", 0))
                server.listen()
            allowed_port, other_port = (s.getsockname()[1] for s in (permitted, denied))
            code = """
import errno, socket, sys
allowed_port, other_port = map(int, sys.argv[1:])
cases = [
    (socket.AF_INET, socket.SOCK_STREAM, ('127.0.0.1', allowed_port), True),
    (socket.AF_INET, socket.SOCK_STREAM, ('127.0.0.1', other_port), False),
    (socket.AF_INET6, socket.SOCK_STREAM, ('::1', other_port), False),
    (socket.AF_INET, socket.SOCK_DGRAM, ('127.0.0.1', allowed_port), False),
    (socket.AF_UNIX, socket.SOCK_STREAM, '/var/run/mDNSResponder', False),
]
for family, kind, endpoint, allowed in cases:
    with socket.socket(family, kind) as sock:
        try:
            sock.connect(endpoint)
        except PermissionError as error:
            assert not allowed and error.errno == errno.EPERM, (endpoint, error)
        else:
            assert allowed, endpoint
"""
            subprocess.run(["/usr/bin/sandbox-exec", "-p", guard.sandbox_profile(allowed_port),
                            "/bin/sh", "-c", '"$@"', "sh", sys.executable, "-c", code,
                            str(allowed_port), str(other_port)], check=True, timeout=5)

    def test_wrong_route_never_opens_an_upstream_socket(self):
        address = ipaddress.ip_address("1.1.1.1")
        with patch.object(guard, "v2pro_interface", return_value=("utun9", 19)), \
             patch.object(guard, "command_output", return_value="interface: en0\n"), \
             patch.object(guard.socket, "socket") as create:
            with self.assertRaises(OSError):
                guard.connect_bound(address, 443)
            create.assert_not_called()

    def test_upstream_uses_darwin_interface_binding_before_connect(self):
        tunnel = ("utun9", 19)
        cases = [("1.1.1.1", socket.IPPROTO_IP, guard.IP_BOUND_IF),
                 ("2606:4700:4700::1111", socket.IPPROTO_IPV6, guard.IPV6_BOUND_IF)]
        for host, level, option in cases:
            with self.subTest(host=host), \
                 patch.object(guard, "v2pro_interface", return_value=tunnel), \
                 patch.object(guard, "verify_route"), \
                 patch.object(guard.socket, "socket") as create:
                connection = create.return_value

                def check_binding(_):
                    connection.setsockopt.assert_called_once_with(level, option, tunnel[1])

                connection.connect.side_effect = check_binding
                self.assertEqual(guard.connect_bound(ipaddress.ip_address(host), 443), (connection, tunnel))
                connection.connect.assert_called_once_with((host, 443))

    def test_diagnostic_rejects_other_hosts_and_connections_without_v2pro(self):
        with guard.http.server.ThreadingHTTPServer(("127.0.0.1", 0), guard.ConnectHandler) as server:
            server.tls_context = None
            server.policy = None
            with patch.object(guard, "v2pro_interface", side_effect=OSError(errno.ENXIO, "no tunnel")):
                worker = threading.Thread(target=server.serve_forever, daemon=True)
                worker.start()
                try:
                    for host, expected_status in (("other.example.test", 403), (guard.DIAGNOSTIC_HOST, 502)):
                        client = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=2)
                        try:
                            client.request("CONNECT", f"{host}:443")
                            self.assertEqual(client.getresponse().status, expected_status)
                        finally:
                            client.close()
                finally:
                    server.shutdown()
                    worker.join(timeout=2)

    def test_egress_policy_requires_two_matching_expected_reports(self):
        tunnel = ("utun9", 19)
        expected, unexpected = map(ipaddress.ip_address, ("8.8.8.8", "1.1.1.1"))
        policy = guard.EgressPolicy([expected])
        for observation in [(expected, unexpected), (unexpected, unexpected), OSError("offline")]:
            with self.subTest(observation=observation), \
                 patch.object(guard, "observe_egress", side_effect=[observation]):
                with self.assertRaises(OSError):
                    policy.authorize(tunnel, 4, None)
        with patch.object(guard, "observe_egress", return_value=(expected, expected)) as observe:
            policy.authorize(tunnel, 4, None)
            policy.authorize(tunnel, 4, None)
            observe.assert_called_once_with(tunnel, 4, None)
            new_tunnel = ("utun12", 23)
            policy.authorize(new_tunnel, 4, None)
            observe.assert_called_with(new_tunnel, 4, None)
            with self.assertRaises(OSError):
                policy.authorize(tunnel, 6, None)
        with patch.object(guard.time, "monotonic", return_value=policy.confirmed[4][1]), \
             patch.object(guard, "observe_egress", side_effect=OSError("offline")):
            with self.assertRaises(OSError):
                policy.authorize(new_tunnel, 4, None)
            self.assertNotIn(4, policy.confirmed)

    def test_multiple_allowed_egress_addresses(self):
        first, second, unknown = map(ipaddress.ip_address, ("8.8.8.8", "9.9.9.9", "1.1.1.1"))
        policy = guard.EgressPolicy([first, second])
        observations = [(first, first), (second, second), (unknown, unknown)]
        with patch.object(guard, "observe_egress", side_effect=observations):
            self.assertEqual(policy.authorize(("utun1", 11), 4, None), first)
            self.assertEqual(policy.authorize(("utun1", 11), 4, None), first)
            self.assertEqual(policy.authorize(("utun2", 12), 4, None), second)
            with self.assertRaises(OSError):
                policy.authorize(("utun3", 13), 4, None)
            self.assertNotIn(4, policy.confirmed)

    def test_egress_denied_before_app_dns_can_leave(self):
        expected, wrong = map(ipaddress.ip_address, ("8.8.8.8", "1.1.1.1"))
        policy = guard.EgressPolicy([expected])
        with patch.object(guard, "v2pro_interface", return_value=("utun9", 19)), \
             patch.object(guard, "observe_egress", return_value=(wrong, wrong)), \
             patch.object(guard, "connect_bound") as connect:
            with self.assertRaises(OSError):
                guard.connect_destination("app-query.example.test", None, policy)
            connect.assert_not_called()

    @unittest.skipUnless(sys.platform == "darwin", "requires the macOS sandbox")
    def test_killing_proxy_keeps_child_off_other_sockets(self):
        child_code = """
import errno, os, socket, sys
from urllib.parse import urlsplit
proxy = urlsplit(os.environ['HTTPS_PROXY'])
with socket.create_connection((proxy.hostname, proxy.port), timeout=10) as active:
    print('ready', flush=True)
    assert os.read(0, 1) == b'x'
    try:
        assert active.recv(1) == b''
    except ConnectionResetError:
        pass
with socket.socket() as rejected:
    try:
        rejected.connect(('127.0.0.1', int(sys.argv[1])))
    except PermissionError as error:
        assert error.errno == errno.EPERM
    else:
        raise AssertionError('direct connection survived loss of the proxy')
print('blocked', flush=True)
"""
        with socket.socket() as control:
            control.bind(("127.0.0.1", 0))
            control.listen()
            with subprocess.Popen([sys.executable, guard.__file__, "--expected-egress", "8.8.8.8", "--",
                                   sys.executable, "-c", child_code, str(control.getsockname()[1])],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, start_new_session=True) as proxy:
                try:
                    self.assertTrue(select.select([proxy.stdout], [], [], 45)[0], "proxy child did not become ready")
                    self.assertEqual(proxy.stdout.readline().strip(), b"ready")
                    proxy.kill()
                    proxy.wait(timeout=10)
                    proxy.stdin.write(b"x")
                    proxy.stdin.flush()
                    self.assertTrue(select.select([proxy.stdout], [], [], 15)[0], "proxy child did not finish")
                    self.assertEqual(proxy.stdout.readline().strip(), b"blocked")
                finally:
                    with contextlib.suppress(ProcessLookupError):
                        os.killpg(proxy.pid, signal.SIGKILL)

    def test_existing_relay_closes_after_route_disappears(self):
        client, proxy_client = socket.socketpair()
        upstream, proxy_upstream = socket.socketpair()
        address = ipaddress.ip_address("1.1.1.1")
        lost = threading.Event()

        def verify(*_):
            if lost.is_set():
                raise OSError("tunnel gone")

        def relay():
            with proxy_client, proxy_upstream:
                try:
                    guard.relay(proxy_client, proxy_upstream, address, ("utun9", 19))
                except OSError:
                    return

        with client, upstream, patch.object(guard, "verify_route", side_effect=verify):
            upstream.settimeout(3)
            worker = threading.Thread(target=relay, daemon=True)
            worker.start()
            client.sendall(b"before")
            self.assertEqual(upstream.recv(64), b"before")
            lost.set()
            self.assertEqual(upstream.recv(64), b"")
            worker.join(timeout=2)
            self.assertFalse(worker.is_alive())


if __name__ == "__main__":
    unittest.main()
