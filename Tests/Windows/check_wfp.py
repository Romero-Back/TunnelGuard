"""Exercise kernel enforcement with a disposable executable on a Windows runner."""

import ctypes
from ctypes import wintypes
from pathlib import Path
import socket
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Windows"))
from tunnelguard_windows import Firewall


def test(dll, probe):
    wfp = Firewall(dll)
    permit = wintypes.HANDLE()

    def connect(port):
        return subprocess.run([str(probe), str(port)], timeout=5).returncode

    with socket.socket() as local, socket.socket() as other:
        for listener in (local, other):
            listener.bind(("127.0.0.1", 0))
            listener.listen(16)
        allowed = local.getsockname()[1]
        denied = other.getsockname()[1]
        assert connect(allowed) == 0 and connect(denied) == 0, "baseline TCP failed"
        wfp.require(wfp.lock(str(probe)), "apply persistent blocks")
        try:
            wfp.require(wfp.status(str(probe)), "verify persistent blocks")
            assert connect(allowed) == 1 and connect(denied) == 1, "persistent block did not apply"
            wfp.require(wfp.allow(str(probe), allowed, ctypes.byref(permit)), "add narrow proxy permit")
            assert connect(allowed) == 0 and connect(denied) == 1, "proxy permit was not scoped to one port"
            wfp.require(wfp.close(permit), "release proxy permit")
            permit = wintypes.HANDLE()
            assert connect(allowed) == 1, "closing the WFP session did not restore blocking"
            killer = subprocess.Popen([sys.executable, __file__, str(dll), str(probe), str(allowed)],
                                      stdout=subprocess.PIPE, text=True)
            try:
                assert killer.stdout.readline().strip() == "ready", "crash test could not add permit"
                assert connect(allowed) == 0, "child permit failed"
            finally:
                killer.kill()
                killer.wait(timeout=8)
            assert connect(allowed) == 1, "permit survived process termination"
        finally:
            if permit:
                wfp.close(permit)
            wfp.require(wfp.unlock(), "remove test filters")
        assert connect(allowed) == 0, "test rollback failed"
    print("PASS: actual WFP blocks, exact loopback permit, crash, and rollback")


if __name__ == "__main__":
    dll, probe = map(lambda value: Path(value).resolve(strict=True), sys.argv[1:3])
    if len(sys.argv) == 4:
        firewall = Firewall(dll)
        permit = wintypes.HANDLE()
        firewall.require(firewall.allow(str(probe), int(sys.argv[3]), ctypes.byref(permit)), "child permit")
        print("ready", flush=True)
        time.sleep(30)
    else:
        test(dll, probe)
