#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT="$(mktemp -d)"

cleanup() {
    rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

pass() {
    printf 'ok - %s\n' "$1"
}

fail() {
    printf 'not ok - %s\n' "$1" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 ||
        fail "missing host command '$1' (see docs/codex-sync.md)"
}

assert_contains() {
    local value="$1"
    local expected="$2"

    [[ "$value" == *"$expected"* ]] ||
        fail "expected snapshot output to contain: $expected"
}

if [[ "${CODEX_TEST_SKIP_SYNC:-0}" != 1 ]]; then
    for command in awk find flock hostname lsof sha256sum sqlite3 tar zstd; do
        need "$command"
    done

    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        running_codex="$(
            docker ps --format '{{.Names}}' 2>/dev/null |
                grep '^codex-' || true
        )"
        if [[ -n "$running_codex" ]]; then
            printf '%s\n' "$running_codex" >&2
            fail "stop Codex containers before snapshot tests, or set CODEX_TEST_SKIP_SYNC=1"
        fi
    fi

    installed_sync_dir="$TEST_ROOT/installed-sync"
    mkdir -p "$installed_sync_dir"
    install -m 700 "$ROOT/bin/codex-push" "$installed_sync_dir/codex-push"
    install -m 700 "$ROOT/bin/codex-pull" "$installed_sync_dir/codex-pull"
    install -m 600 "$ROOT/bin/codex-sync-lib" \
        "$installed_sync_dir/codex-sync-lib"
    PUSH_COMMAND="$installed_sync_dir/codex-push"
    PULL_COMMAND="$installed_sync_dir/codex-pull"

    push_arg_root="$TEST_ROOT/push-args"
    mkdir -p "$push_arg_root/live" "$push_arg_root/home"
    printf 'argument probe\n' > "$push_arg_root/live/payload"
    push_arg_env=(
        env
        "HOME=$push_arg_root/home"
        "CODEX_DIR=$push_arg_root/live"
        "CODEX_SYNC_DIR=$push_arg_root/sync"
        "CODEX_LOCK_FILE=$push_arg_root/handoff.lock"
        "XDG_STATE_HOME=$push_arg_root/state"
    )
    push_help="$("${push_arg_env[@]}" "$PUSH_COMMAND" --help)"
    assert_contains "$push_help" "Usage:"
    assert_contains "$push_help" "codex-push"
    if "${push_arg_env[@]}" "$PUSH_COMMAND" --unknown \
        >"$push_arg_root/unknown.out" 2>&1; then
        fail "snapshot push accepted an unknown option"
    fi
    assert_contains "$(<"$push_arg_root/unknown.out")" \
        "Unknown option or argument: --unknown"
    [[ ! -e "$push_arg_root/sync" && ! -e "$push_arg_root/state" &&
       ! -e "$push_arg_root/handoff.lock" ]] ||
        fail "snapshot push arguments mutated synchronization state"
    pass "snapshot push argument parsing is nonmutating"

    SYNC_ROOT="$TEST_ROOT/sync"
    LOCK_FILE="$TEST_ROOT/codex-handoff.lock"
    mkdir -p "$SYNC_ROOT"

    run_machine() {
        local machine="$1"
        shift

        env \
            "HOME=$TEST_ROOT/$machine/home" \
            "CODEX_DIR=$TEST_ROOT/$machine/live" \
            "CODEX_SYNC_DIR=$SYNC_ROOT" \
            "CODEX_LOCK_FILE=$LOCK_FILE" \
            "XDG_STATE_HOME=$TEST_ROOT/$machine/state" \
            "$@"
    }

    mkdir -p "$TEST_ROOT/a/live" "$TEST_ROOT/a/home"
    printf 'generation one\n' > "$TEST_ROOT/a/live/payload"
    generation_one_hash="$(sha256sum "$TEST_ROOT/a/live/payload" | awk '{print $1}')"
    sqlite3 "$TEST_ROOT/a/live/state.sqlite" \
        'CREATE TABLE smoke (value TEXT); INSERT INTO smoke VALUES ("ok");'

    if env \
        "HOME=$TEST_ROOT/a/home" \
        "CODEX_DIR=$TEST_ROOT/a/live" \
        'CODEX_SYNC_DIR=relative/sync' \
        "CODEX_LOCK_FILE=$LOCK_FILE" \
        "XDG_STATE_HOME=$TEST_ROOT/a/state" \
        "$PUSH_COMMAND" >/dev/null 2>&1; then
        fail "snapshot push accepted a relative synchronization path"
    fi
    if env \
        "HOME=$TEST_ROOT/a/home" \
        "CODEX_DIR=$TEST_ROOT/a/live" \
        "CODEX_SYNC_DIR=$TEST_ROOT/a/live/snapshots" \
        "CODEX_LOCK_FILE=$LOCK_FILE" \
        "XDG_STATE_HOME=$TEST_ROOT/a/state" \
        "$PULL_COMMAND" --list >/dev/null 2>&1; then
        fail "snapshot pull accepted overlapping live and synchronized state"
    fi

    mkdir -p "$TEST_ROOT/offender-bin"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'if [[ "${1:-}" == ps ]]; then' \
        '    printf "%s\\n" codex-first codex-second' \
        'fi' \
        > "$TEST_ROOT/offender-bin/docker"
    chmod 755 "$TEST_ROOT/offender-bin/docker"
    if PATH="$TEST_ROOT/offender-bin:$PATH" \
        run_machine a "$PUSH_COMMAND" \
        >"$TEST_ROOT/offenders.log" 2>&1; then
        fail "snapshot push ignored running Codex containers"
    fi
    grep -Fxq '  codex-first' "$TEST_ROOT/offenders.log" &&
        grep -Fxq '  codex-second' "$TEST_ROOT/offenders.log" ||
        fail "snapshot push did not report every running Codex container"

    run_machine a "$PUSH_COMMAND" >/dev/null
    no_change="$(run_machine a "$PUSH_COMMAND")"
    assert_contains "$no_change" "No changes"

    mkdir -p "$TEST_ROOT/b/live" "$TEST_ROOT/b/home"
    printf 'replace me\n' > "$TEST_ROOT/b/live/payload"
    run_machine b "$PULL_COMMAND" --force 1 >/dev/null
    [[ "$(sha256sum "$TEST_ROOT/a/live/payload" | awk '{print $1}')" == \
       "$(sha256sum "$TEST_ROOT/b/live/payload" | awk '{print $1}')" ]] ||
        fail "forced pull did not restore generation 1"

    printf 'generation two\n' > "$TEST_ROOT/a/live/payload"
    run_machine a "$PUSH_COMMAND" >/dev/null
    run_machine b "$PULL_COMMAND" >/dev/null
    [[ "$(sha256sum "$TEST_ROOT/a/live/payload" | awk '{print $1}')" == \
       "$(sha256sum "$TEST_ROOT/b/live/payload" | awk '{print $1}')" ]] ||
        fail "forward pull did not restore generation 2"

    printf 'local divergence\n' > "$TEST_ROOT/b/live/payload"
    printf 'generation three\n' > "$TEST_ROOT/a/live/payload"
    run_machine a "$PUSH_COMMAND" >/dev/null
    if run_machine b "$PULL_COMMAND" \
        >"$TEST_ROOT/divergence.log" 2>&1; then
        fail "divergent pull unexpectedly succeeded"
    fi
    grep -q 'DIVERGENCE' "$TEST_ROOT/divergence.log" ||
        fail "divergent pull did not report divergence"

    incomplete_archive='codex-g0000000004-incomplete.tar.zst'
    incomplete_state="$SYNC_ROOT/$incomplete_archive.state"
    incomplete_hash='0000000000000000000000000000000000000000000000000000000000000000'
    {
        printf 'format=1\n'
        printf 'generation=4\n'
        printf 'sha256=%s\n' "$incomplete_hash"
        printf 'created=20260911T000000Z\n'
        printf 'host=host-smoke\n'
        printf 'archive=%s\n' "$incomplete_archive"
    } > "$incomplete_state"

    mkdir -p "$TEST_ROOT/c/live" "$TEST_ROOT/c/home"
    printf 'replace from incomplete head\n' > "$TEST_ROOT/c/live/payload"
    if run_machine c "$PULL_COMMAND" \
        >"$TEST_ROOT/incomplete-normal.log" 2>&1; then
        fail "normal snapshot pull accepted an incomplete newest generation"
    fi
    assert_contains "$(<"$TEST_ROOT/incomplete-normal.log")" \
        "Generation 4 is incomplete"
    run_machine c "$PULL_COMMAND" --force 1 >/dev/null
    [[ "$(sha256sum "$TEST_ROOT/c/live/payload" | awk '{print $1}')" == \
       "$generation_one_hash" ]] ||
        fail "older forced pull did not bypass an incomplete newest generation"
    grep -Fxq 'generation=4' "$TEST_ROOT/c/state/codex-handoff/base.state" ||
        fail "older forced pull did not preserve the remote head baseline"
    rm -f -- "$incomplete_state"
    pass "older forced recovery bypasses incomplete remote head"

    run_machine b "$PULL_COMMAND" --force 1 >/dev/null
    run_machine b "$PUSH_COMMAND" >/dev/null
    grep -R -q '^generation=4$' "$SYNC_ROOT"/*.state ||
        fail "recovery did not publish a new generation"

    snapshot_list="$(run_machine b "$PULL_COMMAND" --list)"
    [[ "$snapshot_list" == *"OK"* ]] ||
        fail "snapshot listing did not report valid archives: $snapshot_list"
    pass "snapshot push, pull, divergence, and recovery"

    validator_root="$TEST_ROOT/shared-validator"
    validator_archive='codex-g0000000001-validator.tar.zst'
    validator_hash='1111111111111111111111111111111111111111111111111111111111111111'
    mkdir -p "$validator_root/live" "$validator_root/home" \
        "$validator_root/sync"
    printf 'validator live state\n' > "$validator_root/live/payload"
    printf 'not a compressed archive\n' \
        > "$validator_root/sync/$validator_archive"
    sha256sum "$validator_root/sync/$validator_archive" |
        awk '{print $1}' \
        > "$validator_root/sync/$validator_archive.sha256"
    {
        printf 'format=2\n'
        printf 'generation=1\n'
        printf 'sha256=%s\n' "$validator_hash"
        printf 'created=20260911T000000Z\n'
        printf 'host=host-smoke\n'
        printf 'archive=%s\n' "$validator_archive"
    } > "$validator_root/sync/$validator_archive.state"
    validator_env=(
        env
        "HOME=$validator_root/home"
        "CODEX_DIR=$validator_root/live"
        "CODEX_SYNC_DIR=$validator_root/sync"
        "CODEX_LOCK_FILE=$validator_root/handoff.lock"
        "XDG_STATE_HOME=$validator_root/state"
    )
    validator_list="$("${validator_env[@]}" "$PULL_COMMAND" --list)"
    assert_contains "$validator_list" "INVALID"
    if "${validator_env[@]}" "$PUSH_COMMAND" \
        >"$validator_root/push.out" 2>&1; then
        fail "snapshot push accepted malformed shared metadata"
    fi
    assert_contains "$(<"$validator_root/push.out")" \
        "Remote snapshot metadata, archive, or checksum is invalid"
    pass "push and pull share strict snapshot metadata validation"
else
    printf 'skip - snapshot integration (CODEX_TEST_SKIP_SYNC=1)\n'
fi
