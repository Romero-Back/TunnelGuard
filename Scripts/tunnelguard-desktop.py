#!/usr/bin/env python3
"""Run official Claude Desktop in a network-isolated Lima guest."""

import argparse
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
LIMA_HOME = Path(os.environ.get("TUNNELGUARD_LIMA_HOME", ROOT / ".build" / "desktop-lima")).expanduser().resolve()
INSTANCE = "tunnelguard-desktop"
SSH_CONFIG = LIMA_HOME / INSTANCE / "ssh.config"
PREPARED_MARKER = SSH_CONFIG.parent / "tunnelguard-prepared"
PACKAGE = ROOT / "Packaging" / "linux"
SESSION_LABEL = "app.tunnelguard.desktop.session"
GUEST_PROXY = "127.0.0.1:3128"
GUEST_VNC = "127.0.0.1:5900"
VSOCK_ONLY = 'case "$SSH_CONNECTION" in UNKNOWN*) ;; *) echo "Expected SSH over vsock" >&2; exit 64 ;; esac; '

spec = importlib.util.spec_from_file_location("tunnelguard_runner", ROOT / "Scripts" / "tunnelguard-run.py")
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


def ssh_command(remote, *options):
    return ["/usr/bin/ssh", "-F", str(SSH_CONFIG), "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes", "-o", "ControlPath=none", "-T",
            *options, f"lima-{INSTANCE}", VSOCK_ONLY + remote]


def start_guest():
    lima = shutil.which("limactl")
    if not lima:
        raise OSError("Lima 2.3 or later must be installed")
    environment = dict(os.environ, LIMA_HOME=str(LIMA_HOME))
    exists = (LIMA_HOME / INSTANCE / "lima.yaml").is_file()
    args = [INSTANCE] if exists else [f"--name={INSTANCE}", str(PACKAGE / "desktop-vm.yaml")]
    subprocess.run([lima, "start", "--yes", "--timeout=8m", *args], env=environment, check=True)


def prepare_guest():
    start_guest()
    with (PACKAGE / "prepare-guest.sh").open("rb") as source:
        subprocess.run(ssh_command("exec sudo -n /bin/sh -s"), stdin=source, check=True)
    for source_name, destination in (("launch-guest.sh", "tunnelguard-launch"),
                                     ("desktop-session.sh", "tunnelguard-session")):
        destination = f"/usr/local/libexec/{destination}"
        with (PACKAGE / source_name).open("rb") as source:
            subprocess.run(ssh_command(f"sudo -n tee {destination} >/dev/null && sudo -n chmod 755 {destination}"),
                           stdin=source, check=True)
    PREPARED_MARKER.touch()


def probe_running_guest():
    # Use the live proxy without opening another reverse SSH forward or reloading the guest firewall.
    remote = (f"exec sudo -n -u tunnelguard-app /usr/bin/curl --proxy http://{GUEST_PROXY} "
              "--noproxy '' --fail --silent --show-error --max-time 22 --head --output /dev/null https://example.com/")
    return subprocess.run(ssh_command(remote, "-o", "ConnectTimeout=4"), check=False, timeout=30).returncode


def localhost_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def wait_for_vnc(session, port):
    deadline = time.monotonic() + 20
    while session.poll() is None and time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.4) as connection:
                with connection.makefile("rb") as stream:
                    if stream.read(4) == b"RFB ":
                        return
        except OSError:
            pass
        time.sleep(0.2)
    raise OSError("The guest did not start its loopback VNC session")


@contextlib.contextmanager
def publish_session(path, port, password, policy):
    if path is None:
        print(f"Screen Sharing: vnc://127.0.0.1:{port}", flush=True)
        print(f"Temporary VNC password: {password}", flush=True)
        yield
        return

    record = {
        "label": SESSION_LABEL, "pid": os.getpid(), "port": port, "password": password,
        "expectedIPv4": next((str(address) for address in sorted(policy.expected, key=str) if address.version == 4), ""),
    }
    fd, temporary = tempfile.mkstemp(prefix="session.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(record, stream)
        os.replace(temporary, path)
        yield
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary)
        with contextlib.suppress(OSError, ValueError):
            if json.loads(path.read_text(encoding="utf-8")) == record:
                path.unlink()


def run_guest(mode, policy, session_file=None):
    start_guest()
    with guard.proxy_server(policy) as server:
        remote = f"exec sudo -n /usr/local/libexec/tunnelguard-launch {mode}"
        options = ["-o", "ExitOnForwardFailure=yes", "-R", f"{GUEST_PROXY}:127.0.0.1:{server.server_port}"]
        if mode != "session":
            result = subprocess.run(ssh_command(remote, *options), check=False, timeout=60)
            return result.returncode

        port = localhost_port()
        password = secrets.token_hex(4)
        unit = f"tunnelguard-desktop-{secrets.token_hex(8)}"
        options += ["-L", f"127.0.0.1:{port}:{GUEST_VNC}"]
        with subprocess.Popen(ssh_command(f"{remote} {unit}", *options), stdin=subprocess.PIPE, text=True) as session:
            try:
                session.stdin.write(password + "\n")
                session.stdin.close()
                wait_for_vnc(session, port)
                with publish_session(session_file, port, password, policy):
                    return session.wait()
            finally:
                if session.poll() is None:
                    session.terminate()
                    try:
                        session.wait(timeout=4)
                    except subprocess.TimeoutExpired:
                        session.kill()
                with contextlib.suppress(OSError, subprocess.SubprocessError):
                    subprocess.run(ssh_command(f"exec sudo -n systemctl stop {unit}.service"), timeout=8,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--prepare", action="store_true", help="create and provision the isolated Debian guest")
    mode.add_argument("--probe", action="store_true", help="test HTTPS from the isolated guest")
    mode.add_argument("--probe-running", action="store_true", help="test HTTPS through the running session's proxy")
    mode.add_argument("--stop-running", action="store_true", help="stop the desktop session in the dedicated guest")
    mode.add_argument("--smoke", action="store_true", help="test Claude with an empty temporary profile")
    parser.add_argument("--session-file", type=Path, help="publish the running session to a private local file")
    parser.add_argument("--expected-egress", action="append", type=guard.expected_egress, default=[],
                        help="expected public IP of the VPN, repeat for additional addresses")
    args = parser.parse_args()

    if sys.platform != "darwin" or os.uname().machine != "arm64":
        parser.error("requires an Apple Silicon Mac")
    if not (args.prepare or args.probe_running or args.stop_running or args.expected_egress):
        parser.error("--expected-egress is required outside VM provisioning")
    if args.session_file and (args.prepare or args.probe or args.probe_running or args.stop_running or args.smoke):
        parser.error("--session-file is only available for a desktop session")
    if not args.prepare and not SSH_CONFIG.is_file():
        parser.error("run --prepare first")
    try:
        if args.prepare:
            prepare_guest()
            return 0
        if args.probe_running:
            return probe_running_guest()
        if args.stop_running:
            remote = "exec sudo -n systemctl stop 'tunnelguard-desktop-*.service'"
            return subprocess.run(ssh_command(remote, "-o", "ConnectTimeout=4"), check=False, timeout=12).returncode
        guest_mode = "smoke" if args.smoke else "probe" if args.probe else "session"
        return run_guest(guest_mode, guard.EgressPolicy(args.expected_egress), args.session_file)
    except KeyboardInterrupt:
        return 130
    except (OSError, subprocess.SubprocessError) as error:
        print(f"TunnelGuard Desktop: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, signal.default_int_handler)
    sys.exit(main())
