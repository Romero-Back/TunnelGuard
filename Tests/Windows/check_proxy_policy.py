import ipaddress
from pathlib import Path
import socket
import struct
import sys
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Windows"))
from tunnelguard_windows import IP_UNICAST_IF, WindowsProxy


class WindowsRouteTest(unittest.TestCase):
    def setUp(self):
        self.firewall = Mock()
        self.firewall.route_index.return_value = 42
        self.firewall.interface_id.return_value = 88
        self.addr = ipaddress.IPv4Address("1.1.1.1")
        self.proxy = WindowsProxy(self.firewall, 42, ipaddress.IPv4Address("8.8.8.8"))

    def test_mismatched_route_refuses_before_socket_creation(self):
        self.firewall.route_index.return_value = 5
        with patch.object(socket, "socket") as create:
            with self.assertRaises(OSError):
                self.proxy.connect_bound(self.addr, 443)
            create.assert_not_called()

    def test_connection_binds_before_connect_and_closes_on_route_change(self):
        self.firewall.route_index.side_effect = [42, 5]
        with patch.object(socket, "socket") as create:
            with self.assertRaises(OSError):
                self.proxy.connect_bound(self.addr, 443)
            calls = [call[0] for call in create.return_value.method_calls]
            self.assertLess(calls.index("setsockopt"), calls.index("connect"))
            create.return_value.setsockopt.assert_called_once_with(socket.IPPROTO_IP, IP_UNICAST_IF, struct.pack("!I", 42))
            create.return_value.close.assert_called_once()

    def test_recycled_index_stops_an_existing_proxy(self):
        self.firewall.interface_id.return_value = 89
        with self.assertRaises(OSError):
            self.proxy.tunnel()


if __name__ == "__main__":
    unittest.main()
