#!/usr/bin/env bash
set -Eeuo pipefail

phase_script="${1:-}"
shift || true
[[ -n "$phase_script" && $# -ge 1 ]] || {
    printf 'host-smoke: image phase wrapper requires a script and arguments\n' >&2
    exit 2
}

kill_after_seconds="${CODEX_TEST_IMAGE_KILL_AFTER_SECONDS:-5}"
[[ "$kill_after_seconds" =~ ^[1-9][0-9]*$ ]] || {
    printf 'host-smoke: CODEX_TEST_IMAGE_KILL_AFTER_SECONDS must be a positive integer\n' >&2
    exit 2
}

terminate_phase_group() {
    trap '' TERM INT
    kill -TERM -- "-$$" 2>/dev/null || true
    sleep "$kill_after_seconds"
    kill -KILL -- "-$$" 2>/dev/null || true
}
trap terminate_phase_group TERM INT

set +e
/bin/bash "$phase_script" "$@" &
phase_pid=$!
wait "$phase_pid"
phase_status=$?
set -e

trap - TERM INT
exit "$phase_status"
