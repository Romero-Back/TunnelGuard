#!/bin/sh
set -eu
umask 077
cd "$HOME"

mode=$1
mkdir -p "$HOME/.local/state/tunnelguard"
exec 9>"$HOME/.local/state/tunnelguard/session.lock"
if ! flock -n 9; then
    echo 'A TunnelGuard Desktop session is already running.' >&2
    exit 1
fi

session_dir=$(mktemp -d)
desktop_pid=
vnc_pid=
wm_pid=
cleanup() {
    for pid in "$desktop_pid" "$vnc_pid" "$wm_pid"; do
        [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
    done
    for pid in "$desktop_pid" "$vnc_pid" "$wm_pid"; do
        [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
    done
    if mountpoint -q "$session_dir/doc"; then
        fusermount3 -uz "$session_dir/doc"
    fi
    rm -rf -- "$session_dir"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

export XDG_RUNTIME_DIR="$session_dir"
export XDG_CURRENT_DESKTOP=Openbox XDG_SESSION_TYPE=x11
export BROWSER=/usr/bin/firefox-esr
export HTTPS_PROXY=http://127.0.0.1:3128 HTTP_PROXY=http://127.0.0.1:3128
export https_proxy="$HTTPS_PROXY" http_proxy="$HTTP_PROXY"
export NO_PROXY=127.0.0.1,localhost,::1 no_proxy=127.0.0.1,localhost,::1

if [ "$mode" = smoke ]; then
    export HOME="$session_dir/home"
    mkdir -m 700 "$HOME"
    cd "$HOME"
fi
dbus-update-activation-environment DISPLAY XAUTHORITY XDG_RUNTIME_DIR XDG_CURRENT_DESKTOP XDG_SESSION_TYPE HOME

openbox 9>&- >/dev/null 2>&1 &
wm_pid=$!

if [ "$mode" = smoke ]; then
    set -- "--user-data-dir=$session_dir/claude-profile"
else
    IFS= read -r vnc_password
    # x11vnc reads a plaintext password file. It only lives in this private temporary directory.
    printf '%s\n' "$vnc_password" >"$session_dir/vnc-password"
    unset vnc_password
    xdg-mime default firefox-esr.desktop x-scheme-handler/http x-scheme-handler/https
    x11vnc -listen 127.0.0.1 -localhost -rfbport 5900 -rfbportv6 -1 -forever \
        -passwdfile "$session_dir/vnc-password" -quiet 9>&- >/dev/null 2>&1 &
    vnc_pid=$!
    set --
fi

/usr/bin/claude-desktop --proxy-server="$HTTPS_PROXY" --disable-quic "$@" 9>&- >"$session_dir/claude.log" 2>&1 &
desktop_pid=$!

if [ "$#" -eq 0 ]; then
    wait "$desktop_pid"
    exit $?
fi

for _ in $(seq 1 20); do
    if ! kill -0 "$desktop_pid" 2>/dev/null; then
        break
    fi
    if xwininfo -root -tree 2>/dev/null | grep -q '"Claude"'; then
        # The application should have a real Chromium renderer with its own seccomp sandbox.
        for pid in $(pgrep -U "$(id -u)" -f -- '--type=renderer' || true); do
            if grep -Eq '^Seccomp:[[:space:]]+2$' "/proc/$pid/status" 2>/dev/null; then
                printf '%s\n' 'Claude Desktop window and sandboxed renderer verified.'
                exit 0
            fi
        done
    fi
    sleep 1
done
grep -iE 'sandbox|fatal|sigtrap|cannot open display|shared librar' "$session_dir/claude.log" | tail -10 >&2 || true
echo 'Claude Desktop did not produce a window with a sandboxed renderer.' >&2
exit 1
