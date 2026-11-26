"""Integration check for the isolated Claude Desktop guest. Keep host VPN connected."""

import argparse
import importlib.util
from pathlib import Path
import select
import subprocess
import threading
from unittest.mock import patch


entry = Path(__file__).resolve().parents[1] / "Scripts" / "tunnelguard-desktop.py"
spec = importlib.util.spec_from_file_location("desktop", entry)
desktop = importlib.util.module_from_spec(spec)
spec.loader.exec_module(desktop)
guard = desktop.guard

PROBE = "exec sudo -n /usr/local/libexec/tunnelguard-launch probe"
DIRECT_PROBE = """
import errno
import socket

cases = [
    ('IPv4 TCP', socket.AF_INET, socket.SOCK_STREAM, ('1.1.1.1', 443)),
    ('IPv6 TCP', socket.AF_INET6, socket.SOCK_STREAM, ('2606:4700:4700::1111', 443)),
    ('direct DNS', socket.AF_INET, socket.SOCK_DGRAM, ('1.1.1.1', 53)),
    ('UDP / QUIC', socket.AF_INET, socket.SOCK_DGRAM, ('1.1.1.1', 443)),
    ('host access', socket.AF_INET, socket.SOCK_STREAM, ('192.168.5.2', 22)),
]
for name, family, transport, destination in cases:
    with socket.socket(family, transport) as probe:
        probe.settimeout(2)
        try:
            probe.connect(destination)
        except OSError as error:
            assert error.errno in (errno.ENETUNREACH, errno.EHOSTUNREACH, errno.EACCES), (name, error)
            print(f'PASS: {name} blocked')
        else:
            raise AssertionError(f'{name} unexpectedly worked')
"""


def probe(expected):
    result = subprocess.run(desktop.ssh_command(PROBE), capture_output=True, text=True, timeout=30)
    assert result.returncode == expected, (result.returncode, result.stderr.strip())


def test_direct():
    subprocess.run(desktop.ssh_command("exec sudo -n -u tunnelguard-app /usr/bin/python3 -"),
                   input=DIRECT_PROBE, text=True, check=True, timeout=15)


def test_guest_egress(policy):
    real_interface = guard.v2pro_interface
    failure = threading.Event()

    def lookup():
        if failure.is_set():
            raise OSError("Simulated loss in the dedicated test proxy")
        return real_interface()

    forward = None
    try:
        with patch.object(guard, "v2pro_interface", lookup), guard.proxy_server(policy) as server:
            remote = "printf 'bridge-ready\\n'; exec sleep 120"
            forward = subprocess.Popen(desktop.ssh_command(
                remote, "-o", "ExitOnForwardFailure=yes", "-R", f"{desktop.GUEST_PROXY}:127.0.0.1:{server.server_port}"
            ), stdout=subprocess.PIPE)
            assert select.select([forward.stdout], [], [], 8)[0], "SSH forward timed out"
            assert forward.stdout.readline().strip() == b"bridge-ready"
            probe(0)
            print("PASS: VM HTTPS via V2Pro", flush=True)
            test_direct()
            failure.set()
            probe(22)
            print("PASS: simulated loss of V2Pro rejects guest traffic", flush=True)
            failure.clear()
            probe(0)
            print("PASS: simulated recovery restores guest traffic", flush=True)

        probe(56)
        test_direct()
        print("PASS: dismantling the host proxy leaves the guest isolated", flush=True)
    finally:
        if forward is not None:
            if forward.poll() is None:
                forward.terminate()
            forward.wait(timeout=5)
            forward.stdout.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected-egress", action="append", required=True, type=guard.expected_egress)
    args = parser.parse_args()

    before = guard.v2pro_interface()
    desktop.start_guest()
    policy = guard.EgressPolicy(args.expected_egress)
    test_guest_egress(policy)
    assert desktop.run_guest("smoke", policy) == 0
    assert guard.v2pro_interface() == before
    print("PASS: Claude Desktop starts with its renderer sandbox, and V2Pro remained connected")


if __name__ == "__main__":
    main()
