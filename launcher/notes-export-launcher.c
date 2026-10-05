// notes-export-launcher: a tiny compiled front end for run_combined_export.sh.
//
// WHY THIS EXISTS
// macOS privacy controls (TCC) decide Full Disk Access by the "responsible
// process". For a launchd job, that is the program launchd started. When that
// program is a shell script, the program actually running is the interpreter
// (/bin/bash), so a Full Disk Access grant on the script file is never
// consulted, and a grant on /bin/bash would cover every bash script on the
// machine. A compiled binary that launchd starts directly IS the responsible
// process for everything it spawns, so Full Disk Access granted to this one
// binary covers the script's sqlite3/cp of the Notes database - and does not
// depend on Terminal.app, AppleScript, or whether the screen is locked.
//
// It must spawn-and-wait, NOT exec(). exec() would replace this binary's code
// with /bin/bash inside the same process, and TCC would then see bash again.
//
// The script path comes from the password database, not $HOME, so the
// environment cannot point this binary at some other script.
//
// Build/sign with launcher/build.sh. Rebuilding changes the binary's code
// signature, which invalidates the Full Disk Access grant: re-grant after.

#include <errno.h>
#include <limits.h>
#include <pwd.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

int main(void) {
    struct passwd *pw = getpwuid(getuid());
    if (pw == NULL || pw->pw_dir == NULL || pw->pw_dir[0] == '\0') {
        fprintf(stderr, "notes-export-launcher: cannot determine home directory\n");
        return 1;
    }

    char script[PATH_MAX];
    int n = snprintf(script, sizeof script, "%s/NotesIndex/run_combined_export.sh", pw->pw_dir);
    if (n < 0 || (size_t)n >= sizeof script) {
        fprintf(stderr, "notes-export-launcher: script path too long\n");
        return 1;
    }

    char *const child_argv[] = { "/bin/bash", script, NULL };
    pid_t pid;
    int rc = posix_spawn(&pid, "/bin/bash", NULL, NULL, child_argv, environ);
    if (rc != 0) {
        fprintf(stderr, "notes-export-launcher: posix_spawn failed: %s\n", strerror(rc));
        return 1;
    }

    int status;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) {
            perror("notes-export-launcher: waitpid");
            return 1;
        }
    }
    if (WIFEXITED(status))   return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 1;
}
