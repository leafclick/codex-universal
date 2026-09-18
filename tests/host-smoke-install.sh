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
[[ "$help_output" == *"--list"* && "$help_output" == *"--rollback"* &&
   "$help_output" == *"--remove"* ]] ||
    fail "installer lifecycle help is missing"
run_fail "unknown installer argument" "$INSTALLER" --unknown
run_fail "missing prefix argument" "$INSTALLER" --prefix
run_fail "missing rollback argument" "$INSTALLER" --rollback
run_fail "missing remove argument" "$INSTALLER" --remove
run_fail "conflicting lifecycle actions" "$INSTALLER" --list --check
run_fail "conflicting remove action" "$INSTALLER" --remove absent --list
run_fail "invalid check dry-run" "$INSTALLER" --check --dry-run
run_fail "duplicate dry-run" "$INSTALLER" --dry-run --dry-run
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
missing_list="$TEST_ROOT/missing-list"
run_fail "missing installation list" "$INSTALLER" --prefix "$missing_list" --list
[[ ! -e "$missing_list" ]] || fail "missing --list created its prefix"
missing_rollback="$TEST_ROOT/missing-rollback"
run_fail "missing installation rollback" "$INSTALLER" --prefix "$missing_rollback" --rollback absent
[[ ! -e "$missing_rollback" ]] || fail "missing --rollback created its prefix"
missing_remove="$TEST_ROOT/missing-remove"
run_fail "missing installation removal" "$INSTALLER" --prefix "$missing_remove" --remove absent
[[ ! -e "$missing_remove" ]] || fail "missing --remove created its prefix"

collision_prefix="$TEST_ROOT/collision"
mkdir -p "$collision_prefix/bin"
printf '#!/bin/sh\nprintf unmanaged\\n\n' >"$collision_prefix/bin/codex-push"
chmod 700 "$collision_prefix/bin/codex-push"
collision_hash="$(codex_host_sha256_file "$collision_prefix/bin/codex-push")"
run_fail "unmanaged command collision" "$INSTALLER" --prefix "$collision_prefix"
[[ "$(codex_host_sha256_file "$collision_prefix/bin/codex-push")" == "$collision_hash" ]] ||
    fail "collision check modified an unmanaged command"
[[ ! -e "$collision_prefix/libexec" ]] || fail "collision check modified the installation root"

lock_prefix="$TEST_ROOT/unsafe-lock"
lock_root="$lock_prefix/libexec/codex-universal"
mkdir -p "$lock_root"
printf 'lock victim\n' >"$TEST_ROOT/lock-victim"
ln "$TEST_ROOT/lock-victim" "$lock_root/.install.lock"
run_fail "multiply linked install lock" "$INSTALLER" --prefix "$lock_prefix"
[[ "$(<"$TEST_ROOT/lock-victim")" == 'lock victim' ]] || fail "unsafe install lock damaged its target"
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
    expected_files=(MANIFEST codex-bwrap-seccomp.json codex-collab codex-host-compat.bash codex-pull codex-push codex-sync-lib run-codex run-codex-doctor.bash)
    expected_wrappers=(codex-collab codex-pull codex-push run-codex)
fi
assert_exact_bundle_files "$bundle_dir" "${expected_files[@]}"
for file in "${expected_wrappers[@]}"; do
    expected_mode=700
    [[ "$file" == run-codex || "$file" == setup-codex-idea ]] && expected_mode=755
    [[ "$(codex_host_file_mode "$bundle_dir/$file")" == "$expected_mode" ]] || fail "wrong mode for $file"
    [[ "$(codex_host_file_mode "$prefix/bin/$file")" == "$expected_mode" ]] || fail "wrong wrapper mode for $file"
done
[[ "$(codex_host_file_mode "$bundle_dir/codex-sync-lib")" == 600 ]] || fail "wrong mode for sync library"
for file in codex-bwrap-seccomp.json codex-host-compat.bash run-codex-doctor.bash MANIFEST; do
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

rollback_source="$TEST_ROOT/rollback-source"
mkdir -p "$rollback_source/bin"
cp "$ROOT"/bin/* "$rollback_source/bin/"
git -C "$rollback_source" init -q
git -C "$rollback_source" config user.email smoke@example.invalid
git -C "$rollback_source" config user.name host-smoke
git -C "$rollback_source" add -A
git -C "$rollback_source" -c commit.gpgSign=false commit -qm 'host smoke rollback baseline'
rollback_prefix="$TEST_ROOT/rollback-install"
rollback_installer="$rollback_source/bin/install-codex-host-tools"
"$rollback_installer" --prefix "$rollback_prefix" >/dev/null
rollback_root="$rollback_prefix/libexec/codex-universal"
first_id="$(readlink "$rollback_root/current")"
first_list="$($rollback_installer --prefix "$rollback_prefix" --list)"
[[ "$first_list" == *$'CURRENT\tBUNDLE\tVERSION\tREVISION\tBACKEND'* ]] || fail "bundle list header is missing"
[[ "$first_list" == *$'*	'"$first_id"$'\t'* ]] || fail "bundle list current marker is wrong"
first_current="$first_id"
first_list_again="$($rollback_installer --prefix "$rollback_prefix" --list)"
[[ "$first_list" == "$first_list_again" ]] || fail "bundle list is not deterministic"
[[ "$(readlink "$rollback_root/current")" == "$first_current" ]] || fail "bundle list changed current"

printf '\nrollback version two\n' >>"$rollback_source/bin/codex-push"
git -C "$rollback_source" add bin/codex-push
git -C "$rollback_source" -c commit.gpgSign=false commit -qm 'host smoke rollback second bundle'
"$rollback_installer" --prefix "$rollback_prefix" >/dev/null
second_id="$(readlink "$rollback_root/current")"
[[ "$second_id" != "$first_id" ]] || fail "second source revision did not create a new bundle"
list_two="$($rollback_installer --prefix "$rollback_prefix" --list)"
[[ "$list_two" == *$'\t'"$first_id"$'\t'* && "$list_two" == *$'*\t'"$second_id"$'\t'* ]] || fail "bundle list omitted retained versions"
cp "$rollback_source/bin/codex-push" "$TEST_ROOT/second-codex-push"
rm "$rollback_source/bin/codex-push"
"$rollback_installer" --prefix "$rollback_prefix" --rollback "$first_id" >/dev/null
[[ "$(readlink "$rollback_root/current")" == "$first_id" ]] || fail "rollback did not switch current bundle"
"$rollback_prefix/bin/codex-push" --help >/dev/null || fail "rolled-back wrapper failed"
run_fail "current checkout mismatch after rollback" "$rollback_installer" --prefix "$rollback_prefix" --check

run_fail "traversal rollback ID" "$rollback_installer" --prefix "$rollback_prefix" --rollback ../"$first_id"
run_fail "invalid rollback ID" "$rollback_installer" --prefix "$rollback_prefix" --rollback bad/id
ln -s "$first_id" "$rollback_root/symlink-id"
run_fail "symlink rollback ID" "$rollback_installer" --prefix "$rollback_prefix" --rollback symlink-id
rm -f "$rollback_root/symlink-id"

printf 'tampered retained bundle\n' >>"$rollback_root/$second_id/codex-push"
run_fail "tampered retained rollback" "$rollback_installer" --prefix "$rollback_prefix" --rollback "$second_id"
[[ "$(readlink "$rollback_root/current")" == "$first_id" ]] || fail "failed rollback changed current"
cp "$TEST_ROOT/second-codex-push" "$rollback_root/$second_id/codex-push"

exec 8>"$rollback_root/.install.lock"
codex_host_lock_exclusive 8 || fail "could not acquire installer lock for serialization test"
list_pid=""
(exec 8>&-; "$rollback_installer" --prefix "$rollback_prefix" --list) >"$TEST_ROOT/locked-list.out" 2>&1 &
list_pid=$!
sleep 1
kill -0 "$list_pid" 2>/dev/null || fail "list did not wait for installer lock"
exec 8>&-
wait "$list_pid" || fail "locked list did not complete after lock release"
pass "bundle list, rollback validation, tamper protection, and lock serialization"

hidden_dir="$rollback_root/.unrelated-hidden"
mkdir "$hidden_dir"
printf 'keep me\n' >"$hidden_dir/marker"
remove_before_list="$($rollback_installer --prefix "$rollback_prefix" --list)"
remove_before_current="$(readlink "$rollback_root/current")"
run_fail "active bundle removal" "$rollback_installer" --prefix "$rollback_prefix" --remove "$first_id" --dry-run
for dry_order in '--dry-run --remove' '--remove --dry-run'; do
    if [[ "$dry_order" == '--dry-run --remove' ]]; then
        dry_output="$($rollback_installer --prefix "$rollback_prefix" --dry-run --remove "$second_id")"
    else
        dry_output="$($rollback_installer --prefix "$rollback_prefix" --remove "$second_id" --dry-run)"
    fi
    [[ "$dry_output" == *"Would remove inactive"* ]] || fail "remove dry-run output is missing"
done
[[ "$($rollback_installer --prefix "$rollback_prefix" --list)" == "$remove_before_list" ]] || fail "remove dry-run changed the bundle tree"
[[ "$(readlink "$rollback_root/current")" == "$remove_before_current" ]] || fail "remove dry-run changed current"
[[ "$(cat "$hidden_dir/marker")" == 'keep me' ]] || fail "remove dry-run changed unrelated hidden state"
second_manifest_hash="$(codex_host_sha256_file "$rollback_root/$second_id/MANIFEST")"

run_fail "missing bundle removal" "$rollback_installer" --prefix "$rollback_prefix" --remove missing-bundle
run_fail "traversal bundle removal" "$rollback_installer" --prefix "$rollback_prefix" --remove ../"$second_id"
ln -s "$second_id" "$rollback_root/remove-symlink-id"
run_fail "symlink bundle removal" "$rollback_installer" --prefix "$rollback_prefix" --remove remove-symlink-id
rm -f "$rollback_root/remove-symlink-id"
printf 'tampered removal bundle\n' >>"$rollback_root/$second_id/codex-push"
run_fail "tampered bundle removal" "$rollback_installer" --prefix "$rollback_prefix" --remove "$second_id"
[[ "$(readlink "$rollback_root/current")" == "$remove_before_current" ]] || fail "rejected removal changed current"
cp "$TEST_ROOT/second-codex-push" "$rollback_root/$second_id/codex-push"

fake_rm_bin="$TEST_ROOT/fake-rm"
mkdir "$fake_rm_bin"
cat >"$fake_rm_bin/rm" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
target="${*: -1}"
if [[ "$target" == */bundle ]]; then
    "$CODEX_TEST_REAL_RM" -f "$target/codex-push"
    exit 1
fi
exec "$CODEX_TEST_REAL_RM" "$@"
EOF
chmod 755 "$fake_rm_bin/rm"
run_fail "injected removal failure" env PATH="$fake_rm_bin:$PATH" CODEX_TEST_REAL_RM="$(command -v rm)" \
    "$rollback_installer" --prefix "$rollback_prefix" --remove "$second_id"
removal_tombstone=""
shopt -s nullglob
for path in "$rollback_root/.remove.${second_id}."*; do removal_tombstone="$path"; done
shopt -u nullglob
[[ -n "$removal_tombstone" && -d "$removal_tombstone/bundle" &&
   -f "$removal_tombstone/REMOVE-MANIFEST" ]] || fail "failed removal did not preserve tombstone"
tombstone_manifest_hash="$(codex_host_sha256_file "$removal_tombstone/bundle/MANIFEST")"
[[ "$tombstone_manifest_hash" == "$second_manifest_hash" &&
   ! -e "$removal_tombstone/bundle/codex-push" ]] || fail "injected removal did not leave a partial retry fixture"
[[ "$(readlink "$rollback_root/current")" == "$remove_before_current" ]] || fail "failed removal changed current"
"$rollback_installer" --prefix "$rollback_prefix" --remove "$second_id" >/dev/null
[[ ! -e "$rollback_root/$second_id" ]] || fail "successful removal retained the bundle"
[[ ! -e "$removal_tombstone" ]] || fail "successful retry retained tombstone"
[[ "$(cat "$hidden_dir/marker")" == 'keep me' ]] || fail "successful removal changed unrelated hidden state"
"$rollback_prefix/bin/codex-push" --help >/dev/null || fail "current wrapper failed after removing inactive bundle"
pass "bundle removal validation, dry-runs, tombstone recovery, and hidden-state preservation"

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
darwin_expected=(MANIFEST codex-bwrap-seccomp.json codex-collab codex-host-compat.bash codex-pull codex-push codex-sync-lib run-codex run-codex-doctor.bash)
assert_exact_bundle_files "$darwin_bundle" "${darwin_expected[@]}"
[[ -x "$darwin_prefix/bin/run-codex" ]] || fail "Darwin did not install run-codex"
[[ ! -e "$darwin_prefix/bin/setup-codex-idea" ]] || fail "Darwin installed Linux-only setup-codex-idea"
PATH="$darwin_bin:$PATH" "$INSTALLER" --prefix "$darwin_prefix" --check >/dev/null || fail "Darwin installation check failed"
pass "Darwin generic launcher and portable command set"
