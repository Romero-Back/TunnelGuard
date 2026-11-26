#!/usr/bin/env python3
"""Launch the installed Claude Desktop in the PF group restricted to V2Pro."""

import argparse
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


GROUP = "tunnelguard_claude"
APP = "/Applications/Claude.app/Contents/MacOS/Claude"
NETWORK_BLOCKED = 75

frozen = getattr(sys, "frozen", False)
if frozen:
    import tunnelguard_runner as guard
else:
    driver = Path(__file__).resolve()
    spec = importlib.util.spec_from_file_location("tunnelguard_runner", driver.with_name("tunnelguard-run.py"))
    guard = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(guard)


def assert_filter(blocked_port):
    if os.geteuid() == 0 or os.getegid() != grp.getgrnam(GROUP).gr_gid:
        raise OSError("Claude must run as the signed-in user with the TunnelGuard process group")
    with socket.socket() as connection:
        connection.settimeout(2)
        try:
            connection.connect(("127.0.0.1", blocked_port))
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


def child(mode, blocked_port, launcher_pid, interface, index, verified_ipv4, ready_file=None):
    try:
        assert_filter(blocked_port)
        connection, _ = guard.connect_bound(guard.DOH_ADDRESSES[0], 443, (interface, index))
        connection.close()
    except (OSError, KeyError, subprocess.SubprocessError):
        return report_blocked()
    if mode == "probe":
        return 0
    if ready_file:
        publish(Path(ready_file), launcher_pid, verified_ipv4)
    os.execv(APP, [APP])


def run(mode, policy, ready_file):
    if not Path(APP).is_file():
        raise OSError("Claude.app is missing from /Applications")
    if mode == "session":
        executables = subprocess.check_output(["/bin/ps", "-axo", "comm="], text=True).splitlines()
        if any(executable.strip() == APP for executable in executables):
            raise OSError("Quit the existing native Claude before launching a protected session")
    try:
        interface, index = guard.v2pro_interface()
        verified = policy.authorize((interface, index), 4, ssl.create_default_context(cafile="/etc/ssl/cert.pem"))
    except (OSError, subprocess.SubprocessError):
        return report_blocked()
    with socket.socket() as blocked:
        blocked.bind(("127.0.0.1", 0))
        blocked.listen()
        command = [sys.executable] if frozen else ["/usr/bin/python3", "-B", str(driver)]
        command += ["--child", mode, str(blocked.getsockname()[1]), str(os.getpid()), interface, str(index), str(verified)]
        if ready_file:
            command.append(str(ready_file))
        environment = dict(os.environ, SHELL="/bin/sh")
        if frozen:
            environment["PYINSTALLER_RESET_ENVIRONMENT"] = "1"
        try:
            result = subprocess.run(["/usr/bin/newgrp", GROUP], input="exec " + shlex.join(command) + "\n",
                                    text=True, env=environment, check=False)
            if mode == "probe" and result.returncode == 0:
                print(verified, flush=True)
            return result.returncode if result.returncode >= 0 else 128 - result.returncode
        finally:
            if ready_file and ready_file.exists():
                with ready_file.open(encoding="utf-8") as stream:
                    record = json.load(stream)
                if record.get("pid") == os.getpid():
                    ready_file.unlink(missing_ok=True)


def main():
    if sys.argv[1:2] == ["--child"]:
        return child(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5], int(sys.argv[6]), *sys.argv[7:])
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", action="store_true", help="test the filter and V2Pro without starting Claude")
    parser.add_argument("--expected-egress", action="append", required=True, type=guard.expected_egress,
                        help="permitted VPN IPv4, repeat to allow more than one")
    parser.add_argument("--ready-file", type=Path)
    args = parser.parse_args()
    if sys.platform != "darwin" or os.geteuid() == 0:
        parser.error("requires an unprivileged macOS user")
    if any(address.version != 4 for address in args.expected_egress):
        parser.error("the native Claude filter only supports IPv4")
    mode = "probe" if args.probe else "session"
    return run(mode, guard.EgressPolicy(args.expected_egress), args.ready_file if mode == "session" else None)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, signal.default_int_handler)
    try:
        sys.exit(main())
    except (OSError, KeyError, subprocess.SubprocessError) as error:
        print(f"TunnelGuard Native: {error}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(130)
