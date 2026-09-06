// SPDX-License-Identifier: MIT

#define _GNU_SOURCE

#include <errno.h>
#include <grp.h>
#include <nss.h>
#include <pwd.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define CODEX_NAME "codex"
#define CODEX_PASSWD "x"
#define CODEX_GECOS "Codex runtime user"
#define CODEX_DEFAULT_HOME "/home/codex"
#define CODEX_SHELL "/bin/bash"

static enum nss_status
buffer_string(const char *value, char **cursor, size_t *remaining, char **result,
              int *errnop)
{
    size_t length = strlen(value) + 1;

    if (length > *remaining) {
        *errnop = ERANGE;
        return NSS_STATUS_TRYAGAIN;
    }
    memcpy(*cursor, value, length);
    *result = *cursor;
    *cursor += length;
    *remaining -= length;
    return NSS_STATUS_SUCCESS;
}

static const char *
runtime_home(void)
{
    const char *home = getenv("HOME");

    if (home == NULL || home[0] != '/' || home[1] == '\0' ||
        strchr(home, ':') != NULL || strchr(home, '\n') != NULL) {
        return CODEX_DEFAULT_HOME;
    }
    return home;
}

static int
runtime_identity(uid_t *uid, gid_t *gid)
{
    *uid = geteuid();
    *gid = getegid();
    return *uid != 0 && *gid != 0;
}

static enum nss_status
fill_passwd(struct passwd *result, char *buffer, size_t buflen, int *errnop)
{
    char *cursor = buffer;
    size_t remaining = buflen;
    uid_t uid;
    gid_t gid;
    enum nss_status status;

    if (!runtime_identity(&uid, &gid)) {
        return NSS_STATUS_NOTFOUND;
    }

#define COPY_PASSWD_FIELD(value, field)                                      \
    do {                                                                      \
        status = buffer_string((value), &cursor, &remaining,                  \
                               &result->field, errnop);                       \
        if (status != NSS_STATUS_SUCCESS) {                                   \
            return status;                                                    \
        }                                                                     \
    } while (0)

    COPY_PASSWD_FIELD(CODEX_NAME, pw_name);
    COPY_PASSWD_FIELD(CODEX_PASSWD, pw_passwd);
    COPY_PASSWD_FIELD(CODEX_GECOS, pw_gecos);
    COPY_PASSWD_FIELD(runtime_home(), pw_dir);
    COPY_PASSWD_FIELD(CODEX_SHELL, pw_shell);
#undef COPY_PASSWD_FIELD

    result->pw_uid = uid;
    result->pw_gid = gid;
    return NSS_STATUS_SUCCESS;
}

enum nss_status
_nss_codex_getpwuid_r(uid_t requested_uid, struct passwd *result, char *buffer,
                      size_t buflen, int *errnop)
{
    uid_t uid;
    gid_t gid;

    if (!runtime_identity(&uid, &gid) || requested_uid != uid) {
        return NSS_STATUS_NOTFOUND;
    }
    return fill_passwd(result, buffer, buflen, errnop);
}

enum nss_status
_nss_codex_getpwnam_r(const char *requested_name, struct passwd *result,
                      char *buffer, size_t buflen, int *errnop)
{
    uid_t uid;
    gid_t gid;

    if (requested_name == NULL || strcmp(requested_name, CODEX_NAME) != 0 ||
        !runtime_identity(&uid, &gid)) {
        return NSS_STATUS_NOTFOUND;
    }
    return fill_passwd(result, buffer, buflen, errnop);
}

static enum nss_status
fill_group(struct group *result, char *buffer, size_t buflen, int *errnop)
{
    uintptr_t start = (uintptr_t)buffer;
    uintptr_t aligned = (start + _Alignof(char *) - 1) &
                        ~((uintptr_t)_Alignof(char *) - 1);
    size_t padding = aligned - start;
    char *cursor;
    size_t remaining;
    uid_t uid;
    gid_t gid;
    enum nss_status status;

    if (!runtime_identity(&uid, &gid)) {
        return NSS_STATUS_NOTFOUND;
    }
    if (padding > buflen || sizeof(char *) > buflen - padding) {
        *errnop = ERANGE;
        return NSS_STATUS_TRYAGAIN;
    }

    result->gr_mem = (char **)aligned;
    result->gr_mem[0] = NULL;
    cursor = (char *)(result->gr_mem + 1);
    remaining = buflen - padding - sizeof(char *);

    status = buffer_string(CODEX_NAME, &cursor, &remaining, &result->gr_name,
                           errnop);
    if (status != NSS_STATUS_SUCCESS) {
        return status;
    }
    status = buffer_string(CODEX_PASSWD, &cursor, &remaining,
                           &result->gr_passwd, errnop);
    if (status != NSS_STATUS_SUCCESS) {
        return status;
    }
    result->gr_gid = gid;
    return NSS_STATUS_SUCCESS;
}

enum nss_status
_nss_codex_getgrgid_r(gid_t requested_gid, struct group *result, char *buffer,
                      size_t buflen, int *errnop)
{
    uid_t uid;
    gid_t gid;

    if (!runtime_identity(&uid, &gid) || requested_gid != gid) {
        return NSS_STATUS_NOTFOUND;
    }
    return fill_group(result, buffer, buflen, errnop);
}

enum nss_status
_nss_codex_getgrnam_r(const char *requested_name, struct group *result,
                      char *buffer, size_t buflen, int *errnop)
{
    uid_t uid;
    gid_t gid;

    if (requested_name == NULL || strcmp(requested_name, CODEX_NAME) != 0 ||
        !runtime_identity(&uid, &gid)) {
        return NSS_STATUS_NOTFOUND;
    }
    return fill_group(result, buffer, buflen, errnop);
}

enum nss_status
_nss_codex_initgroups_dyn(const char *user, gid_t group, long int *start,
                          long int *size, gid_t **groupsp, long int limit,
                          int *errnop)
{
    uid_t uid;
    gid_t gid;

    (void)group;
    (void)start;
    (void)size;
    (void)groupsp;
    (void)limit;
    (void)errnop;
    if (user == NULL || strcmp(user, CODEX_NAME) != 0 ||
        !runtime_identity(&uid, &gid)) {
        return NSS_STATUS_NOTFOUND;
    }
    return NSS_STATUS_SUCCESS;
}
