"""Read-only network diagnostics and the user-level emergency latch."""

import argparse
import fcntl
import json
import os
from pathlib import Path
import plistlib
import ssl
import subprocess
import tempfile
from contextlib import contextmanager
from uuid import uuid4

SUPPORT = Path.home() / "Library/Application Support/TunnelGuard"
STATE = SUPPORT / "access-state"
CODE_LOCK = SUPPORT / "claude-code.lock"


def access_state():
    try:
        value = STATE.read_text(encoding="ascii").split()
    except FileNotFoundError:
        return "initial", False
    if len(value) != 2 or value[1] not in ("paused", "ready"):
        raise OSError("Emergency access state is unreadable")
    return value[0], value[1] == "paused"


def set_access(paused):
    SUPPORT.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, path = tempfile.mkstemp(dir=SUPPORT)
    try:
        with os.fdopen(fd, "w", encoding="ascii") as stream:
            stream.write(f"{uuid4().hex} {'paused' if paused else 'ready'}\n")
        os.replace(path, STATE)
    finally:
        Path(path).unlink(missing_ok=True)


def require_access(generation):
    current, paused = access_state()
    if paused or current != generation:
        raise OSError("TunnelGuard access has been paused")


@contextmanager
def code_session(generation=None):
    SUPPORT.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(CODE_LOCK, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if generation is not None:
            os.ftruncate(fd, 0)
            os.write(fd, generation.encode("ascii"))
        yield
    finally:
        os.close(fd)


def code_active():
    try:
        fd = os.open(CODE_LOCK, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return False
    except OSError:
        return None
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return False
    except BlockingIOError:
        return True
    except OSError:
        return None
    finally:
        os.close(fd)


def configured_addresses():
    result = subprocess.run(["/usr/bin/defaults", "export", "app.tunnelguard.local", "-"],
                            capture_output=True, timeout=4)
    if result.returncode:
        return []
    settings = plistlib.loads(result.stdout)
    allowed = settings.get("allowedIPv4") or [settings.get("expectedIPv4")]
    selected = settings.get("selectedIPv4")
    return [selected] if selected and selected in allowed else [address for address in allowed if address]


def monitor(guard):
    result = dict(interface=None, routeIPv4=None, routeIPv6=None, filter="unknown", filterRuns=None,
                  paused=None, codeActive=code_active(), codeAuthorized=None)
    try:
        generation, result["paused"] = access_state()
        if result["codeActive"]:
            result["codeAuthorized"] = not result["paused"] and CODE_LOCK.read_text(encoding="ascii") == generation
    except OSError:
        pass
    try:
        tunnel = guard.v2pro_interface()
        result["interface"] = tunnel[0]
    except (OSError, subprocess.SubprocessError):
        tunnel = None
    if tunnel:
        for address, key in zip(guard.DOH_ADDRESSES, ("routeIPv4", "routeIPv6")):
            try:
                guard.verify_route(address, tunnel)
                result[key] = True
            except (OSError, subprocess.SubprocessError):
                result[key] = False
    try:
        job = subprocess.run(["/bin/launchctl", "print", "system/app.tunnelguard.native-filter"],
                             capture_output=True, text=True, timeout=2)
        if job.returncode == 0:
            status = next((line.strip().split(" = ", 1)[1] for line in job.stdout.splitlines()
                           if line.strip().startswith("last exit code = ")), None)
            runs = next((line.strip().split(" = ", 1)[1] for line in job.stdout.splitlines()
                         if line.strip().startswith("runs = ")), None)
            if runs and runs.isdecimal():
                result["filterRuns"] = int(runs)
            if status == "0":
                result["filter"] = "healthy"
            elif status and status.lstrip("-").isdigit():
                result["filter"] = "failed"
        elif "Could not find service" in job.stderr:
            result["filter"] = "missing"
    except (OSError, subprocess.SubprocessError):
        pass
    return result


def stop_desktop():
    result = subprocess.run(["/bin/launchctl", "bootout", f"gui/{os.getuid()}/app.tunnelguard.native"],
                            capture_output=True, timeout=5)
    if result.returncode:
        check = subprocess.run(["/bin/launchctl", "print", f"gui/{os.getuid()}/app.tunnelguard.native"],
                               capture_output=True, timeout=5)
        if b"Could not find service" not in check.stderr:
            raise OSError("Could not confirm that the desktop job was stopped")


def cli(guard, native_run, arguments):
    parser = argparse.ArgumentParser(prog="tunnelguard", description=__doc__)
    parser.add_argument("action", choices=("status", "check", "leak-test", "fingerprint", "launch-code", "panic", "resume"))
    parser.add_argument("--expected-egress", action="append", type=guard.expected_egress)
    parser.add_argument("--executable", type=Path, help="absolute path to the installed Claude Code executable")
    options = parser.parse_args(arguments)
    if options.action == "status":
        print(json.dumps(monitor(guard)))
        return 0
    if options.action == "panic":
        set_access(True)
        stop_desktop()
        return 0
    if options.action == "resume":
        set_access(False)
        return 0
    expected = options.expected_egress
    if not expected:
        try:
            expected = [guard.expected_egress(value) for value in configured_addresses()]
        except (argparse.ArgumentTypeError, plistlib.InvalidFileException, TypeError):
            parser.error("the saved IPv4 list is invalid")
    if not expected or any(address.version != 4 for address in expected):
        parser.error("configure a permitted public IPv4 or use --expected-egress")
    generation, paused = access_state()
    if paused:
        raise OSError("TunnelGuard access is paused")
    policy = guard.EgressPolicy(expected, access_check=lambda: require_access(generation))
    if options.action == "fingerprint":
        interface = guard.v2pro_interface()
        address = policy.authorize(interface, 4, ssl.create_default_context(cafile="/etc/ssl/cert.pem"))
        print(json.dumps(dict(interface=interface[0], egress=str(address))))
        return 0
    if options.action != "launch-code":
        return native_run("leak" if options.action == "leak-test" else "probe", policy, None)

    choices = (Path.home() / ".local/bin/claude", Path("/opt/homebrew/bin/claude"), Path("/usr/local/bin/claude"))
    binary = options.executable or next((path for path in choices if os.access(path, os.X_OK)), None)
    if not binary or not binary.is_absolute() or not binary.is_file() or not os.access(binary, os.X_OK):
        parser.error("install Claude Code or specify --executable with its absolute path")
    with code_session(generation):
        policy.authorize(guard.v2pro_interface(), 4, ssl.create_default_context(cafile="/etc/ssl/cert.pem"))
        require_access(generation)
        return guard.run([str(binary)], policy)
