#!/bin/sh
# TunnelGuard VPN profile v1
set -eu

profile=$1
test "$(/usr/bin/id -u)" = 0
anchor=com.apple/app.tunnelguard.claude
token_file=/var/run/tunnelguard-claude.pf-token
gid=$(/usr/bin/dscl . -read /Groups/tunnelguard_claude PrimaryGroupID | /usr/bin/awk '{print $2}')
case "$gid" in ''|*[!0-9]*) exit 1;; esac

# Amend only the child ruleset. Never reload the system's root ruleset.
/sbin/pfctl -s rules 2>/dev/null | /usr/bin/grep -Fxq 'anchor "com.apple/*" all'
interfaces=$(/sbin/ifconfig -v) || interfaces=
iface=$(printf '%s\n' "$interfaces" | TUNNELGUARD_VPN_PROFILE="$profile" /usr/bin/awk '
    /^$/ || /^[^ \t]/ { name="" }
    /^utun[0-9][0-9]?[0-9]?: flags=[0-9a-f]+<UP[,>]/ { name=$1; sub(/:$/, "", name) }
    name != "" && /^[ \t]+agent domain:NetworkExtension type:VPN([ \t]|$)/ {
        if (match($0, /[ \t]desc:"VPN: [^"]*"([ \t]|$)/)) {
            label=substr($0, RSTART+12, RLENGTH-12)
            sub(/"[ \t]?$/, "", label)
            if (!((name SUBSEP label) in seen)) {
                seen[name,label]=1
                labels[name]++
                if (label == ENVIRON["TUNNELGUARD_VPN_PROFILE"]) {
                    chosen=name
                    matches++
                }
            }
        }
    }
    END { if (matches == 1 && labels[chosen] == 1) print chosen }
')

rules() {
    case "$iface" in
        utun[0-9]|utun[0-9][0-9]|utun[0-9][0-9][0-9])
            printf 'pass out quick on %s inet proto { tcp, udp } all group = %s no state\n' "$iface" "$gid"
            ;;
    esac
    printf 'block drop out quick proto { tcp, udp } all group = %s\n' "$gid"
}

desired=$(rules | /sbin/pfctl -n -v -a "$anchor" -f - 2>/dev/null)
test -n "$desired"
if [ "$desired" != "$(/sbin/pfctl -a "$anchor" -s rules 2>/dev/null)" ]; then
    rules | /sbin/pfctl -a "$anchor" -f - >/dev/null 2>&1
fi

if [ ! -s "$token_file" ] || ! /sbin/pfctl -s info 2>/dev/null | /usr/bin/grep -q '^Status: Enabled'; then
    enabled=$(/sbin/pfctl -E 2>&1)
    token=$(printf '%s\n' "$enabled" | /usr/bin/sed -nE 's/.*Token[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p')
    case "$token" in ''|*[!0-9]*) exit 1;; esac
    umask 077
    printf '%s\n' "$token" > "$token_file"
fi
