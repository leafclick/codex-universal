#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
INSTALLER="$ROOT/bin/install-codex-host-tools"
TEST_ROOT="$(mktemp -d)"
# shellcheck source=bin/codex-host-compat.bash
source "$ROOT/bin/codex-host-compat.bash"
codex_host_require_capabilities path stat checksum lock atomic-replace
TEST_ROOT="$(codex_host_path_existing "$TEST_ROOT")"
trap 'rm -rf "$TEST_ROOT"' EXIT

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
run_fail() {
    local label="$1"; shift
    if "$@" >"$TEST_ROOT/fail.out" 2>&1; then
        fail "$label unexpectedly succeeded"
    fi
}
assert_exact_bundle_files() {
    local directory="$1"
    shift
    local expected path
    local -a entries=()

    shopt -s nullglob dotglob
    entries=("$directory"/*)
    shopt -u nullglob dotglob
    [[ "${#entries[@]}" == "$#" ]] || fail "bundle command set is wrong"
    for expected in "$@"; do
        path="$directory/$expected"
        [[ -f "$path" && ! -L "$path" ]] || fail "bundle command set is wrong"
    done
}

bash -n "$INSTALLER"

help_output="$($INSTALLER --help)"
[[ "$help_output" == *"Usage:"* ]] || fail "installer help is missing"
run_fail "unknown installer argument" "$INSTALLER" --unknown
run_fail "missing prefix argument" "$INSTALLER" --prefix
run_fail "relative prefix" "$INSTALLER" --prefix relative
run_fail "root prefix" "$INSTALLER" --prefix /
run_fail "source-overlap prefix" "$INSTALLER" --prefix "$ROOT/.codex-install"

mkdir -p "$TEST_ROOT/parent"
ln -s "$TEST_ROOT/parent" "$TEST_ROOT/prefix-link"
run_fail "symlink prefix" "$INSTALLER" --prefix "$TEST_ROOT/prefix-link"

dry_prefix="$TEST_ROOT/dry"
dry_output="$($INSTALLER --prefix "$dry_prefix" --dry-run)"
[[ "$dry_output" == *"Would install codex-universal"* ]] || fail "dry-run output is incomplete"
[[ ! -e "$dry_prefix" ]] || fail "dry-run created its prefix"
missing_check="$TEST_ROOT/missing-check"
run_fail "missing installation check" "$INSTALLER" --prefix "$missing_check" --check
[[ ! -e "$missing_check" ]] || fail "missing --check created its prefix"

collision_prefix="$TEST_ROOT/collision"
mkdir -p "$collision_prefix/bin"
printf '#!/bin/sh\nprintf unmanaged\\n\n' >"$collision_prefix/bin/codex-push"
chmod 700 "$collision_prefix/bin/codex-push"
collision_hash="$(codex_host_sha256_file "$collision_prefix/bin/codex-push")"
run_fail "unmanaged command collision" "$INSTALLER" --prefix "$collision_prefix"
[[ "$(codex_host_sha256_file "$collision_prefix/bin/codex-push")" == "$collision_hash" ]] ||
    fail "collision check modified an unmanaged command"
[[ ! -e "$collision_prefix/libexec" ]] || fail "collision check modified the installation root"
pass "argument validation, collision protection, and non-mutating dry-run"

prefix="$TEST_ROOT/install"
"$INSTALLER" --prefix "$prefix" >/dev/null
current="$prefix/libexec/codex-universal/current"
bundle_dir="$prefix/libexec/codex-universal/$(readlink "$current")"
[[ -L "$current" ]] || fail "current is not a symlink"
[[ "$(readlink "$current")" != /* ]] || fail "current is not a relative symlink"
[[ -d "$bundle_dir" && ! -L "$bundle_dir" ]] || fail "current does not resolve to immutable bundle"

revision="$(git -C "$ROOT" rev-parse HEAD)"
grep -Fqx $'backend\t'"$CODEX_HOST_BACKEND" "$bundle_dir/MANIFEST" || fail "manifest backend is wrong"
grep -Fqx $'revision\t'"$revision" "$bundle_dir/MANIFEST" || fail "manifest revision is wrong"

if [[ "$CODEX_HOST_BACKEND" == gnu-linux ]]; then
    expected_files=(MANIFEST codex-collab codex-host-compat.bash codex-pull codex-push codex-sync-lib run-codex run-codex-doctor.bash setup-codex-idea)
    expected_wrappers=(codex-collab codex-pull codex-push run-codex setup-codex-idea)
else
    expected_files=(MANIFEST codex-collab codex-host-compat.bash codex-pull codex-push codex-sync-lib)
    expected_wrappers=(codex-collab codex-pull codex-push)
fi
assert_exact_bundle_files "$bundle_dir" "${expected_files[@]}"
for file in "${expected_wrappers[@]}"; do
    expected_mode=700
    [[ "$file" == run-codex || "$file" == setup-codex-idea ]] && expected_mode=755
    [[ "$(codex_host_file_mode "$bundle_dir/$file")" == "$expected_mode" ]] || fail "wrong mode for $file"
    [[ "$(codex_host_file_mode "$prefix/bin/$file")" == "$expected_mode" ]] || fail "wrong wrapper mode for $file"
done
[[ "$(codex_host_file_mode "$bundle_dir/codex-sync-lib")" == 600 ]] || fail "wrong mode for sync library"
for file in codex-host-compat.bash run-codex-doctor.bash MANIFEST; do
    [[ ! -e "$bundle_dir/$file" || "$(codex_host_file_mode "$bundle_dir/$file")" == 644 ]] || fail "wrong mode for $file"
done
for file in "${expected_wrappers[@]}"; do
    "$prefix/bin/$file" --help >/dev/null || fail "$file --help failed"
done
"$INSTALLER" --prefix "$prefix" --check >/dev/null || fail "fresh installation check failed"

bundle_count() {
    local count=0 path
    shopt -s nullglob
    for path in "$prefix/libexec/codex-universal"/*; do [[ -d "$path" && ! -L "$path" ]] && ((count += 1)); done
    shopt -u nullglob
    printf '%s\n' "$count"
}
before_bundle_count="$(bundle_count)"
"$INSTALLER" --prefix "$prefix" >/dev/null
after_bundle_count="$(bundle_count)"
[[ "$before_bundle_count" == "$after_bundle_count" ]] || fail "repeat install was not idempotent"
pass "native install, manifest, modes, wrappers, check, and repeat install"

printf 'tamper\n' >> "$bundle_dir/codex-push"
run_fail "tampered bundle check" "$INSTALLER" --prefix "$prefix" --check
cp "$ROOT/bin/codex-push" "$bundle_dir/codex-push"
touch "$bundle_dir/unexpected"
run_fail "unexpected bundle entry check" "$INSTALLER" --prefix "$prefix" --check
rm -f "$bundle_dir/unexpected"
pass "bundle integrity checks"

[[ "$CODEX_HOST_BACKEND" == gnu-linux ]] || exit 0
darwin_bin="$TEST_ROOT/darwin-bin"
mkdir -p "$darwin_bin"
cat >"$darwin_bin/uname" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' Darwin
EOF
chmod 755 "$darwin_bin/uname"
ln -s "$(command -v "$CODEX_HOST_REALPATH")" "$darwin_bin/grealpath"
ln -s "$(command -v "$CODEX_HOST_STAT")" "$darwin_bin/gstat"
ln -s "$(command -v "$CODEX_HOST_SHA256SUM")" "$darwin_bin/gsha256sum"
ln -s "$(command -v "$CODEX_HOST_FLOCK")" "$darwin_bin/flock"
ln -s "$(command -v "$CODEX_HOST_MV")" "$darwin_bin/gmv"
ln -s "$(command -v "$CODEX_HOST_SORT")" "$darwin_bin/gsort"
ln -s "$(command -v "$CODEX_HOST_TAR")" "$darwin_bin/gtar"
darwin_prefix="$TEST_ROOT/darwin-install"
PATH="$darwin_bin:$PATH" "$INSTALLER" --prefix "$darwin_prefix" >/dev/null
darwin_bundle="$darwin_prefix/libexec/codex-universal/$(readlink "$darwin_prefix/libexec/codex-universal/current")"
darwin_expected=(MANIFEST codex-collab codex-host-compat.bash codex-pull codex-push codex-sync-lib)
assert_exact_bundle_files "$darwin_bundle" "${darwin_expected[@]}"
for file in run-codex setup-codex-idea; do [[ ! -e "$darwin_prefix/bin/$file" ]] || fail "Darwin installed Linux-only command $file"; done
PATH="$darwin_bin:$PATH" "$INSTALLER" --prefix "$darwin_prefix" --check >/dev/null || fail "Darwin installation check failed"
pass "Darwin portable command set"
