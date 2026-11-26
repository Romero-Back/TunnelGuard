#!/usr/bin/env python3
"""Launch a macOS command with a V2Pro-bound HTTPS CONNECT proxy."""

import argparse
import contextlib
import http.client
import http.server
import ipaddress
import json
import os
import re
import select
import socket
import ssl
import subprocess
import sys
import threading
import time
from urllib.parse import urlencode, urlsplit


# Darwin constants from netinet/in.h and netinet6/in6.h.
IP_BOUND_IF = 25
IPV6_BOUND_IF = 125
TIMEOUT = 6
EGRESS_VALIDITY = 15
DOH_HOST = "cloudflare-dns.com"
DOH_ADDRESSES = tuple(map(ipaddress.ip_address, ("1.1.1.1", "2606:4700:4700::1111")))
IPIFY_HOST = "api64.ipify.org"
DIAGNOSTIC_HOST = "example.com"


def command_output(*command):
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            check=False, timeout=2, text=True)
    if result.returncode != 0:
        raise OSError(f"{os.path.basename(command[0])} could not confirm the network configuration")
    return result.stdout


def v2pro_interface():
    interfaces = []
    interface = None
    for line in command_output("/sbin/ifconfig", "-v").splitlines():
        if not line[:1].isspace():
            match = re.match(r"(utun[0-9]+): flags=[0-9a-f]+<([^>]+)>", line)
            interface = match[1] if match and "UP" in match[2].split(",") else None
        elif interface and 'desc:"VPN: V2Pro"' in line and "domain:NetworkExtension type:VPN" in line:
            interfaces.append(interface)
    if len(interfaces) != 1:
        raise OSError("Could not identify one active V2Pro tunnel")
    name = interfaces[0]
    return name, socket.if_nametoindex(name)


def verify_route(address, tunnel):
    family = "-inet" if address.version == 4 else "-inet6"
    route = command_output("/sbin/route", "-n", "get", family, str(address))
    interface = re.search(r"^\s*interface: (\S+)", route, re.MULTILINE)
    if not interface or interface[1] != tunnel[0] or v2pro_interface() != tunnel:
        raise OSError("The current route does not use the V2Pro tunnel")


def connect_bound(address, port, tunnel=None):
    if tunnel is None:
        tunnel = v2pro_interface()
    verify_route(address, tunnel)
    if address.version == 4:
        family, level, option = socket.AF_INET, socket.IPPROTO_IP, IP_BOUND_IF
    else:
        family, level, option = socket.AF_INET6, socket.IPPROTO_IPV6, IPV6_BOUND_IF
    connection = socket.socket(family, socket.SOCK_STREAM)
    try:
        connection.settimeout(TIMEOUT)
        connection.setsockopt(level, option, tunnel[1])
        connection.connect((str(address), port))
        verify_route(address, tunnel)
    except BaseException:
        connection.close()
        raise
    return connection, tunnel


def public_address(address):
    return address.is_global and not address.is_multicast and not address.is_reserved


def connect_authorized(address, port, tls_context, policy):
    if policy is None:
        return connect_bound(address, port)
    tunnel = v2pro_interface()
    policy.authorize(tunnel, address.version, tls_context)
    return connect_bound(address, port, tunnel)


def fetch_https(address, host, path, tls_context, *, tunnel=None, policy=None, accept="text/plain"):
    if tunnel is None:
        connection, _ = connect_authorized(address, 443, tls_context, policy)
    else:
        connection, _ = connect_bound(address, 443, tunnel)
    with connection, tls_context.wrap_socket(connection, server_hostname=host) as secured:
        secured.sendall((f"GET {path} HTTP/1.1\r\nHost: {host}\r\n"
                         f"Accept: {accept}\r\nConnection: close\r\n\r\n").encode("ascii"))
        with http.client.HTTPResponse(secured) as response:
            response.begin()
            if response.status != 200:
                raise OSError("HTTPS verification endpoint rejected the request")
            body = response.read(65537)
            if len(body) > 65536:
                raise OSError("HTTPS verification response is too large")
            return body


def resolve_doh(host, record_type, tls_context, *, policy=None, tunnel=None):
    request = urlencode({"name": host, "type": record_type})
    for resolver in DOH_ADDRESSES:
        try:
            body = fetch_https(resolver, DOH_HOST, f"/dns-query?{request}", tls_context,
                               tunnel=tunnel, policy=policy, accept="application/dns-json")
            result = json.loads(body)
            if result["Status"] != 0 or result.get("TC", False):
                return
            for answer in result.get("Answer", []):
                if answer["type"] == record_type:
                    address = ipaddress.ip_address(answer["data"])
                    if address.version == {1: 4, 28: 6}[record_type] and public_address(address):
                        yield address
            return
        except (OSError, subprocess.SubprocessError, http.client.HTTPException, ValueError, KeyError, TypeError):
            continue


def observe_egress(tunnel, version, tls_context):
    resolver = DOH_ADDRESSES[0] if version == 4 else DOH_ADDRESSES[1]
    trace = fetch_https(resolver, DOH_HOST, "/cdn-cgi/trace", tls_context, tunnel=tunnel)
    cloudflare_ip = next((line[3:] for line in trace.decode("ascii").splitlines()
                         if line.startswith("ip=")), "")
    addresses = resolve_doh(IPIFY_HOST, 1 if version == 4 else 28, tls_context, tunnel=tunnel)
    for address in addresses:
        try:
            ipify = fetch_https(address, IPIFY_HOST, "/", tls_context, tunnel=tunnel)
        except (OSError, subprocess.SubprocessError, http.client.HTTPException):
            continue
        return ipaddress.ip_address(cloudflare_ip), ipaddress.ip_address(ipify.decode("ascii").strip())
    raise OSError("The second egress verification endpoint is unavailable")


class EgressPolicy:
    def __init__(self, expected):
        self.expected = frozenset(expected)
        self.families = frozenset(address.version for address in self.expected)
        self.confirmed = {}
        self.locks = {version: threading.Lock() for version in self.families}

    def authorize(self, tunnel, version, tls_context):
        if version not in self.families:
            raise OSError(f"No IPv{version} egress address was configured")
        with self.locks[version]:
            verified = self.confirmed.get(version)
            if verified and verified[0] == tunnel and time.monotonic() < verified[1]:
                return
            self.confirmed.pop(version, None)
            try:
                first, second = observe_egress(tunnel, version, tls_context)
            except (OSError, subprocess.SubprocessError, http.client.HTTPException, ValueError) as error:
                raise OSError("Could not verify the VPN egress") from error
            if first != second or first.version != version or first not in self.expected:
                raise OSError("The VPN egress does not match the configuration")
            self.confirmed[version] = (tunnel, time.monotonic() + EGRESS_VALIDITY)


def destinations(host, tls_context, policy):
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        # A failed DNS lookup has no system resolver fallback.
        for version, record_type in ((4, 1), (6, 28)):
            if policy is None or version in policy.families:
                yield from resolve_doh(host, record_type, tls_context, policy=policy)
    else:
        if public_address(address):
            yield address


def connect_destination(host, tls_context, policy):
    for address in destinations(host, tls_context, policy):
        try:
            connection, tunnel = connect_authorized(address, 443, tls_context, policy)
            return connection, address, tunnel
        except (OSError, subprocess.SubprocessError):
            continue
    raise OSError("No confirmed V2Pro route to the destination")


def relay(client, upstream, address, tunnel, tls_context=None, policy=None):
    peers = {client: upstream, upstream: client}
    next_check = 0
    while peers:
        now = time.monotonic()
        if now >= next_check:
            verify_route(address, tunnel)
            if policy is not None:
                policy.authorize(tunnel, address.version, tls_context)
            next_check = time.monotonic() + 1
        readable, _, _ = select.select(peers, [], [], max(0, next_check - time.monotonic()))
        for source in readable:
            data = source.recv(65536)
            peer = peers[source]
            if data:
                peer.sendall(data)
            else:
                del peers[source]
                with contextlib.suppress(OSError):
                    peer.shutdown(socket.SHUT_WR)


class ConnectHandler(http.server.BaseHTTPRequestHandler):
    # Preserve bytes sent immediately after CONNECT for the relay.
    rbufsize = 0
    timeout = TIMEOUT

    def do_CONNECT(self):
        try:
            target = urlsplit("//" + self.path)
            if (not target.hostname or target.port != 443 or target.username is not None
                    or target.path or target.query or target.fragment or "%" in target.hostname):
                raise ValueError
            host = target.hostname.encode("idna").decode("ascii")
            if not re.fullmatch(r"[a-zA-Z0-9.:-]{1,253}", host):
                raise ValueError
        except (ValueError, UnicodeError):
            self.send_error(400, "Expected a hostname or IP address and port 443")
            return
        if self.server.policy is None and host != DIAGNOSTIC_HOST:
            self.send_error(403, "Only the fixed diagnostic endpoint is available")
            return
        try:
            upstream, address, tunnel = connect_destination(host, self.server.tls_context, self.server.policy)
        except (OSError, subprocess.SubprocessError):
            self.send_error(502, "No confirmed V2Pro route")
            return
        with upstream:
            self.send_response_only(200, "Connection Established")
            self.end_headers()
            with contextlib.suppress(OSError, subprocess.SubprocessError):
                relay(self.connection, upstream, address, tunnel, self.server.tls_context, self.server.policy)

    def log_message(self, format, *args):
        # Avoid printing application requests or destination names.
        pass


def sandbox_profile(proxy_port):
    return f"""(version 1)
(allow default)
(deny network-outbound network-inbound)
(allow network-outbound (remote tcp "localhost:{proxy_port}"))
(deny mach-lookup
    (global-name "com.apple.dnssd.service")
    (global-name "com.apple.nsurlsessiond")
    (global-name "com.apple.nsurlsessiond.privileged"))
"""


@contextlib.contextmanager
def proxy_server(policy, handler=ConnectHandler):
    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler) as server:
        server.tls_context = ssl.create_default_context()
        server.policy = policy
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            yield server
        finally:
            server.shutdown()
            worker.join()


def run(command, policy):
    with proxy_server(policy) as server:
        port = server.server_port
        proxy = f"http://127.0.0.1:{port}"
        environment = os.environ.copy()
        for key in ("http_proxy", "https_proxy", "all_proxy", "no_proxy"):
            value = "" if key == "no_proxy" else proxy
            environment[key] = environment[key.upper()] = value
        result = subprocess.run(["/usr/bin/sandbox-exec", "-p", sandbox_profile(port), *command],
                                env=environment, check=False)
        return result.returncode if result.returncode >= 0 else 128 - result.returncode


def expected_egress(value):
    try:
        address = ipaddress.ip_address(value)
    except ValueError:
        raise argparse.ArgumentTypeError("expected a public IP address") from None
    if not public_address(address) or "%" in value:
        raise argparse.ArgumentTypeError("expected a public IP address without a zone identifier")
    return address


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-v2pro", action="store_true", help="run a fixed HTTPS connectivity test")
    parser.add_argument("--expected-egress", action="append", type=expected_egress, default=[],
                        help="expected public VPN IP, repeat for additional allowed addresses")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    command = arguments.command
    if command[:1] == ["--"]:
        command = command[1:]
    if arguments.check_v2pro:
        if command:
            parser.error("--check-v2pro runs its own test command")
        command = ["/usr/bin/curl", "--fail", "--silent", "--show-error", "--head", "--output", "/dev/null",
                   "--max-time", "25", f"https://{DIAGNOSTIC_HOST}/"]
    elif not command:
        parser.error("specify a command after --")
    elif not arguments.expected_egress:
        parser.error("protected launches require at least one --expected-egress")
    if sys.platform != "darwin":
        parser.error("requires macOS")
    try:
        policy = EgressPolicy(arguments.expected_egress) if arguments.expected_egress else None
        return run(command, policy)
    except KeyboardInterrupt:
        return 130
    except OSError as error:
        print(f"TunnelGuard could not start: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
