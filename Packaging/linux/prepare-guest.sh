#!/bin/sh
set -eu

if [ "$(id -u)" != 0 ] || [ "$(hostname -s)" != lima-tunnelguard-desktop ]; then
    echo 'Run this script as root inside the dedicated TunnelGuard Lima guest.' >&2
    exit 1
fi

install -d -m 755 /etc/tunnelguard /usr/local/libexec
if [ ! -e /etc/tunnelguard/desktop-provisioned ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q
    apt-get install -y --no-install-recommends ca-certificates curl gpg nftables \
        dbus-x11 xauth xvfb x11-utils x11vnc openbox firefox-esr gnome-keyring \
        fonts-dejavu-core python3

    signing_key=$(mktemp)
    trap 'rm -f "$signing_key"' EXIT
    curl --fail --silent --show-error --connect-timeout 10 --max-time 60 \
        https://downloads.claude.ai/claude-desktop/key.asc -o "$signing_key"
    fingerprint=$(gpg --batch --show-keys --with-colons "$signing_key" 2>/dev/null \
        | awk -F: '$1 == "fpr" { print $10; exit }')
    if [ "$fingerprint" != 31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE ]; then
        echo 'The Claude Desktop repository key fingerprint does not match.' >&2
        exit 1
    fi
    install -m 644 "$signing_key" /usr/share/keyrings/claude-desktop-archive-keyring.asc
    printf '%s\n' 'deb [signed-by=/usr/share/keyrings/claude-desktop-archive-keyring.asc] https://downloads.claude.ai/claude-desktop/apt/stable stable main' \
        >/etc/apt/sources.list.d/claude-desktop.list
    apt-get update -q
    apt-get install -y --no-install-recommends claude-desktop
    if ! id tunnelguard-app >/dev/null 2>&1; then
        useradd --create-home --shell /bin/bash tunnelguard-app
    fi
fi

install -d -m 755 /etc/firefox/policies
cat >/etc/firefox/policies/policies.json <<'EOF'
{
  "policies": {
    "Proxy": {
      "Mode": "manual",
      "HTTPProxy": "127.0.0.1:3128",
      "UseHTTPProxyForAllProtocols": true,
      "Locked": true
    },
    "DNSOverHTTPS": { "Enabled": false, "Locked": true },
    "DisableTelemetry": true
  }
}
EOF

cat >/etc/tunnelguard/egress.nft <<'EOF'
destroy table inet tunnelguard_desktop
table inet tunnelguard_desktop {
    chain input {
        type filter hook input priority -10; policy drop;
        iifname "lo" accept
        # Lima checks its private SSH port before enabling SSH over vsock.
        ip saddr 192.168.5.2 udp sport 67 udp dport 68 accept
        ip saddr { 192.168.5.1, 192.168.5.2 } tcp dport 22 ct state { new, established } accept
    }
    chain output {
        type filter hook output priority -10; policy drop;
        oifname "lo" accept
        ip daddr { 192.168.5.2, 255.255.255.255 } udp sport 68 udp dport 67 accept
        ip daddr { 192.168.5.1, 192.168.5.2 } tcp sport 22 ct direction reply ct state established accept
        counter drop
    }
    chain forward {
        type filter hook forward priority -10; policy drop;
    }
}
EOF

cat >/usr/local/libexec/tunnelguard-isolate <<'EOF'
#!/bin/sh
set -eu
/usr/sbin/nft -f /etc/tunnelguard/egress.nft
systemctl stop systemd-networkd.socket systemd-networkd.service
for link in /sys/class/net/*; do
    name=${link##*/}
    if [ "$name" != lo ]; then
        /usr/sbin/ip link set dev "$name" down
    fi
done
EOF
chmod 755 /usr/local/libexec/tunnelguard-isolate

cat >/etc/systemd/system/tunnelguard-firewall.service <<'EOF'
[Unit]
Description=TunnelGuard loopback-only guest firewall
DefaultDependencies=no
After=local-fs.target
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/nft -f /etc/tunnelguard/egress.nft
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
EOF

systemctl daemon-reload
systemctl enable tunnelguard-firewall.service
systemctl restart tunnelguard-firewall.service
touch /etc/tunnelguard/desktop-provisioned
