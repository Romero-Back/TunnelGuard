#!/bin/sh
set -eu

if [ "$(id -u)" != 0 ] || [ "$(hostname -s)" != lima-tunnelguard-desktop ] || \
   [ ! -f /etc/tunnelguard/desktop-provisioned ]; then
    echo 'The dedicated TunnelGuard guest is not ready.' >&2
    exit 1
fi

# Reload atomically and bring down every non-loopback interface before the app starts.
/usr/local/libexec/tunnelguard-isolate
if [ -n "$(ip -o link show up | awk -F ': ' '$2 != "lo" { print $2 }')" ]; then
    echo 'An IP network interface is still active.' >&2
    exit 1
fi

case "${1:-}" in
    probe)
        exec runuser -u tunnelguard-app -- /usr/bin/curl --proxy http://127.0.0.1:3128 \
            --noproxy '' --fail --silent --show-error --max-time 20 --head --output /dev/null https://example.com/
        ;;
    smoke|session)
        mode=$1
        unit=${2:-}
        set -- /usr/bin/env -i \
            HOME=/home/tunnelguard-app USER=tunnelguard-app LOGNAME=tunnelguard-app \
            PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
            xvfb-run -a -s '-screen 0 1280x800x24 -nolisten tcp' \
            dbus-run-session -- /usr/local/libexec/tunnelguard-session "$mode"
        if [ "$mode" = smoke ]; then
            exec runuser -u tunnelguard-app -- "$@"
        fi
        case "$unit" in
            *[!a-z0-9-]*|tunnelguard-desktop-) exit 64 ;;
            tunnelguard-desktop-*) ;;
            *) exit 64 ;;
        esac
        exec systemd-run --unit="$unit" --uid=tunnelguard-app --property=TimeoutStopSec=5 \
            --quiet --wait --collect --pipe "$@"
        ;;
    *) exit 64 ;;
esac
