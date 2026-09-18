#!/usr/bin/env bash

# Host utility compatibility boundary for codex-universal commands.
#
# Callers use the semantic operations below instead of depending directly on
# platform command names. The Darwin backend deliberately uses prefixed GNU
# tools, available from Homebrew or MacPorts, where their exact behavior is
# part of the state or locking protocol.

[[ -z "${CODEX_HOST_COMPAT_API_LOADED:-}" ]] || return 0
readonly CODEX_HOST_COMPAT_API_LOADED=1

CODEX_HOST_BACKEND=""
CODEX_HOST_REALPATH=""
CODEX_HOST_STAT=""
CODEX_HOST_SHA256SUM=""
CODEX_HOST_FLOCK=""
CODEX_HOST_MV=""
CODEX_HOST_SORT=""
CODEX_HOST_TAR=""

codex_host_compat_error() {
    printf 'ERROR: Host compatibility: %s\n' "$*" >&2
    return 1
}

codex_host_require_command() {
    local command_name="$1"
    local capability="$2"

    command -v "$command_name" >/dev/null 2>&1 ||
        codex_host_compat_error \
            "missing command '$command_name' required for $capability"
}

codex_host_select_backend() {
    local system

    [[ -z "$CODEX_HOST_BACKEND" ]] || return 0
    if ((BASH_VERSINFO[0] < 4 ||
         (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 1))); then
        codex_host_compat_error \
            "Bash 4.1 or newer is required; found ${BASH_VERSION:-unknown}"
        return 1
    fi
    codex_host_require_command uname "platform detection" || return 1
    system="$(uname -s 2>/dev/null)" || {
        codex_host_compat_error "cannot determine the host operating system"
        return 1
    }
    case "$system" in
        Linux)
            CODEX_HOST_BACKEND=gnu-linux
            CODEX_HOST_REALPATH=realpath
            CODEX_HOST_STAT=stat
            CODEX_HOST_SHA256SUM=sha256sum
            CODEX_HOST_FLOCK=flock
            CODEX_HOST_MV=mv
            CODEX_HOST_SORT=sort
            CODEX_HOST_TAR=tar
            ;;
        Darwin)
            CODEX_HOST_BACKEND=darwin-gnu
            CODEX_HOST_REALPATH=grealpath
            CODEX_HOST_STAT=gstat
            CODEX_HOST_SHA256SUM=gsha256sum
            CODEX_HOST_FLOCK=flock
            CODEX_HOST_MV=gmv
            CODEX_HOST_SORT=gsort
            CODEX_HOST_TAR=gtar
            ;;
        *)
            codex_host_compat_error \
                "unsupported host '$system'; available utility backends are GNU/Linux and macOS"
            return 1
            ;;
    esac
}

codex_host_require_linux_security() {
    codex_host_select_backend || return 1
    [[ "$CODEX_HOST_BACKEND" == gnu-linux ]] || {
        codex_host_compat_error \
            "the hardened launcher and host security setup require GNU/Linux; macOS supports only standalone state synchronization and collaboration commands"
        return 1
    }
}

codex_host_require_capability() {
    local capability="$1"

    case "$capability" in
        path)
            codex_host_require_command "$CODEX_HOST_REALPATH" \
                "canonical path resolution for $CODEX_HOST_BACKEND" || return 1
            "$CODEX_HOST_REALPATH" -e -- / >/dev/null 2>&1 &&
                "$CODEX_HOST_REALPATH" -m -- /codex-universal-capability-probe >/dev/null 2>&1 ||
                codex_host_compat_error \
                    "'$CODEX_HOST_REALPATH' lacks required GNU -e/-m semantics"
            ;;
        stat)
            codex_host_require_command "$CODEX_HOST_STAT" \
                "file metadata inspection for $CODEX_HOST_BACKEND" || return 1
            "$CODEX_HOST_STAT" -c '%a' -- / >/dev/null 2>&1 ||
                codex_host_compat_error \
                    "'$CODEX_HOST_STAT' lacks required GNU -c semantics"
            ;;
        checksum)
            codex_host_require_command "$CODEX_HOST_SHA256SUM" \
                "SHA-256 hashing for $CODEX_HOST_BACKEND" || return 1
            printf '' | "$CODEX_HOST_SHA256SUM" >/dev/null 2>&1 ||
                codex_host_compat_error \
                    "'$CODEX_HOST_SHA256SUM' cannot hash standard input"
            ;;
        lock)
            codex_host_require_command "$CODEX_HOST_FLOCK" \
                "fd-based advisory file locking for $CODEX_HOST_BACKEND" || return 1
            "$CODEX_HOST_FLOCK" -V >/dev/null 2>&1 ||
                codex_host_compat_error \
                    "'$CODEX_HOST_FLOCK' lacks the required fd-locking interface"
            ;;
        atomic-replace)
            codex_host_require_command "$CODEX_HOST_MV" \
                "atomic replacement for $CODEX_HOST_BACKEND" || return 1
            "$CODEX_HOST_MV" --version >/dev/null 2>&1 ||
                codex_host_compat_error \
                    "'$CODEX_HOST_MV' is not the required GNU implementation"
            ;;
        null-sort)
            codex_host_require_command "$CODEX_HOST_SORT" \
                "NUL-delimited sorting for $CODEX_HOST_BACKEND" || return 1
            printf '' | "$CODEX_HOST_SORT" -z >/dev/null 2>&1 ||
                codex_host_compat_error \
                    "'$CODEX_HOST_SORT' lacks required GNU -z semantics"
            ;;
        canonical-tar)
            codex_host_require_command "$CODEX_HOST_TAR" \
                "deterministic state archives for $CODEX_HOST_BACKEND" || return 1
            codex_host_require_command grep "GNU tar identification" || return 1
            "$CODEX_HOST_TAR" --version 2>/dev/null | grep -Fq 'GNU tar' ||
                codex_host_compat_error \
                    "'$CODEX_HOST_TAR' is not GNU tar; deterministic snapshot hashing requires GNU tar"
            ;;
        *)
            codex_host_compat_error "unknown requested capability '$capability'"
            ;;
    esac
}

codex_host_require_capabilities() {
    local capability

    codex_host_select_backend || return 1
    for capability in "$@"; do
        codex_host_require_capability "$capability" || return 1
    done
}

codex_host_path_existing() {
    "$CODEX_HOST_REALPATH" -e -- "$1"
}

codex_host_path_allow_missing() {
    "$CODEX_HOST_REALPATH" -m -- "$1"
}

codex_host_file_mode() {
    "$CODEX_HOST_STAT" -c '%a' -- "$1"
}

codex_host_file_size() {
    "$CODEX_HOST_STAT" -c '%s' -- "$1"
}

codex_host_file_link_count() {
    "$CODEX_HOST_STAT" -c '%h' -- "$1"
}

codex_host_file_owner_mode() {
    "$CODEX_HOST_STAT" -c '%u:%a' -- "$1"
}

codex_host_sha256_file() {
    local output

    output="$("$CODEX_HOST_SHA256SUM" -- "$1")" || return 1
    printf '%s\n' "${output%% *}"
}

codex_host_sha256_stdin() {
    local output

    output="$("$CODEX_HOST_SHA256SUM")" || return 1
    printf '%s\n' "${output%% *}"
}

codex_host_lock_exclusive() {
    "$CODEX_HOST_FLOCK" -x "$1"
}

codex_host_lock_try_exclusive() {
    "$CODEX_HOST_FLOCK" -n -x "$1"
}

codex_host_lock_shared() {
    "$CODEX_HOST_FLOCK" -s "$1"
}

codex_host_lock_try_shared() {
    "$CODEX_HOST_FLOCK" -n -s "$1"
}

codex_host_atomic_replace() {
    "$CODEX_HOST_MV" -T -- "$1" "$2"
}

codex_host_sort_null() {
    "$CODEX_HOST_SORT" -z
}

codex_host_canonical_tar() {
    local directory="$1"

    LC_ALL=C "$CODEX_HOST_TAR" \
        --sort=name \
        --format=gnu \
        --mtime='@0' \
        --owner=0 \
        --group=0 \
        --numeric-owner \
        -C "$directory" \
        -cf - .
}

codex_host_state_archive_create() {
    local directory="$1"

    "$CODEX_HOST_TAR" -C "$directory" -cf - .
}

codex_host_state_archive_extract() {
    local destination="$1"

    "$CODEX_HOST_TAR" -xf - \
        --no-same-owner \
        --same-permissions \
        --transform='s,^\.$,content,rSH' \
        --transform='s,^\./,content/,rSH' \
        -C "$destination"
}
