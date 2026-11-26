#!/bin/sh
set -eu

account=$1
definition=$2
group=tunnelguard_claude
label=app.tunnelguard.native-filter
target="/Library/LaunchDaemons/$label.plist"

test "$(/usr/bin/id -u)" = 0
test "$(/usr/bin/stat -f '%Su' /dev/console)" = "$account"
test "$(/usr/bin/id -u "$account")" -ge 501
/sbin/pfctl -s rules 2>/dev/null | /usr/bin/grep -Fxq 'anchor "com.apple/*" all'

created=no
added=no
installed=no
temp=$(/usr/bin/mktemp "$target.XXXXXX")
cleanup() {
    /bin/unlink "$temp" 2>/dev/null || true
    if [ "$installed" = yes ]; then
        /bin/unlink "$target"
    fi
    if [ "$created" = yes ]; then
        /usr/sbin/dseditgroup -o delete "$group"
    elif [ "$added" = yes ]; then
        /usr/sbin/dseditgroup -o edit -d "$account" -t user "$group"
    fi
}
trap 'cleanup' EXIT

if ! /usr/bin/dscl . -read "/Groups/$group" >/dev/null 2>&1; then
    /usr/sbin/dseditgroup -o create "$group"
    created=yes
fi
if ! /usr/bin/dsmemberutil checkmembership -U "$account" -G "$group" | /usr/bin/grep -Fxq 'user is a member of the group'; then
    /usr/sbin/dseditgroup -o edit -a "$account" -t user "$group"
    added=yes
fi

if [ ! -e "$target" ]; then
    printf '%s' "$definition" | /usr/bin/base64 -D > "$temp"
    /usr/bin/plutil -lint "$temp" >/dev/null
    /usr/sbin/chown root:wheel "$temp"
    /bin/chmod 644 "$temp"
    /bin/mv "$temp" "$target"
    installed=yes
fi
if ! /bin/launchctl print "system/$label" >/dev/null 2>&1; then
    /bin/launchctl bootstrap system "$target"
fi
/bin/unlink "$temp" 2>/dev/null || true
trap - EXIT
