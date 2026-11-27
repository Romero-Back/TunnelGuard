#!/usr/bin/env python3
"""Launch the installed Claude Desktop in the PF group restricted to the selected VPN."""

import argparse
from contextlib import nullcontext
import errno
import grp
import importlib.util
import json
import os
from pathlib import Path
import shlex
import signal
import socket
import ssl
import subprocess
import sys
import tempfile

# The bundled launcher imports the same control module as the source launcher.
try:
    import tunnelguard_control as control
except ModuleNotFoundError:
    control_spec = importlib.util.spec_from_file_location(
        "tunnelguard_control", Path(__file__).with_name("tunnelguard-control.py"))
    control = importlib.util.module_from_spec(control_spec)
    control_spec.loader.exec_module(control)


GROUP = "tunnelguard_claude"
APP_BUNDLE = Path("/Applications/Claude.app")
APP = str(APP_BUNDLE / "Contents/MacOS/Claude")
GATE_DIRECTORY = Path("/private/var/db/tunnelguard-desktop")
GATED_APP = str(GATE_DIRECTORY / "Claude.app/Contents/MacOS/Claude")
NETWORK_BLOCKED = 75

frozen = getattr(sys, "frozen", False)
if frozen:
    import tunnelguard_runner as guard
else:
    driver = Path(__file__).resolve()
    spec = importlib.util.spec_from_file_location("tunnelguard_runner", driver.with_name("tunnelguard-run.py"))
    guard = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(guard)


def assert_filter(blocked_port, host="127.0.0.1", family=socket.AF_INET):
    if os.geteuid() == 0 or os.getegid() != grp.getgrnam(GROUP).gr_gid:
        raise OSError("Claude must run as the signed-in user with the TunnelGuard process group")
    with socket.socket(family) as connection:
        connection.settimeout(2)
        try:
            connection.connect((host, blocked_port))
        except OSError as error:
            if not isinstance(error, socket.timeout) and error.errno not in (errno.EACCES, errno.EPERM):
                raise
        else:
            raise OSError("PF did not block the isolated group's direct test socket")


def publish(path, launcher_pid, verified_ipv4):
    fd, temporary = tempfile.mkstemp(prefix="native-session.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump({"pid": launcher_pid, "appPid": os.getpid(), "verifiedIPv4": verified_ipv4}, stream)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def report_blocked():
    print("TunnelGuard Native: protected network check failed", file=sys.stderr)
    return NETWORK_BLOCKED


def verify_group_connection(tunnel, blocked_port, generation=None, ipv6_port=None):
    if generation is not None:
        control.require_access(generation)
    assert_filter(blocked_port)
    if ipv6_port is not None:
        assert_filter(ipv6_port, "::1", socket.AF_INET6)
    connection, _ = guard.connect_bound(guard.DOH_ADDRESSES[0], 443, tunnel)
    connection.close()
    if generation is not None:
        control.require_access(generation)


def child(mode, blocked_port, launcher_pid, interface, index, verified_ipv4, ready_file=None, *, generation=None, ipv6_port=None):
    try:
        verify_group_connection((interface, index), blocked_port, generation, ipv6_port)
    except (OSError, KeyError, subprocess.SubprocessError):
        return report_blocked()
    if mode in ("probe", "leak"):
        return 0
    if ready_file:
        publish(Path(ready_file), launcher_pid, verified_ipv4)
    os.execv(APP, [APP])



def gated_request(stream):
    # The root-owned helper drops to the caller's UID before entering Python.
    if os.geteuid() == 0 or os.getegid() != grp.getgrnam(GROUP).gr_gid or not Path(GATED_APP).is_file():
        raise OSError("The restricted launch helper is required")
    line = stream.readline(16385)
    if not line.endswith(b"\n") or len(line) > 16384:
        raise OSError("Invalid restricted launch request")
    request = json.loads(line)
    required = {"mode", "expected", "pid", "publish"}
    if not isinstance(request, dict) or set(request) not in (required, required | {"vpn"}):
        raise OSError("Invalid restricted launch request")
    profile = request.get("vpn", guard.DEFAULT_VPN_PROFILE)
    if not guard.valid_vpn_profile(profile) or profile != guard.vpn_profile():
        raise OSError("The restricted launch requires the configured VPN")
    mode, expected, pid, should_publish = (request[key] for key in ("mode", "expected", "pid", "publish"))
    if mode not in ("session", "probe", "leak") or type(pid) is not int or pid <= 1 or type(should_publish) is not bool:
        raise OSError("Invalid restricted launch request")
    if not isinstance(expected, list) or not expected or not all(isinstance(value, str) for value in expected):
        raise OSError("No permitted IPv4")
    addresses = [guard.expected_egress(value) for value in expected]
    if any(address.version != 4 for address in addresses):
        raise OSError("Only IPv4 is supported")
    if mode == "session":
        ensure_not_running()
    try:
        generation, _ = control.access_state()
        control.require_access(generation)
        tunnel = guard.v2pro_interface()
        policy = guard.EgressPolicy(addresses)
        verified = policy.authorize(tunnel, 4, ssl.create_default_context(cafile="/etc/ssl/cert.pem"))
        ipv6_listener = socket.socket(socket.AF_INET6) if mode == "leak" else nullcontext()
        with socket.socket() as blocked, ipv6_listener as blocked6:
            blocked.bind(("127.0.0.1", 0))
            blocked.listen()
            ipv6_port = None
            if blocked6 is not None:
                blocked6.bind(("::1", 0))
                blocked6.listen()
                ipv6_port = blocked6.getsockname()[1]
            verify_group_connection(tunnel, blocked.getsockname()[1], generation, ipv6_port)
        if profile != guard.vpn_profile():
            raise OSError("The VPN profile changed during verification")
    except (OSError, KeyError, subprocess.SubprocessError):
        return report_blocked()
    if mode in ("probe", "leak"):
        print(verified, flush=True)
        return 0
    if should_publish:
        publish(control.SUPPORT / "native-session.json", pid, str(verified))
    os.execv(GATED_APP, [GATED_APP])


def ensure_not_running():
    executables = subprocess.check_output(["/bin/ps", "-axo", "comm="], text=True).splitlines()
    if any(executable.strip() in (APP, GATED_APP) for executable in executables):
        raise OSError("Quit the existing Claude before launching a protected session")


def clear_session(ready_file):
    if ready_file is None:
        return
    try:
        with ready_file.open(encoding="utf-8") as stream:
            record = json.load(stream)
        if record.get("pid") == os.getpid():
            ready_file.unlink(missing_ok=True)
    except (OSError, ValueError, AttributeError):
        pass


def request_gated_launch(mode, addresses, ready_file):
    if ready_file is not None and ready_file != control.SUPPORT / "native-session.json":
        raise OSError("Unexpected session record path")
    try:
        profile = guard.vpn_profile()
        if profile not in guard.detected_vpn_interfaces():
            return report_blocked()
    except (OSError, subprocess.SubprocessError):
        return report_blocked()
    body = {"mode": mode, "expected": [str(address) for address in addresses],
            "pid": os.getpid(), "publish": ready_file is not None}
    if profile != guard.DEFAULT_VPN_PROFILE:
        # Older installed helpers reject this field instead of launching through V2Pro.
        body["vpn"] = profile
    try:
        result = subprocess.run(["/usr/bin/sudo", "-n", str(GATE_DIRECTORY / "launch")],
                                input=json.dumps(body) + "\n", text=True, check=False)
        return result.returncode if result.returncode >= 0 else 128 - result.returncode
    finally:
        clear_session(ready_file)


def run(mode, policy, ready_file, *, require_gate=False):
    if os.path.lexists(GATE_DIRECTORY):
        return request_gated_launch(mode, policy.expected, ready_file)
    if require_gate:
        raise OSError("The restricted launch helper is missing")
    if not Path(APP).is_file():
        raise OSError("Claude.app is missing from /Applications")
    if mode == "session":
        ensure_not_running()
    try:
        interface, index = guard.v2pro_interface()
        verified = policy.authorize((interface, index), 4, ssl.create_default_context(cafile="/etc/ssl/cert.pem"))
    except (OSError, subprocess.SubprocessError):
        return report_blocked()
    ipv6_listener = socket.socket(socket.AF_INET6) if mode == "leak" else nullcontext()
    with socket.socket() as blocked, ipv6_listener as blocked6:
        blocked.bind(("127.0.0.1", 0))
        blocked.listen()
        command = [sys.executable] if frozen else ["/usr/bin/python3", "-B", str(driver)]
        command += ["--child", mode, str(blocked.getsockname()[1]), str(os.getpid()), interface, str(index), str(verified)]
        if ready_file:
            command.append(str(ready_file))
        generation, paused = control.access_state()
        if paused:
            return report_blocked()
        if policy.access_check:
            policy.access_check()
        command += ["--access-generation", generation]
        if mode == "leak":
            blocked6.bind(("::1", 0))
            blocked6.listen()
            command += ["--ipv6-port", str(blocked6.getsockname()[1])]
        environment = dict(os.environ, SHELL="/bin/sh")
        if frozen:
            environment["PYINSTALLER_RESET_ENVIRONMENT"] = "1"
        try:
            result = subprocess.run(["/usr/bin/newgrp", GROUP], input="exec " + shlex.join(command) + "\n",
                                    text=True, env=environment, check=False)
            if mode in ("probe", "leak") and result.returncode == 0:
                print(verified, flush=True)
            return result.returncode if result.returncode >= 0 else 128 - result.returncode
        finally:
            clear_session(ready_file)


def main():
    if sys.argv[1:] == ["--gated-request"]:
        return gated_request(sys.stdin.buffer)
    if sys.argv[1:2] == ["--child"]:
        parser = argparse.ArgumentParser()
        parser.add_argument("ready_file", nargs="?")
        parser.add_argument("--access-generation", required=True)
        parser.add_argument("--ipv6-port", type=int)
        options = parser.parse_args(sys.argv[8:])
        return child(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5], int(sys.argv[6]),
                     sys.argv[7], options.ready_file, generation=options.access_generation, ipv6_port=options.ipv6_port)
    if sys.argv[1:2] == ["cli"]:
        if sys.platform != "darwin" or os.geteuid() == 0:
            raise OSError("Requires an unprivileged macOS user")
        return control.cli(guard, run, sys.argv[2:])
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", action="store_true", help="test the filter and selected VPN without starting Claude")
    parser.add_argument("--expected-egress", action="append", required=True, type=guard.expected_egress,
                        help="permitted VPN IPv4, repeat to allow more than one")
    parser.add_argument("--ready-file", type=Path)
    parser.add_argument("--require-gate", action="store_true")
    args = parser.parse_args()
    if sys.platform != "darwin" or os.geteuid() == 0:
        parser.error("requires an unprivileged macOS user")
    if any(address.version != 4 for address in args.expected_egress):
        parser.error("the native Claude filter only supports IPv4")
    mode = "probe" if args.probe else "session"
    generation, paused = control.access_state()
    if paused:
        return report_blocked()
    def require_access():
        control.require_access(generation)
    return run(mode, guard.EgressPolicy(args.expected_egress, access_check=require_access),
               args.ready_file if mode == "session" else None, require_gate=args.require_gate)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, signal.default_int_handler)
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, argparse.ArgumentTypeError, subprocess.SubprocessError) as error:
        print(f"TunnelGuard Native: {error}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(130)
