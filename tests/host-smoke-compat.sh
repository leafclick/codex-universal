#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

pass() { printf '  ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
assert_eq() {
    [[ "$1" == "$2" ]] || fail "$3 (expected '$2', got '$1')"
}
assert_contains() {
    [[ "$1" == *"$2"* ]] || fail "$3 (missing '$2')"
}

REAL_PATH="$PATH"
REAL_BASH="$(command -v bash)"
SYSTEM_PATH=/usr/bin:/bin:/usr/sbin:/sbin
# shellcheck source=/dev/null
source "$ROOT/bin/codex-host-compat.bash"

codex_host_require_capabilities \
    path stat checksum lock atomic-replace null-sort canonical-tar
TEST_ROOT="$(codex_host_path_existing "$TEST_ROOT")"
pass "native host capability checks"

fixture="$TEST_ROOT/fixture"
mkdir -p "$fixture/sub"
printf 'z\n' > "$fixture/z file"
printf 'a\n' > "$fixture/sub/a"
chmod 600 "$fixture/z file"

assert_eq "$(codex_host_path_existing "$fixture/sub/../z file")" \
    "$fixture/z file" "existing path resolution"
assert_eq "$(codex_host_path_allow_missing "$fixture/new/../created")" \
    "$fixture/created" "missing path resolution"
assert_eq "$(codex_host_file_mode "$fixture/z file")" "600" "file mode"
assert_eq "$(codex_host_file_size "$fixture/z file")" "2" "file size"
assert_eq "$(codex_host_file_link_count "$fixture/z file")" "1" "link count"
assert_eq "$(codex_host_file_owner_mode "$fixture/z file")" \
    "$(id -u):600" "owner and mode"
assert_eq "$(codex_host_sha256_file "$fixture/z file")" \
    "c865f6c5ab8d1b0bcd383a5e1e3879d22681c96bf462c269b7581d523fbe70ab" \
    "file checksum"
assert_eq "$(printf 'compat\n' | codex_host_sha256_stdin)" \
    7506474ede71264dcb3fdd617ee2389b92343d76bbaae0c1db384a8bac44812c "stdin checksum"
assert_eq "$(printf '%s\0' z a 'with space' | codex_host_sort_null | tr '\0' '\n')" \
    $'a\nwith space\nz' "NUL-delimited sorting"
pass "path, metadata, checksum, and NUL-sort operations"

printf 'replacement\n' > "$fixture/replacement"
printf 'old\n' > "$fixture/target"
codex_host_atomic_replace "$fixture/replacement" "$fixture/target"
assert_eq "$(<"$fixture/target")" "replacement" "atomic replacement"
[[ ! -e "$fixture/replacement" ]] || fail "atomic replacement left source behind"
pass "atomic replacement"

lock_file="$TEST_ROOT/lock"
exec 9>"$lock_file"
codex_host_lock_exclusive 9
if (exec 8>"$lock_file"; codex_host_lock_try_exclusive 8); then
    fail "cross-descriptor nonblocking lock unexpectedly succeeded"
fi
exec 9>&-
pass "exclusive lock operations"

tar_one="$TEST_ROOT/archive-one.tar"
tar_two="$TEST_ROOT/archive-two.tar"
codex_host_canonical_tar "$fixture" >"$tar_one"
sleep 1
codex_host_canonical_tar "$fixture" >"$tar_two"
cmp -s "$tar_one" "$tar_two" || fail "canonical tar output changed between runs"
tar_listing="$("$CODEX_HOST_TAR" -tf "$tar_one")"
assert_contains "$tar_listing" $'./sub/a' "canonical tar listing"
assert_contains "$tar_listing" $'./z file' "canonical tar listing"
pass "canonical deterministic tar"

fake_root="$TEST_ROOT/fake-darwin"
mkdir -p "$fake_root"
cat >"$fake_root/uname" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' Darwin
EOF
chmod 755 "$fake_root/uname"
ln -s "$(command -v "$CODEX_HOST_REALPATH")" "$fake_root/grealpath"
ln -s "$(command -v "$CODEX_HOST_STAT")" "$fake_root/gstat"
ln -s "$(command -v "$CODEX_HOST_SHA256SUM")" "$fake_root/gsha256sum"
ln -s "$(command -v "$CODEX_HOST_FLOCK")" "$fake_root/flock"
ln -s "$(command -v "$CODEX_HOST_MV")" "$fake_root/gmv"
ln -s "$(command -v "$CODEX_HOST_SORT")" "$fake_root/gsort"
ln -s "$(command -v "$CODEX_HOST_TAR")" "$fake_root/gtar"

darwin_output="$(
    PATH="$fake_root:$REAL_PATH" \
        CODEX_COMPAT_ROOT="$ROOT" \
        CODEX_COMPAT_FIXTURE="$fixture" \
        CODEX_COMPAT_LOCK="$TEST_ROOT/darwin-lock" \
        bash -c '
            set -Eeuo pipefail
            source "$CODEX_COMPAT_ROOT/bin/codex-host-compat.bash"
            codex_host_require_capabilities path stat checksum lock atomic-replace null-sort canonical-tar
            [[ "$CODEX_HOST_BACKEND" == darwin-gnu ]]
            [[ "$CODEX_HOST_REALPATH" == grealpath ]]
            [[ "$(codex_host_path_existing "$CODEX_COMPAT_FIXTURE/sub/../z file")" == \
                "$CODEX_COMPAT_FIXTURE/z file" ]]
            [[ "$(codex_host_file_mode "$CODEX_COMPAT_FIXTURE/z file")" == 600 ]]
            [[ "$(codex_host_sha256_file "$CODEX_COMPAT_FIXTURE/z file")" == \
                c865f6c5ab8d1b0bcd383a5e1e3879d22681c96bf462c269b7581d523fbe70ab ]]
            sorted_output="$(printf "%s\\0" z a | codex_host_sort_null | tr "\\0" "\\n")"
            [[ "$sorted_output" == a* && "$sorted_output" != z* ]]
            printf replacement > "$CODEX_COMPAT_FIXTURE/darwin-replacement"
            printf old > "$CODEX_COMPAT_FIXTURE/darwin-target"
            codex_host_atomic_replace "$CODEX_COMPAT_FIXTURE/darwin-replacement" \
                "$CODEX_COMPAT_FIXTURE/darwin-target"
            [[ "$(<"$CODEX_COMPAT_FIXTURE/darwin-target")" == replacement ]]
            exec 9>"$CODEX_COMPAT_LOCK"
            codex_host_lock_exclusive 9
            if (exec 8>"$CODEX_COMPAT_LOCK"; codex_host_lock_try_exclusive 8); then
                exit 1
            fi
            codex_host_canonical_tar "$CODEX_COMPAT_FIXTURE" >/dev/null
            printf "%s\\n" "Darwin backend semantic operations passed"
        '
)"
assert_contains "$darwin_output" "Darwin backend semantic operations passed" \
    "Darwin backend semantic operations"
pass "Darwin GNU backend semantic operations"

set +e
security_output="$(PATH="$fake_root:$REAL_PATH" bash -c \
    'source "$1/bin/codex-host-compat.bash"; codex_host_require_linux_security' \
    bash "$ROOT" 2>&1)"
security_status=$?
set -e
(( security_status != 0 )) || fail "Darwin Linux-security probe unexpectedly passed"
assert_contains "$security_output" "hardened launcher and host security setup require GNU/Linux" \
    "Darwin Linux-security diagnostic"
pass "Darwin Linux-security rejection"

unsupported_root="$TEST_ROOT/fake-unsupported"
mkdir -p "$unsupported_root"
cat >"$unsupported_root/uname" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' FreeBSD
EOF
chmod 755 "$unsupported_root/uname"
set +e
unsupported_output="$(PATH="$unsupported_root:$REAL_PATH" bash -c \
    'source "$1/bin/codex-host-compat.bash"; codex_host_select_backend' \
    bash "$ROOT" 2>&1)"
unsupported_status=$?
set -e
(( unsupported_status != 0 )) || fail "unsupported platform probe unexpectedly passed"
assert_contains "$unsupported_output" "unsupported host 'FreeBSD'" \
    "unsupported platform diagnostic"
pass "unsupported platform diagnostic"

missing_root="$TEST_ROOT/missing-darwin"
mkdir -p "$missing_root"
cp "$fake_root/uname" "$missing_root/uname"
set +e
missing_output="$(PATH="$missing_root:$SYSTEM_PATH" "$REAL_BASH" -c \
    'source "$1/bin/codex-host-compat.bash"; codex_host_require_capabilities path' \
    bash "$ROOT" 2>&1)"
missing_status=$?
set -e
(( missing_status != 0 )) || fail "missing grealpath probe unexpectedly passed"
assert_contains "$missing_output" \
    "missing command 'grealpath' required for canonical path resolution" \
    "missing capability diagnostic"
pass "missing Darwin tool diagnostic"

incompatible_root="$TEST_ROOT/fake-incompatible"
mkdir -p "$incompatible_root"
cp "$fake_root/uname" "$incompatible_root/uname"
ln -s "$(command -v "$CODEX_HOST_STAT")" "$incompatible_root/gstat"
ln -s "$(command -v "$CODEX_HOST_SHA256SUM")" "$incompatible_root/gsha256sum"
ln -s "$(command -v "$CODEX_HOST_FLOCK")" "$incompatible_root/flock"
ln -s "$(command -v "$CODEX_HOST_MV")" "$incompatible_root/gmv"
ln -s "$(command -v "$CODEX_HOST_SORT")" "$incompatible_root/gsort"
ln -s "$(command -v "$CODEX_HOST_TAR")" "$incompatible_root/gtar"
cat >"$incompatible_root/grealpath" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod 755 "$incompatible_root/grealpath"
set +e
missing_capability_output="$(PATH="$incompatible_root:$SYSTEM_PATH" \
    "$REAL_BASH" -c 'source "$1/bin/codex-host-compat.bash"; codex_host_require_capabilities path' \
    bash "$ROOT" 2>&1)"
missing_capability_status=$?
set -e
(( missing_capability_status != 0 )) || fail "incompatible realpath probe unexpectedly passed"
assert_contains "$missing_capability_output" \
    "'grealpath' lacks required GNU -e/-m semantics" \
    "incompatible capability diagnostic"
pass "incompatible capability diagnostic"

printf '%s\n' 'compatibility contract passed'
