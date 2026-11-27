#!/bin/sh
set -eu

account=$1
definition=$2
resources=$3
group=tunnelguard_claude
label=app.tunnelguard.native-filter
target="/Library/LaunchDaemons/$label.plist"
gate=/private/var/db/tunnelguard-desktop
anchor=com.apple/app.tunnelguard.claude

test "$(/usr/bin/id -u)" = 0
test "$(/usr/bin/stat -f '%Su' /dev/console)" = "$account"
test "$(/usr/bin/id -u "$account")" -ge 501
/sbin/pfctl -s rules 2>/dev/null | /usr/bin/grep -Fxq 'anchor "com.apple/*" all'

created=no
added=no
installed=no
stopped=no
stage=$(/usr/bin/mktemp -d "$target.XXXXXX")
launcher_stage=
cleanup() {
    set +e
    if [ "$installed" = yes ]; then
        /bin/launchctl bootout "system/$label" 2>/dev/null
        if [ -f "$stage/previous" ]; then
            /bin/mv -f "$stage/previous" "$target" || return
        else
            /bin/unlink "$target"
        fi
    fi
    if [ -n "$launcher_stage" ] && [ -d "$launcher_stage/previous" ]; then
        /bin/rm -rf "$gate/NativeLauncher"
        /bin/mv "$launcher_stage/previous" "$gate/NativeLauncher" || return
    fi
    if [ "$stopped" = yes ]; then
        /bin/launchctl bootstrap system "$target"
    fi
    if [ "$created" = yes ]; then
        /usr/sbin/dseditgroup -o delete "$group"
    elif [ "$added" = yes ]; then
        /usr/sbin/dseditgroup -o edit -d "$account" -t user "$group"
    fi
    /bin/rm -rf "$stage"
    if [ -n "$launcher_stage" ]; then /bin/rm -rf "$launcher_stage"; fi
}
trap 'cleanup' EXIT

test ! -L "$target"
printf '%s' "$definition" | /usr/bin/base64 -D > "$stage/new"
/usr/bin/plutil -lint "$stage/new" >/dev/null
/usr/sbin/chown root:wheel "$stage/new"
/bin/chmod 644 "$stage/new"

if ! /usr/bin/dscl . -read "/Groups/$group" >/dev/null 2>&1; then
    /usr/sbin/dseditgroup -o create "$group"
    created=yes
fi
if ! /usr/bin/dsmemberutil checkmembership -U "$account" -G "$group" | /usr/bin/grep -Fxq 'user is a member of the group'; then
    /usr/sbin/dseditgroup -o edit -a "$account" -t user "$group"
    added=yes
fi

if ! /usr/bin/cmp -s "$stage/new" "$target"; then
    if /bin/ps -axo comm= | /usr/bin/grep -Fxq \
        -e /Applications/Claude.app/Contents/MacOS/Claude -e "$gate/Claude.app/Contents/MacOS/Claude"; then
        echo "Quit Claude before switching the VPN." >&2
        exit 1
    fi

    if [ -e "$gate" ] || [ -L "$gate" ]; then
        test ! -L "$gate"
        test "$(/usr/bin/stat -f '%u:%Lp' "$gate")" = 0:755
        test ! -L "$gate/NativeLauncher"
        test -d "$gate/NativeLauncher"
        launcher_stage=$(/usr/bin/mktemp -d "$gate/.native.XXXXXX")
        /usr/bin/ditto --noacl "$resources/NativeLauncher" "$launcher_stage/new"
        /usr/sbin/chown -hRP root:wheel "$launcher_stage/new"
        /bin/chmod -R go-w "$launcher_stage/new"
        /usr/bin/codesign --verify --strict "$launcher_stage/new/tunnelguard-native"
    fi

    if [ -f "$target" ]; then
        /bin/cp -p "$target" "$stage/previous"
    fi
    if /bin/launchctl print "system/$label" >/dev/null 2>&1; then
        /bin/launchctl bootout "system/$label"
        stopped=yes
    fi
    # Keep the existing PF reference active and deny Claude during the switch.
    gid=$(/usr/bin/dscl . -read "/Groups/$group" PrimaryGroupID | /usr/bin/awk '{print $2}')
    case "$gid" in ''|*[!0-9]*) exit 1;; esac
    printf 'block drop out quick proto { tcp, udp } all group = %s\n' "$gid" > "$stage/block"
    /sbin/pfctl -n -a "$anchor" -f "$stage/block" >/dev/null 2>&1
    /sbin/pfctl -a "$anchor" -f "$stage/block" >/dev/null 2>&1
    if [ -n "$launcher_stage" ]; then
        /bin/mv "$gate/NativeLauncher" "$launcher_stage/previous"
        /bin/mv "$launcher_stage/new" "$gate/NativeLauncher"
    fi
    /bin/mv -f "$stage/new" "$target"
    installed=yes
fi
if ! /bin/launchctl print "system/$label" >/dev/null 2>&1; then
    /bin/launchctl bootstrap system "$target"
fi
trap - EXIT
/bin/rm -rf "$stage"
if [ -n "$launcher_stage" ]; then /bin/rm -rf "$launcher_stage"; fi
