#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

fail() {
    printf 'not ok - %s\n' "$1" >&2
    exit 1
}

portable_files=(
    "$ROOT/bin/codex-push"
    "$ROOT/bin/codex-pull"
    "$ROOT/bin/codex-collab"
    "$ROOT/bin/codex-sync-lib"
    "$ROOT/bin/install-codex-host-tools"
)

for file in "${portable_files[@]}"; do
    [[ -f "$file" ]] || fail "missing portable host file: $file"
done

violations=0
check_rule() {
    local description="$1"
    local pattern="$2"
    local matches

    matches="$(LC_ALL=C grep -En -- "$pattern" "${portable_files[@]}" || true)"
    if [[ -n "$matches" ]]; then
        printf 'not ok - portable host commands bypass %s\n%s\n' \
            "$description" "$matches" >&2
        violations=1
    fi
}

# Keep platform-sensitive command selection and invocation inside the host
# compatibility module. Ordinary POSIX/BSD-compatible uses such as
# `LC_ALL=C sort` and `mv -- source target` are intentionally allowed.
check_rule 'canonical-path abstraction' \
    '(^|[^[:alnum:]_])(realpath|grealpath)([[:space:]]|$)'
check_rule 'file-metadata abstraction' \
    '(^|[^[:alnum:]_])stat[[:space:]]+-|(^|[^[:alnum:]_])gstat([[:space:]]|$)'
check_rule 'checksum abstraction' \
    '(^|[^[:alnum:]_])(sha256sum|gsha256sum|shasum)([[:space:]]|$)'
check_rule 'locking abstraction' \
    '(^|[^[:alnum:]_])flock([[:space:]]|$)'
check_rule 'atomic-replacement abstraction' \
    '(^|[^[:alnum:]_])mv[[:space:]]+-[^[:space:]]*T|(^|[^[:alnum:]_])gmv([[:space:]]|$)'
check_rule 'NUL-sort abstraction' \
    '(^|[^[:alnum:]_])sort[[:space:]]+-[^[:space:]]*z|(^|[^[:alnum:]_])gsort([[:space:]]|$)'
check_rule 'canonical-tar abstraction' \
    '(^|[^[:alnum:]_])gtar([[:space:]]|$)|--sort=name|--mtime=|--owner=|--group=|--numeric-owner|--pax-option'
check_rule 'compatibility backend internals' \
    'CODEX_HOST_(REALPATH|STAT|SHA256SUM|FLOCK|MV|SORT|TAR)'

((violations == 0)) || exit 1
printf 'ok - portable host commands use the compatibility boundary\n'
