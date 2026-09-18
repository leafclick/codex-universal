#!/usr/bin/env bash

# Host utility compatibility boundary for codex-universal commands.
#
# The first backend deliberately supports GNU/Linux only.  Callers use the
# semantic operations below instead of depending directly on GNU option
# spellings, so another backend can be added without changing safety-critical
# path, locking, hashing, or publication logic.

[[ -z "${CODEX_HOST_COMPAT_API_LOADED:-}" ]] || return 0
readonly CODEX_HOST_COMPAT_API_LOADED=1

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

codex_host_require_gnu_linux() {
    local system

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
    [[ "$system" == Linux ]] || {
        codex_host_compat_error \
            "unsupported host '$system'; this release supports GNU/Linux only (macOS and BSD backends are not implemented)"
        return 1
    }
}

codex_host_require_capability() {
    local capability="$1"

    case "$capability" in
        path)
            codex_host_require_command realpath "canonical path resolution" || return 1
            realpath -e -- / >/dev/null 2>&1 &&
                realpath -m -- /codex-universal-capability-probe >/dev/null 2>&1 ||
                codex_host_compat_error \
                    "'realpath' lacks required GNU -e/-m semantics"
            ;;
        stat)
            codex_host_require_command stat "file metadata inspection" || return 1
            stat -c '%a' -- / >/dev/null 2>&1 ||
                codex_host_compat_error "'stat' lacks required GNU -c semantics"
            ;;
        checksum)
            codex_host_require_command sha256sum "SHA-256 hashing" || return 1
            printf '' | sha256sum >/dev/null 2>&1 ||
                codex_host_compat_error "'sha256sum' cannot hash standard input"
            ;;
        lock)
            codex_host_require_command flock "advisory file locking" || return 1
            flock --version >/dev/null 2>&1 ||
                codex_host_compat_error "'flock' is not the required util-linux implementation"
            ;;
        atomic-replace)
            codex_host_require_command mv "atomic file replacement" || return 1
            mv --version >/dev/null 2>&1 ||
                codex_host_compat_error "'mv' is not the required GNU implementation"
            ;;
        null-sort)
            codex_host_require_command sort "NUL-delimited sorting" || return 1
            printf '' | sort -z >/dev/null 2>&1 ||
                codex_host_compat_error "'sort' lacks required GNU -z semantics"
            ;;
        canonical-tar)
            codex_host_require_command tar "deterministic state archives" || return 1
            codex_host_require_command grep "GNU tar identification" || return 1
            tar --version 2>/dev/null | grep -Fq 'GNU tar' ||
                codex_host_compat_error "'tar' is not GNU tar; deterministic snapshot hashing requires GNU tar"
            ;;
        *)
            codex_host_compat_error "unknown requested capability '$capability'"
            ;;
    esac
}

codex_host_require_capabilities() {
    local capability

    codex_host_require_gnu_linux || return 1
    for capability in "$@"; do
        codex_host_require_capability "$capability" || return 1
    done
}

codex_host_path_existing() {
    realpath -e -- "$1"
}

codex_host_path_allow_missing() {
    realpath -m -- "$1"
}

codex_host_file_mode() {
    stat -c '%a' -- "$1"
}

codex_host_file_size() {
    stat -c '%s' -- "$1"
}

codex_host_file_link_count() {
    stat -c '%h' -- "$1"
}

codex_host_file_owner_mode() {
    stat -c '%u:%a' -- "$1"
}

codex_host_sha256_file() {
    local output

    output="$(sha256sum -- "$1")" || return 1
    printf '%s\n' "${output%% *}"
}

codex_host_sha256_stdin() {
    local output

    output="$(sha256sum)" || return 1
    printf '%s\n' "${output%% *}"
}

codex_host_lock_exclusive() {
    flock -x "$1"
}

codex_host_lock_try_exclusive() {
    flock -n -x "$1"
}

codex_host_lock_shared() {
    flock -s "$1"
}

codex_host_lock_try_shared() {
    flock -n -s "$1"
}

codex_host_atomic_replace() {
    mv -T -- "$1" "$2"
}

codex_host_sort_null() {
    sort -z
}

codex_host_canonical_tar() {
    local directory="$1"

    LC_ALL=C tar \
        --sort=name \
        --format=gnu \
        --mtime='@0' \
        --owner=0 \
        --group=0 \
        --numeric-owner \
        -C "$directory" \
        -cf - .
}
