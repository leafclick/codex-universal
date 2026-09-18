#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

pass() { printf '  ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
assert_eq() {
    [[ "$1" == "$2" ]] || fail "$3 (expected '$2', got '$1')"
}
assert_contains() {
    [[ "$1" == *"$2"* ]] || fail "$3 (missing '$2')"
}

REAL_PATH="$PATH"
# shellcheck source=/dev/null
source "$ROOT/bin/codex-host-compat.bash"

codex_host_require_capabilities \
    path stat checksum lock atomic-replace null-sort canonical-tar
pass "GNU/Linux capability checks"

fixture="$TEST_ROOT/fixture"
mkdir -p -- "$fixture/sub"
printf 'z\n' > "$fixture/z file"
printf 'a\n' > "$fixture/sub/a"
chmod 600 -- "$fixture/z file"

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
    "$(sha256sum -- "$fixture/z file" | awk '{print $1}')" "file checksum"
assert_eq "$(printf 'compat\n' | codex_host_sha256_stdin)" \
    "$(printf 'compat\n' | sha256sum | awk '{print $1}')" "stdin checksum"
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
cmp -s -- "$tar_one" "$tar_two" || fail "canonical tar output changed between runs"
tar_listing="$(tar -tf "$tar_one")"
assert_contains "$tar_listing" $'./sub/a' "canonical tar listing"
assert_contains "$tar_listing" $'./z file' "canonical tar listing"
pass "canonical deterministic tar"

fake_root="$TEST_ROOT/fake"
mkdir -p -- "$fake_root"
cat >"$fake_root/uname" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' Darwin
EOF
chmod 755 -- "$fake_root/uname"
set +e
unsupported_output="$(PATH="$fake_root:$REAL_PATH" codex_host_require_gnu_linux 2>&1)"
unsupported_status=$?
set -e
(( unsupported_status != 0 )) || fail "unsupported platform probe unexpectedly passed"
assert_contains "$unsupported_output" "unsupported host 'Darwin'" \
    "unsupported platform diagnostic"
pass "unsupported platform diagnostic"

missing_root="$TEST_ROOT/missing"
mkdir -p -- "$missing_root"
set +e
missing_output="$(PATH="$missing_root" codex_host_require_capability path 2>&1)"
missing_status=$?
set -e
(( missing_status != 0 )) || fail "missing realpath probe unexpectedly passed"
assert_contains "$missing_output" \
    "missing command 'realpath' required for canonical path resolution" \
    "missing capability diagnostic"
pass "missing capability diagnostic"

cat >"$fake_root/realpath" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod 755 -- "$fake_root/realpath"
set +e
missing_capability_output="$(PATH="$fake_root:$REAL_PATH" \
    codex_host_require_capability path 2>&1)"
missing_capability_status=$?
set -e
(( missing_capability_status != 0 )) || fail "incompatible realpath probe unexpectedly passed"
assert_contains "$missing_capability_output" \
    "'realpath' lacks required GNU -e/-m semantics" \
    "incompatible capability diagnostic"
pass "incompatible capability diagnostic"

printf '%s\n' 'compatibility contract passed'
