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
    for command in awk cp find flock grep head hostname lsof sha256sum sqlite3 tar zstd; do
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

    run_isolated() {
        local root="$1"
        shift

        env \
            "HOME=$root/home" \
            "CODEX_DIR=$root/live" \
            "CODEX_SYNC_DIR=$root/sync" \
            "CODEX_LOCK_FILE=$root/handoff.lock" \
            "XDG_STATE_HOME=$root/state" \
            "$@"
    }

    handoff_sync_root="$TEST_ROOT/handoff-sync"
    handoff_project='handoff-project'
    handoff_lane='default'
    handoff_commit='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    handoff_profile='generic'
    handoff_version='test-version'
    handoff_revision='abcdef1234567'
    handoff_onboarding_hash='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

    run_handoff() {
        local machine="$1"
        shift

        env \
            "HOME=$TEST_ROOT/$machine/home" \
            "CODEX_DIR=$TEST_ROOT/$machine/live" \
            "CODEX_SYNC_DIR=$handoff_sync_root" \
            "CODEX_LOCK_FILE=$TEST_ROOT/handoff.lock" \
            "XDG_STATE_HOME=$TEST_ROOT/$machine/state" \
            "CODEX_HANDOFF_PROJECT=$handoff_project" \
            "CODEX_HANDOFF_LANE=$handoff_lane" \
            "CODEX_HANDOFF_COMMIT=$handoff_commit" \
            "CODEX_HANDOFF_RUNTIME_PROFILE=$handoff_profile" \
            "CODEX_HANDOFF_RUNTIME_VERSION=$handoff_version" \
            "CODEX_HANDOFF_RUNTIME_REVISION=$handoff_revision" \
            "CODEX_HANDOFF_ONBOARDING_SHA256=$handoff_onboarding_hash" \
            'CODEX_HANDOFF_READY=1' \
            "$@"
    }

    fixture_state_hash() {
        local dir="$1"

        LC_ALL=C tar \
            --sort=name \
            --format=gnu \
            --mtime='@0' \
            --owner=0 \
            --group=0 \
            --numeric-owner \
            -C "$dir" \
            -cf - . |
            sha256sum |
            awk '{print $1}'
    }

    make_fixture_archive() {
        local source_dir="$1"
        local archive_path="$2"

        LC_ALL=C tar \
            --sort=name \
            --format=gnu \
            --mtime='@0' \
            --owner=0 \
            --group=0 \
            --numeric-owner \
            -C "$source_dir" \
            -cf - . |
            zstd -q -T0 -o "$archive_path"
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

    lock_snapshot_count="$(find "$SYNC_ROOT" -maxdepth 1 -type f | wc -l)"
    lock_live_hash="$(fixture_state_hash "$TEST_ROOT/a/live")"
    exec 8>"$LOCK_FILE"
    flock -n -x 8 || fail "could not acquire snapshot contention lock"
    if run_machine a "$PUSH_COMMAND" >"$TEST_ROOT/lock-push.log" 2>&1; then
        fail "snapshot push ignored an active handoff lock"
    fi
    assert_contains "$(<"$TEST_ROOT/lock-push.log")" \
        "Codex is running, starting, or another push/pull is active"
    [[ "$(find "$SYNC_ROOT" -maxdepth 1 -type f | wc -l)" == \
       "$lock_snapshot_count" &&
       "$(fixture_state_hash "$TEST_ROOT/a/live")" == "$lock_live_hash" ]] ||
        fail "locked snapshot push mutated state"

    lock_pull_hash="$(fixture_state_hash "$TEST_ROOT/a/live")"
    if run_machine a "$PULL_COMMAND" >"$TEST_ROOT/lock-pull.log" 2>&1; then
        fail "snapshot pull ignored an active handoff lock"
    fi
    assert_contains "$(<"$TEST_ROOT/lock-pull.log")" \
        "Codex is running, starting, or another push/pull is active"
    [[ "$(fixture_state_hash "$TEST_ROOT/a/live")" == "$lock_pull_hash" ]] ||
        fail "locked snapshot pull mutated live state"
    exec 8>&-
    pass "snapshot push and pull reject lock contention without mutation"

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

    corrupt_live_root="$TEST_ROOT/corrupt-live"
    mkdir -p "$corrupt_live_root/live" "$corrupt_live_root/home" \
        "$corrupt_live_root/sync"
    printf 'replace corrupt live state\n' > "$corrupt_live_root/live/payload"
    sqlite3 "$corrupt_live_root/live/state.sqlite" \
        'CREATE TABLE smoke (value TEXT); INSERT INTO smoke VALUES ("ok");'
    dd if=/dev/zero of="$corrupt_live_root/live/state.sqlite" \
        bs=1 count=100 seek=4096 conv=notrunc status=none
    corrupt_source="$TEST_ROOT/corrupt-source"
    mkdir -p "$corrupt_source"
    printf 'valid restored state\n' > "$corrupt_source/payload"
    sqlite3 "$corrupt_source/state.sqlite" \
        'CREATE TABLE smoke (value TEXT); INSERT INTO smoke VALUES ("ok");'
    corrupt_archive="$corrupt_live_root/sync/codex-g0000000001-corrupt.tar.zst"
    make_fixture_archive "$corrupt_source" "$corrupt_archive"
    corrupt_archive_hash="$(sha256sum "$corrupt_archive" | awk '{print $1}')"
    corrupt_state_hash="$(fixture_state_hash "$corrupt_source")"
    printf '%s\n' "$corrupt_archive_hash" > "$corrupt_archive.sha256"
    {
        printf 'format=1\n'
        printf 'generation=1\nsha256=%s\n' "$corrupt_state_hash"
        printf 'created=20260911T000000Z\nhost=host-smoke\narchive=%s\n' \
            "$(basename "$corrupt_archive")"
    } > "$corrupt_archive.state"
    run_isolated "$corrupt_live_root" "$PULL_COMMAND" --force 1 >/dev/null
    [[ "$(<"$corrupt_live_root/live/payload")" == \
       'valid restored state' ]] ||
        fail "forced pull did not bypass corrupt local SQLite"
    pass "forced pull bypasses corrupt local SQLite"

    suffix_root="$TEST_ROOT/suffix-db"
    mkdir -p "$suffix_root/live" "$suffix_root/home" "$suffix_root/sync"
    printf 'suffix live state\n' > "$suffix_root/live/payload"
    sqlite3 "$suffix_root/live/codex-state.db" \
        'CREATE TABLE smoke (value TEXT); INSERT INTO smoke VALUES ("ok");'
    dd if=/dev/zero of="$suffix_root/live/codex-state.db" \
        bs=1 count=100 seek=4096 conv=notrunc status=none
    suffix_archive="$suffix_root/sync/codex-g0000000001-suffix.tar.zst"
    make_fixture_archive "$suffix_root/live" "$suffix_archive"
    suffix_archive_hash="$(sha256sum "$suffix_archive" | awk '{print $1}')"
    suffix_state_hash="$(fixture_state_hash "$suffix_root/live")"
    printf '%s\n' "$suffix_archive_hash" > "$suffix_archive.sha256"
    {
        printf 'format=1\ngeneration=1\nsha256=%s\n' "$suffix_state_hash"
        printf 'created=20260911T000000Z\nhost=host-smoke\narchive=%s\n' \
            "$(basename "$suffix_archive")"
    } > "$suffix_archive.state"
    if run_isolated "$suffix_root" "$PULL_COMMAND" --force 1 \
        >"$suffix_root/suffix.log" 2>&1; then
        fail "forced pull accepted corrupt non-.sqlite database"
    fi
    grep -Eq 'SQLite (corruption detected|check failed)' \
        "$suffix_root/suffix.log" ||
        fail "corrupt non-.sqlite database was not rejected"

    sidecar_root="$TEST_ROOT/sidecars"
    mkdir -p "$sidecar_root/live" "$sidecar_root/home" "$sidecar_root/sync"
    printf 'sidecar payload\n' > "$sidecar_root/live/payload"
    sidecar_db="$sidecar_root/live/codex-state.db"
    sidecar_fifo="$sidecar_root/writer.fifo"
    mkfifo "$sidecar_fifo"
    sqlite3 "$sidecar_db" < "$sidecar_fifo" >"$sidecar_root/writer.log" 2>&1 &
    sidecar_writer=$!
    exec 7>"$sidecar_fifo"
    printf '%s\n' \
        'PRAGMA journal_mode=WAL;' \
        'PRAGMA wal_autocheckpoint=0;' \
        'CREATE TABLE smoke (value TEXT);' \
        'BEGIN IMMEDIATE;' \
        'INSERT INTO smoke VALUES ("committed in WAL");' \
        'COMMIT;' >&7
    for attempt in {1..20}; do
        [[ -f "$sidecar_db-wal" && -f "$sidecar_db-shm" ]] && break
        sleep 0.05
    done
    [[ -f "$sidecar_db-wal" && -f "$sidecar_db-shm" ]] ||
        fail "SQLite writer did not create WAL/SHM sidecars"
    sidecar_archive="$sidecar_root/sync/codex-g0000000001-sidecars.tar.zst"
    make_fixture_archive "$sidecar_root/live" "$sidecar_archive"
    sidecar_archive_hash="$(sha256sum "$sidecar_archive" | awk '{print $1}')"
    sidecar_state_hash="$(fixture_state_hash "$sidecar_root/live")"
    sidecar_main_hash="$(sha256sum "$sidecar_db" | awk '{print $1}')"
    sidecar_wal_hash="$(sha256sum "$sidecar_db-wal" | awk '{print $1}')"
    sidecar_shm_hash="$(sha256sum "$sidecar_db-shm" | awk '{print $1}')"
    exec 7>&-
    wait "$sidecar_writer"
    rm -f -- "$sidecar_fifo"
    printf '%s\n' "$sidecar_archive_hash" > "$sidecar_archive.sha256"
    {
        printf 'format=1\ngeneration=1\nsha256=%s\n' "$sidecar_state_hash"
        printf 'created=20260911T000000Z\nhost=host-smoke\narchive=%s\n' \
            "$(basename "$sidecar_archive")"
    } > "$sidecar_archive.state"
    run_isolated "$sidecar_root" "$PULL_COMMAND" --force 1 >/dev/null
    [[ -f "$sidecar_root/live/codex-state.db-wal" &&
       -f "$sidecar_root/live/codex-state.db-shm" ]] ||
        fail "SQLite WAL/SHM sidecars did not survive restore"
    [[ "$(sha256sum "$sidecar_root/live/codex-state.db" | awk '{print $1}')" == \
       "$sidecar_main_hash" &&
       "$(sha256sum "$sidecar_root/live/codex-state.db-wal" | awk '{print $1}')" == \
       "$sidecar_wal_hash" &&
       "$(sha256sum "$sidecar_root/live/codex-state.db-shm" | awk '{print $1}')" == \
       "$sidecar_shm_hash" ]] ||
        fail "SQLite main/WAL/SHM bytes changed during restore"
    sidecar_no_change="$(run_isolated "$sidecar_root" "$PULL_COMMAND")"
    assert_contains "$sidecar_no_change" "No changes"
    [[ "$(fixture_state_hash "$sidecar_root/live")" == "$sidecar_state_hash" ]] ||
        fail "restored SQLite state hash differs from snapshot hash"
    sidecar_query_root="$TEST_ROOT/sidecar-query"
    mkdir -p "$sidecar_query_root"
    cp -- "$sidecar_root/live/codex-state.db" \
        "$sidecar_root/live/codex-state.db-wal" \
        "$sidecar_root/live/codex-state.db-shm" "$sidecar_query_root/"
    [[ "$(sqlite3 "$sidecar_query_root/codex-state.db" \
        'SELECT value FROM smoke;')" == 'committed in WAL' ]] ||
        fail "restored SQLite state did not include committed WAL contents"
    pass "non-.sqlite databases are validated and live WAL/SHM state survives restore"

    nonmutating_root="$TEST_ROOT/nonmutating"
    mkdir -p "$nonmutating_root/live" "$nonmutating_root/home" \
        "$nonmutating_root/sync"
    printf 'must survive validation failures\n' > "$nonmutating_root/live/payload"
    nonmutating_archive='codex-g0000000001-invalid.tar.zst'
    printf 'not a compressed archive\n' > \
        "$nonmutating_root/sync/$nonmutating_archive"
    nonmutating_archive_hash="$(sha256sum \
        "$nonmutating_root/sync/$nonmutating_archive" | awk '{print $1}')"
    printf '%s\n' "$nonmutating_archive_hash" > \
        "$nonmutating_root/sync/$nonmutating_archive.sha256"
    {
        printf 'format=1\ngeneration=1\nsha256=%s\n' "$generation_one_hash"
        printf 'created=20260911T000000Z\nhost=host-smoke\narchive=%s\n' \
            "$nonmutating_archive"
    } > "$nonmutating_root/sync/$nonmutating_archive.state"
    if run_isolated "$nonmutating_root" "$PULL_COMMAND" --force 1 \
        >"$nonmutating_root/bad-archive.log" 2>&1; then
        fail "forced pull accepted malformed archive"
    fi
    [[ "$(<"$nonmutating_root/live/payload")" == \
       'must survive validation failures' ]] ||
        fail "malformed archive changed live state"

    make_fixture_archive "$nonmutating_root/live" \
        "$nonmutating_root/sync/codex-g0000000002-hash.tar.zst"
    hash_archive="$nonmutating_root/sync/codex-g0000000002-hash.tar.zst"
    sha256sum "$hash_archive" | awk '{print $1}' > "$hash_archive.sha256"
    {
        printf 'format=1\ngeneration=2\nsha256=%s\n' "$incomplete_hash"
        printf 'created=20260911T000000Z\nhost=host-smoke\narchive=%s\n' \
            "$(basename "$hash_archive")"
    } > "$hash_archive.state"
    if run_isolated "$nonmutating_root" "$PULL_COMMAND" --force 2 \
        >"$nonmutating_root/hash.log" 2>&1; then
        fail "forced pull accepted restored hash mismatch"
    fi
    assert_contains "$(<"$nonmutating_root/hash.log")" \
        "Restored state hash does not match"
    [[ "$(<"$nonmutating_root/live/payload")" == \
       'must survive validation failures' ]] ||
        fail "restored hash mismatch changed live state"
    pass "bad archives and restored hash mismatches are nonmutating"

    handoff_source="$TEST_ROOT/handoff-a"
    handoff_destination="$TEST_ROOT/handoff-b"
    mkdir -p "$handoff_source/live" "$handoff_source/home" \
        "$handoff_destination/live" "$handoff_destination/home"
    printf 'contextual handoff state\n' > "$handoff_source/live/payload"
    mkdir -p "$handoff_sync_root"
    run_handoff handoff-a "$PUSH_COMMAND" >/dev/null
    handoff_state="$(find "$handoff_sync_root" -maxdepth 1 -name '*.state' -print -quit)"
    [[ -n "$handoff_state" ]] || fail "contextual push did not publish snapshot metadata"
    for handoff_field in \
        'handoff_format=1' \
        "project=$handoff_project" \
        "lane=$handoff_lane" \
        "required_commit=$handoff_commit" \
        "runtime_profile=$handoff_profile" \
        "runtime_version=$handoff_version" \
        "runtime_revision=$handoff_revision" \
        "onboarding_sha256=$handoff_onboarding_hash"; do
        grep -Fxq -- "$handoff_field" "$handoff_state" ||
            fail "contextual push omitted $handoff_field"
    done

    original_handoff_commit="$handoff_commit"
    handoff_commit='cccccccccccccccccccccccccccccccccccccccc'
    updated_handoff_output="$(run_handoff handoff-a "$PUSH_COMMAND")"
    assert_contains "$updated_handoff_output" \
        "publishing updated lane handoff requirements"
    updated_handoff_state="$(
        grep -l '^generation=2$' "$handoff_sync_root"/*.state
    )"
    [[ -n "$updated_handoff_state" ]] ||
        fail "changed handoff requirements did not publish a new generation"
    grep -Fxq "required_commit=$handoff_commit" "$updated_handoff_state" ||
        fail "new handoff generation did not record changed requirements"
    handoff_commit="$original_handoff_commit"

    mkdir -p "$TEST_ROOT/handoff-c/live" "$TEST_ROOT/handoff-c/home"
    cp -- "$handoff_source/live/payload" "$TEST_ROOT/handoff-c/live/payload"
    no_base_handoff_output="$(run_handoff handoff-c "$PUSH_COMMAND")"
    assert_contains "$no_base_handoff_output" \
        "publishing lane handoff requirements"
    no_base_handoff_state="$(
        grep -l '^generation=3$' "$handoff_sync_root"/*.state
    )"
    [[ -n "$no_base_handoff_state" ]] ||
        fail "matching state without a baseline did not advance handoff metadata"
    grep -Fxq "required_commit=$handoff_commit" "$no_base_handoff_state" ||
        fail "no-baseline handoff generation recorded the wrong requirements"
    handoff_list="$(run_handoff handoff-a "$PULL_COMMAND" --list)"
    assert_contains "$handoff_list" "REQUIREMENTS"
    assert_contains "$handoff_list" "$handoff_project/$handoff_lane"
    assert_contains "$handoff_list" "${handoff_commit:0:12}"
    assert_contains "$handoff_list" \
        "$handoff_profile:$handoff_version@${handoff_revision:0:12}"

    partial_root="$TEST_ROOT/handoff-partial"
    mkdir -p "$partial_root/live" "$partial_root/home"
    printf 'partial context survives\n' > "$partial_root/live/payload"
    if env \
        "HOME=$partial_root/home" \
        "CODEX_DIR=$partial_root/live" \
        "CODEX_SYNC_DIR=$partial_root/sync" \
        "CODEX_LOCK_FILE=$partial_root/handoff.lock" \
        "XDG_STATE_HOME=$partial_root/state" \
        "CODEX_HANDOFF_PROJECT=$handoff_project" \
        "$PUSH_COMMAND" >"$partial_root/partial.log" 2>&1; then
        fail "partial handoff context was accepted"
    fi
    [[ ! -e "$partial_root/sync" && ! -e "$partial_root/state" &&
       ! -e "$partial_root/handoff.lock" ]] ||
        fail "partial handoff context mutated synchronization state"

    printf 'destination survives missing lane context\n' > \
        "$handoff_destination/live/payload"
    handoff_destination_before="$(fixture_state_hash "$handoff_destination/live")"
    if env \
        "HOME=$handoff_destination/home" \
        "CODEX_DIR=$handoff_destination/live" \
        "CODEX_SYNC_DIR=$handoff_sync_root" \
        "CODEX_LOCK_FILE=$TEST_ROOT/handoff.lock" \
        "XDG_STATE_HOME=$handoff_destination/state" \
        "$PULL_COMMAND" --force 1 \
        >"$handoff_destination/missing-context.log" 2>&1; then
        fail "contextual restore without lane context was accepted"
    fi
    [[ "$(fixture_state_hash "$handoff_destination/live")" == \
       "$handoff_destination_before" ]] ||
        fail "missing lane context changed destination state"

    for wrong_context in commit runtime onboarding; do
        wrong_root="$TEST_ROOT/handoff-wrong-$wrong_context"
        mkdir -p "$wrong_root/live" "$wrong_root/home"
        printf 'wrong context survives\n' > "$wrong_root/live/payload"
        wrong_before="$(fixture_state_hash "$wrong_root/live")"
        case "$wrong_context" in
            commit) wrong_value='cccccccccccccccccccccccccccccccccccccccc' ;;
            runtime) wrong_value='other-version' ;;
            onboarding) wrong_value='dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd' ;;
        esac
        if env \
            "HOME=$wrong_root/home" \
            "CODEX_DIR=$wrong_root/live" \
            "CODEX_SYNC_DIR=$handoff_sync_root" \
            "CODEX_LOCK_FILE=$TEST_ROOT/handoff.lock" \
            "XDG_STATE_HOME=$wrong_root/state" \
            "CODEX_HANDOFF_PROJECT=$handoff_project" \
            "CODEX_HANDOFF_LANE=$handoff_lane" \
            "CODEX_HANDOFF_COMMIT=$([[ "$wrong_context" == commit ]] && printf '%s' "$wrong_value" || printf '%s' "$handoff_commit")" \
            "CODEX_HANDOFF_RUNTIME_PROFILE=$handoff_profile" \
            "CODEX_HANDOFF_RUNTIME_VERSION=$([[ "$wrong_context" == runtime ]] && printf '%s' "$wrong_value" || printf '%s' "$handoff_version")" \
            "CODEX_HANDOFF_RUNTIME_REVISION=$handoff_revision" \
            "CODEX_HANDOFF_ONBOARDING_SHA256=$([[ "$wrong_context" == onboarding ]] && printf '%s' "$wrong_value" || printf '%s' "$handoff_onboarding_hash")" \
            'CODEX_HANDOFF_READY=1' \
            "$PULL_COMMAND" --force 1 >"$wrong_root/$wrong_context.log" 2>&1; then
            fail "wrong $wrong_context handoff context was accepted"
        fi
        [[ "$(fixture_state_hash "$wrong_root/live")" == "$wrong_before" ]] ||
            fail "wrong $wrong_context context changed live state"
    done

    run_handoff handoff-b "$PULL_COMMAND" --force 1 >/dev/null
    [[ "$(<"$handoff_destination/live/payload")" == \
       'contextual handoff state' ]] ||
        fail "matching handoff context did not restore across machine roots"
    pass "lane handoff metadata is published, validated, and nonmutating"

    rollback_root="$TEST_ROOT/rollback"
    mkdir -p "$rollback_root/live" "$rollback_root/home" "$rollback_root/sync"
    printf 'rollback original\n' > "$rollback_root/live/payload"
    rollback_source="$TEST_ROOT/rollback-source"
    mkdir -p "$rollback_source"
    printf 'rollback restored\n' > "$rollback_source/payload"
    rollback_archive="$rollback_root/sync/codex-g0000000001-rollback.tar.zst"
    make_fixture_archive "$rollback_source" "$rollback_archive"
    rollback_archive_hash="$(sha256sum "$rollback_archive" | awk '{print $1}')"
    rollback_state_hash="$(fixture_state_hash "$rollback_source")"
    printf '%s\n' "$rollback_archive_hash" > "$rollback_archive.sha256"
    {
        printf 'format=1\ngeneration=1\nsha256=%s\n' "$rollback_state_hash"
        printf 'created=20260911T000000Z\nhost=host-smoke\narchive=%s\n' \
            "$(basename "$rollback_archive")"
    } > "$rollback_archive.state"

    rollback_bin="$TEST_ROOT/rollback-bin"
    mkdir -p "$rollback_bin"
    rollback_mv="$rollback_bin/mv"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'if [[ "${2:-}" == */content && "${3:-}" == "'$rollback_root'/live" ]]; then' \
        '    exit 1' \
        'fi' \
        'exec /bin/mv "$@"' > "$rollback_mv"
    chmod 755 "$rollback_mv"
    if PATH="$rollback_bin:$PATH" run_isolated "$rollback_root" "$PULL_COMMAND" --force 1 \
        >"$rollback_root/success.log" 2>&1; then
        fail "pull unexpectedly succeeded after mocked install failure"
    fi
    rollback_success_log="$(<"$rollback_root/success.log")"
    assert_contains "$rollback_success_log" "rollback"
    assert_contains "$rollback_success_log" "$rollback_root/live.backup-"
    [[ "$(<"$rollback_root/live/payload")" == 'rollback original' ]] ||
        fail "successful rollback did not preserve original live state"

    rollback_fail_bin="$TEST_ROOT/rollback-fail-bin"
    mkdir -p "$rollback_fail_bin"
    rollback_mv_fail="$rollback_fail_bin/mv"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'if [[ "${2:-}" == */content && "${3:-}" == "'$rollback_root'/live" ]]; then' \
        '    exit 1' \
        'fi' \
        'if [[ "${2:-}" == "'$rollback_root'/live.backup-"* && "${3:-}" == "'$rollback_root'/live" ]]; then' \
        '    exit 1' \
        'fi' \
        'exec /bin/mv "$@"' > "$rollback_mv_fail"
    chmod 755 "$rollback_mv_fail"
    # A fresh live directory is required because the previous case restored it.
    printf 'rollback original 2\n' > "$rollback_root/live/payload"
    if PATH="$rollback_fail_bin:$PATH" run_isolated "$rollback_root" "$PULL_COMMAND" --force 1 \
        >"$rollback_root/failure.log" 2>&1; then
        fail "pull unexpectedly succeeded after mocked install and rollback failure"
    fi
    rollback_failure_log="$(<"$rollback_root/failure.log")"
    assert_contains "$rollback_failure_log" "rollback"
    assert_contains "$rollback_failure_log" "$rollback_root/live.backup-"
    pass "install failure reports backup and rollback outcome"
else
    printf 'skip - snapshot integration (CODEX_TEST_SKIP_SYNC=1)\n'
fi
