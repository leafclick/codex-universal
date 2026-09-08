#define _GNU_SOURCE

#include <errno.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/sched.h>
#include <linux/seccomp.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

#if defined(__x86_64__)
#define CODEX_AUDIT_ARCH AUDIT_ARCH_X86_64
#elif defined(__aarch64__)
#define CODEX_AUDIT_ARCH AUDIT_ARCH_AARCH64
#else
#error "Unsupported architecture for the nested-userns filter"
#endif

#define DENY_ERRNO(value) (SECCOMP_RET_ERRNO | ((value) & SECCOMP_RET_DATA))

static int install_filter(void) {
    struct sock_filter instructions[] = {
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
                 offsetof(struct seccomp_data, arch)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, CODEX_AUDIT_ARCH, 1, 0),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS),
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
                 offsetof(struct seccomp_data, nr)),
#ifdef SYS_clone3
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SYS_clone3, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, DENY_ERRNO(ENOSYS)),
#endif
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SYS_clone, 0, 5),
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
                 offsetof(struct seccomp_data, args[0])),
        BPF_STMT(BPF_ALU | BPF_AND | BPF_K, CLONE_NEWUSER),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 0, 1, 0),
        BPF_STMT(BPF_RET | BPF_K, DENY_ERRNO(EPERM)),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SYS_unshare, 0, 5),
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
                 offsetof(struct seccomp_data, args[0])),
        BPF_STMT(BPF_ALU | BPF_AND | BPF_K, CLONE_NEWUSER),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 0, 1, 0),
        BPF_STMT(BPF_RET | BPF_K, DENY_ERRNO(EPERM)),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
    };
    struct sock_fprog program = {
        .len = (unsigned short)(sizeof(instructions) / sizeof(instructions[0])),
        .filter = instructions,
    };

    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) == -1) {
        return -1;
    }
    return prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: codex-no-nested-userns COMMAND [ARG ...]\n");
        return 2;
    }
    if (install_filter() == -1) {
        perror("install nested-userns seccomp filter");
        return 126;
    }
    execvp(argv[1], &argv[1]);
    perror("execute filtered command");
    return 127;
}
