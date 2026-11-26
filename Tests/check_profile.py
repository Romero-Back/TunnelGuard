import argparse
import json
import subprocess
import tempfile
from pathlib import Path


REFERENCE = {
    "inbounds": [{"type": "tun", "auto_route": True, "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"]}],
    "outbounds": [{"type": "vless", "tag": "vpn", "server": "192.0.2.2"}],
    "route": {"final": "vpn", "rules": [{"action": "sniff"}, {"protocol": "dns", "action": "hijack-dns"}]},
    "dns": {"final": "tunneled", "servers": [{"type": "https", "tag": "tunneled", "server": "2001:db8::2", "detour": "vpn"}]},
}

CASES = {
    "reference profile": {},
    "extra direct outbound": {"outbounds": REFERENCE["outbounds"] + [{"type": "direct", "tag": "direct"}]},
    "split routing": {"route": {"final": "vpn", "rules": [{"action": "bypass"}]}},
    "tunnel exclusions": {
        "inbounds": [{**REFERENCE["inbounds"][0], "route_exclude_address": ["0.0.0.0/0"]}],
    },
    "DNS without VLESS detour": {
        "dns": {"final": "tunneled", "servers": [{"type": "https", "tag": "tunneled", "server": "192.0.2.4"}]},
    },
    "numeric auto_route": {"inbounds": [{**REFERENCE["inbounds"][0], "auto_route": 1}]},
    "VPN hostname requiring bootstrap DNS": {"outbounds": [{**REFERENCE["outbounds"][0], "server": "vpn.example"}]},
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("checker", type=Path)
    checker = parser.parse_args().checker.resolve()

    with tempfile.TemporaryDirectory() as directory:
        profile = Path(directory) / "profile.json"
        for name, changes in CASES.items():
            profile.write_text(json.dumps({**REFERENCE, **changes}), encoding="utf-8")
            result = subprocess.run([checker, profile], capture_output=True, text=True, timeout=5)
            expected = 65 if changes else 0
            if result.returncode != expected:
                raise SystemExit(f"{name}: expected {expected}, got {result.returncode}\n{result.stderr}")
            print(f"PASS: {name}")


if __name__ == "__main__":
    main()
