// sudoers permits this fixed command without arguments. The Python launcher
// starts only after root privileges are dropped.
#include <errno.h>
#include <grp.h>
#include <limits.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef GATE_DIRECTORY
#define GATE_DIRECTORY "/private/var/db/tunnelguard-desktop"
#endif
#ifndef GATE_GROUP
#define GATE_GROUP "tunnelguard_desktop"
#endif
#ifndef CLAUDE_LINK
#define CLAUDE_LINK "/Applications/Claude.app"
#endif

static int refuse(void) {
    fputs("TunnelGuard: could not enter the restricted Claude launch context\n", stderr);
    return 77;
}

int main(int argc, char **argv) {
    (void)argv;
    if (argc != 1 || getuid() != 0 || geteuid() != 0) return refuse();

    const char expected[] = GATE_DIRECTORY "/Claude.app";
    char target[sizeof expected];
    ssize_t length = readlink(CLAUDE_LINK, target, sizeof target);
    if (length != (ssize_t)(sizeof expected - 1) || memcmp(target, expected, sizeof expected - 1)) return refuse();

    const char *rawUID = getenv("SUDO_UID");
    char *end = NULL;
    if (!rawUID || !*rawUID) return refuse();
    errno = 0;
    unsigned long number = strtoul(rawUID, &end, 10);
    if (errno || *end || number < 501 || number >= UINT_MAX) return refuse();
    uid_t user = (uid_t)number;

    struct passwd *account = getpwuid(user);
    if (!account || account->pw_dir[0] != '/') return refuse();
    char *home = NULL, *name = NULL;
    if (asprintf(&home, "HOME=%s", account->pw_dir) < 0 ||
        asprintf(&name, "USER=%s", account->pw_name) < 0) return refuse();

    struct group *filter = getgrnam("tunnelguard_claude");
    if (!filter || filter->gr_gid == 0) return refuse();
    gid_t filterGroup = filter->gr_gid;
    struct group *restricted = getgrnam(GATE_GROUP);
    if (!restricted || restricted->gr_gid == 0 || restricted->gr_gid == filterGroup) return refuse();
    gid_t groups[] = {filterGroup, restricted->gr_gid};

    if (chdir("/") || setgid(filterGroup) || setgroups(2, groups) || setuid(user) ||
        getuid() != user || geteuid() != user || getegid() != filterGroup) return refuse();

    char *const environment[] = {home, name, "PATH=/usr/bin:/bin:/usr/sbin:/sbin", NULL};
    char *const command[] = {GATE_DIRECTORY "/NativeLauncher/tunnelguard-native", "--gated-request", NULL};
    execve(command[0], command, environment);
    return refuse();
}
