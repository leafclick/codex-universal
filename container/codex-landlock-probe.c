#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <linux/landlock.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

static int landlock_create_ruleset(const struct landlock_ruleset_attr *attr,
                                   size_t size, unsigned int flags) {
    return (int)syscall(SYS_landlock_create_ruleset, attr, size, flags);
}

static int landlock_restrict_self(int ruleset_fd, unsigned int flags) {
    return (int)syscall(SYS_landlock_restrict_self, ruleset_fd, flags);
}

int main(void) {
    char path[] = "/tmp/codex-landlock-probe.XXXXXX";
    struct landlock_ruleset_attr ruleset = {
        .handled_access_fs = LANDLOCK_ACCESS_FS_WRITE_FILE,
    };
    int abi;
    int file_fd;
    int ruleset_fd;

    abi = landlock_create_ruleset(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION);
    if (abi < 1) {
        perror("query Landlock ABI");
        return 1;
    }

    file_fd = mkstemp(path);
    if (file_fd == -1) {
        perror("create Landlock probe file");
        return 1;
    }
    if (close(file_fd) == -1) {
        perror("close Landlock probe file");
        return 1;
    }

    ruleset_fd = landlock_create_ruleset(&ruleset, sizeof(ruleset), 0);
    if (ruleset_fd == -1) {
        perror("create Landlock ruleset");
        return 1;
    }
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) == -1) {
        perror("enable no-new-privileges for Landlock");
        return 1;
    }
    if (landlock_restrict_self(ruleset_fd, 0) == -1) {
        perror("enforce Landlock ruleset");
        return 1;
    }
    if (close(ruleset_fd) == -1) {
        perror("close Landlock ruleset");
        return 1;
    }

    errno = 0;
    file_fd = open(path, O_WRONLY | O_CLOEXEC);
    if (file_fd != -1) {
        close(file_fd);
        fprintf(stderr, "Landlock did not deny a handled write\n");
        return 1;
    }
    if (errno != EACCES) {
        perror("verify Landlock write denial");
        return 1;
    }

    if (unlink(path) == -1) {
        perror("remove Landlock probe file");
        return 1;
    }
    printf("Landlock ABI %d enforced a handled write denial\n", abi);
    return 0;
}
