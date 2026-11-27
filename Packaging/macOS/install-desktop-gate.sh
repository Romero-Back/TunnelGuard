#!/bin/sh
set -eu
umask 077

action=$1
account=$2
root='/private/var/db/tunnelguard-desktop'
group=tunnelguard_desktop
rule=/private/etc/sudoers.d/tunnelguard-desktop
app=/Applications/Claude.app
entry="$root/Claude.app"
backup="$root/Original/Claude.app"

test "$(/usr/bin/id -u)" = 0
test "$(/usr/bin/stat -f '%Su' /dev/console)" = "$account"
test "$(/usr/bin/id -u "$account")" -ge 501
case "$account" in ''|*[!a-zA-Z0-9._-]*|-*) exit 1;; esac
if /bin/ps -axo comm= | /usr/bin/grep -Fxq -e "$app/Contents/MacOS/Claude" -e "$entry/Contents/MacOS/Claude"; then
    echo "Quit Claude before changing its launch permissions." >&2
    exit 1
fi

case "$action" in
    disable)
        test -d "$backup"
        test ! -L "$root"
        test "$(/usr/bin/stat -f '%u' "$root")" = 0
        if [ -L "$app" ]; then
            test "$(/usr/bin/readlink "$app")" = "$entry"
            /bin/unlink "$app"
        else
            test ! -e "$app"
        fi
        if ! /bin/mv -n "$backup" "$app" || [ -e "$backup" ]; then
            [ -e "$app" ] || /bin/ln -s "$entry" "$app"
            exit 1
        fi
        [ ! -f "$rule" ] || /bin/unlink "$rule"
        /bin/rm -rf "$root"
        /usr/sbin/dseditgroup -o delete "$group"
        ;;
    enable)
        resources=$3
        test -d "$app"
        test ! -L "$app"
        test ! -e "$root" && test ! -L "$root"
        test ! -e "$rule" && test ! -L "$rule"
        test -d /private/etc/sudoers.d
        /usr/bin/dscl . -read /Groups/tunnelguard_claude PrimaryGroupID >/dev/null
        if /usr/bin/dscl . -read "/Groups/$group" >/dev/null 2>&1; then exit 1; fi
        requirement='identifier "com.anthropic.claudefordesktop" and anchor apple generic and certificate leaf[subject.OU] = "Q6L2SF6YDW"'
        /usr/bin/codesign --verify --deep --strict -R "=$requirement" "$app"
        /usr/bin/codesign --verify --strict "$resources/tunnelguard-desktop-gate"
        /usr/bin/codesign --verify --strict "$resources/NativeLauncher/tunnelguard-native"
        test "$(/usr/bin/stat -f %d "$app")" = "$(/usr/bin/stat -f %d '/private/var/db')"
        stage=$(/usr/bin/mktemp -d '/private/var/db/.tunnelguard-gate.XXXXXX')
        group_created=no
        root_created=no
        rule_created=no
        linked=no
        rollback() {
            if [ "$linked" = yes ]; then /bin/unlink "$app" || true; fi
            if [ -d "$backup" ]; then
                /bin/mv -n "$backup" "$app" || true
                # Preserve the original if a concurrent installation filled its old path.
                if [ -d "$backup" ]; then return; fi
            fi
            if [ "$rule_created" = yes ]; then /bin/unlink "$rule" || true; fi
            if [ "$root_created" = yes ]; then /bin/rm -rf "$root"; fi
            if [ "$group_created" = yes ]; then /usr/sbin/dseditgroup -o delete "$group"; fi
            /bin/rm -rf "$stage"
        }
        trap rollback EXIT
        /usr/sbin/dseditgroup -o create "$group"
        group_created=yes
        /usr/bin/install -m 755 -o root -g wheel "$resources/tunnelguard-desktop-gate" "$stage/launch"
        /usr/bin/ditto --noacl "$resources/NativeLauncher" "$stage/NativeLauncher"
        /usr/bin/ditto --noacl "$app" "$stage/Claude.app"
        /usr/sbin/chown -hRP root:wheel "$stage/NativeLauncher" "$stage/Claude.app"
        /bin/chmod -R go-w "$stage/NativeLauncher" "$stage/Claude.app"
        /usr/bin/codesign --verify --deep --strict -R "=$requirement" "$stage/Claude.app"
        /usr/bin/codesign --verify --strict "$stage/NativeLauncher/tunnelguard-native"
        /usr/sbin/chown root:"$group" "$stage/Claude.app"
        /bin/chmod 0750 "$stage/Claude.app"
        /bin/mkdir -m 0700 "$stage/Original"
        # Permit the fixed executable with zero arguments.
        command_path='/private/var/db/tunnelguard-desktop/launch'
        printf 'Defaults!%s !use_pty\n%s ALL=(root) NOPASSWD: NOSETENV: %s ""\n' \
            "$command_path" "$account" "$command_path" > "$stage/sudoers"
        /usr/sbin/visudo -cf "$stage/sudoers"
        /bin/mv "$stage" "$root"
        root_created=yes
        /bin/chmod 0755 "$root"
        /usr/bin/install -m 0440 -o root -g wheel "$root/sudoers" "$rule"
        rule_created=yes
        /usr/sbin/visudo -c
        /bin/unlink "$root/sudoers"
        /bin/mv "$app" "$backup"
        /bin/ln -s "$entry" "$app"
        linked=yes
        trap - EXIT
        ;;
    *) exit 1;;
esac
