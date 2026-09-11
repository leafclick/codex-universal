#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
workflow_skill="${2:-/usr/local/share/codex-universal/workflow/skills/clojure-development}"
TEST_ROOT="$(mktemp -d)"
namespace_service_pid=""
namespace_service_pgid=""
config_service_pid=""
supervisor_pid=""

stop_namespace_service() {
    local pgid="${namespace_service_pgid:-}"
    [[ -n "$pgid" ]] || return 0
    kill -TERM -- "-$pgid" 2>/dev/null || true
    for _ in {1..20}; do
        kill -0 -- "-$pgid" 2>/dev/null || break
        sleep 0.05
    done
    kill -KILL -- "-$pgid" 2>/dev/null || true
    if [[ -n "${namespace_service_pid:-}" ]]; then
        wait "$namespace_service_pid" 2>/dev/null || true
    fi
    namespace_service_pid=""
    namespace_service_pgid=""
}

cleanup() {
    stop_namespace_service
    if [[ -n "${supervisor_pid:-}" ]]; then
        kill "$supervisor_pid" 2>/dev/null || true
        wait "$supervisor_pid" 2>/dev/null || true
    fi
    if [[ -n "${config_service_pid:-}" ]]; then
        kill "$config_service_pid" 2>/dev/null || true
        wait "$config_service_pid" 2>/dev/null || true
    fi
    rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

command -v bb >/dev/null 2>&1 || fail "tested image is missing Babashka"
command -v python3 >/dev/null 2>&1 || fail "tested image is missing Python"

python3 "$ROOT/tests/fixtures/check-clojure-network-context.py" \
    "$workflow_skill/scripts/clojure-development" ||
    fail "Clojure helper network preflight changed state or missed elevation"
process_supervisor="$workflow_skill/scripts/clojure-process-supervisor"
supervisor_fixture="$TEST_ROOT/clojure-supervisor-state"
supervisor_project="$TEST_ROOT/clojure-supervisor-project"
mkdir -p -- "$supervisor_fixture" "$supervisor_project"
"$process_supervisor" service \
    --control "$supervisor_fixture/control.fifo" \
    --project-root "$supervisor_project" \
    --state-root "$supervisor_fixture" &
supervisor_pid=$!
for _ in {1..100}; do
    [[ -p "$supervisor_fixture/control.fifo" ]] && break
    sleep 0.02
done
printf '[]\n\377\n' > "$supervisor_fixture/control.fifo"
"$process_supervisor" control \
    "$supervisor_fixture/control.fifo" neutral-token status \
    | grep -Fxq stopped ||
    fail "malformed FIFO input terminated the Clojure process supervisor"
"$process_supervisor" start \
    --log "$supervisor_fixture/repl.log" \
    --dir "$supervisor_project" \
    "$supervisor_fixture/control.fifo" neutral-token \
    -- bash -c 'trap "" TERM; (trap "" TERM; sleep 30) & wait' \
    | grep -Eq '^started [0-9]+$' ||
    fail "Clojure process supervisor did not start an owned process tree"
"$process_supervisor" control \
    "$supervisor_fixture/control.fifo" neutral-token status \
    | grep -Eq '^running [0-9]+$' ||
    fail "Clojure process supervisor did not prove cross-command ownership"
"$process_supervisor" control \
    "$supervisor_fixture/control.fifo" neutral-token stop \
    | grep -Fxq 'stopped confirmed' ||
    fail "Clojure process supervisor did not confirm process-tree termination"
kill "$supervisor_pid"
wait "$supervisor_pid" ||
    fail "Clojure process supervisor failed after confirmed stop"
supervisor_pid=""
[[ ! -e "$supervisor_fixture/control.fifo" ]] ||
    fail "Clojure process supervisor left a stale control channel"

helper="$workflow_skill/scripts/clojure-development"
if command -v bwrap >/dev/null 2>&1; then
    namespace_fixture="$TEST_ROOT/clojure-namespace-state"
    namespace_project="$TEST_ROOT/clojure-namespace-project"
    mkdir -p -- "$namespace_fixture" "$namespace_project/.git"
    setsid bwrap \
        --unshare-user \
        --unshare-ipc \
        --unshare-pid \
        --unshare-net \
        --unshare-uts \
        --unshare-cgroup-try \
        --die-with-parent \
        --new-session \
        --ro-bind / / \
        --dev /dev \
        --tmpfs /proc \
        --dir /proc/self \
        --symlink /bin/sh /proc/self/exe \
        --bind "$TEST_ROOT" "$TEST_ROOT" \
        --ro-bind "$namespace_project/.git" "$namespace_project/.git" \
        --chdir "$namespace_project" \
        -- "$process_supervisor" service \
        --control "$namespace_fixture/service-control.fifo" \
        --project-root "$namespace_project" \
        --state-root "$namespace_fixture" \
        --namespace-scoped \
        > "$namespace_fixture/service.out" \
        2> "$namespace_fixture/service.err" &
    namespace_service_pid=$!
    namespace_service_pgid="$namespace_service_pid"
    for _ in {1..100}; do
        [[ -p "$namespace_fixture/service-control.fifo" ]] && break
        kill -0 "$namespace_service_pid" 2>/dev/null || break
        sleep 0.02
    done
    if [[ -p "$namespace_fixture/service-control.fifo" ]]; then
        "$process_supervisor" start \
            --log "$namespace_fixture/repl.log" \
            --dir "$namespace_project" \
            "$namespace_fixture/service-control.fifo" namespace-token \
            -- bash -c \
            '[[ "$(readlink /proc/self/exe)" == /bin/sh && ! -e /proc/1/root ]]; setsid bash -c '\''trap "" TERM; sleep 30'\'' & sleep 30' \
            | grep -Eq '^started [0-9]+$' ||
            fail "namespace-scoped supervisor lost its minimal proc compatibility boundary"
        "$process_supervisor" control \
            "$namespace_fixture/service-control.fifo" namespace-token stop \
            | grep -Fxq 'stopped confirmed' ||
            fail "namespace-scoped supervisor did not kill a detached descendant"
        "$process_supervisor" control \
            "$namespace_fixture/service-control.fifo" namespace-token status \
            | grep -Fxq stopped ||
            fail "namespace-scoped supervisor released incomplete process state"

        mkdir -p -- "$namespace_project/.codex"
        printf '%s\n' \
            "{:runtimes {:isolated {:kind :lein :repl [\"python3\" \"$ROOT/tests/fixtures/fake-nrepl.py\" \"--interfaces-file\" \"$namespace_fixture/interfaces.txt\"]}}}" \
            > "$namespace_project/.codex/clojure-development.edn"
        CODEX_PROJECT_ROOT="$namespace_project" \
            CODEX_CLOJURE_STATE_DIR="$namespace_fixture" \
            bb "$helper" repl-start isolated \
            > "$namespace_fixture/unix-start.out" ||
            fail "networkless REPL failed to expose its private Unix transport"
        grep -Fq ':transport :unix' "$namespace_fixture/unix-start.out" &&
            grep -Fq ':endpoint-status :reachable' \
                "$namespace_fixture/unix-start.out" ||
            fail "networkless REPL did not report reachable Unix transport"
        [[ "$(<"$namespace_fixture/interfaces.txt")" == lo ]] ||
            fail "persistent REPL namespace exposes a non-loopback interface"
        [[ "$(stat -c %a "$namespace_fixture/repl.sock")" == 600 ]] ||
            fail "persistent REPL Unix socket is not private"
        CODEX_PROJECT_ROOT="$namespace_project" \
            CODEX_CLOJURE_STATE_DIR="$namespace_fixture" \
            bb "$helper" repl-eval isolated-transport \
            > "$namespace_fixture/unix-eval.out"
        grep -Fq ':status :done' "$namespace_fixture/unix-eval.out" &&
            grep -Fq ':text "isolated-transport"' \
                "$namespace_fixture/unix-eval.out" ||
            fail "Unix transport did not carry nREPL evaluation"
        CODEX_PROJECT_ROOT="$namespace_project" \
            CODEX_CLOJURE_STATE_DIR="$namespace_fixture" \
            bb "$helper" repl-stop \
            > "$namespace_fixture/unix-stop.out"
        grep -Fq ':termination :confirmed' \
            "$namespace_fixture/unix-stop.out" ||
            fail "networkless REPL did not stop with confirmed termination"
        [[ ! -e "$namespace_fixture/repl.sock" ]] ||
            fail "networkless REPL left its Unix socket behind"
        stop_namespace_service
    else
        stop_namespace_service
        printf 'skip - namespace-scoped REPL supervisor (Bubblewrap unavailable to this user)\n'
    fi
fi

config_fixture="$TEST_ROOT/clojure-config"
config_state="$TEST_ROOT/clojure-runtime"
fake_nrepl="$ROOT/tests/fixtures/fake-nrepl.py"
mkdir -p -- "$config_fixture/.codex" "$config_fixture/bb-work"
mkdir -p -- "$config_state"
"$process_supervisor" service \
    --control "$config_state/service-control.fifo" \
    --project-root "$config_fixture" \
    --state-root "$config_state" &
config_service_pid=$!
for _ in {1..100}; do
    [[ -p "$config_state/service-control.fifo" ]] && break
    sleep 0.02
done
[[ -p "$config_state/service-control.fifo" ]] ||
    fail "neutral Clojure REPL service did not become ready"
printf '%s\n' \
    '{:default-runtime :dev :runtimes {:dev {:kind :deps :repl ["clojure" "-M:dev" "-m" "nrepl.cmdline" "--bind" "127.0.0.1" "--port" "0"]}} :tests {:unit {:command ["clojure" "-M:test"] :fresh-process :when-required}}}' \
    > "$config_fixture/.codex/clojure-development.edn"
CODEX_PROJECT_ROOT="$config_fixture" \
    CODEX_CLOJURE_STATE_DIR="$config_state" \
    bb "$workflow_skill/scripts/clojure-development" config-validate \
    | grep -Fxq '{:status :valid}' ||
    fail "Clojure development config validation rejected a valid argv configuration"
printf '%s\n' \
    '{:default-runtime :dev :runtimes {:dev {:kind :deps :repl "clojure -M:dev"}}}' \
    > "$config_fixture/.codex/clojure-development.edn"
if CODEX_PROJECT_ROOT="$config_fixture" \
    CODEX_CLOJURE_STATE_DIR="$config_state" \
    bb "$workflow_skill/scripts/clojure-development" config-validate \
    >"$config_fixture/invalid.out" 2>&1; then
    fail "Clojure development config accepted a shell-string command"
fi
grep -Fq 'argv vector' "$config_fixture/invalid.out" ||
    fail "Clojure development config rejection is not useful"
long_command_arg="$(printf '%02049d' 0)"
printf \
    '{:runtimes {:dev {:kind :lein :repl ["%s"]}}}\n' \
    "$long_command_arg" \
    > "$config_fixture/.codex/clojure-development.edn"
if CODEX_PROJECT_ROOT="$config_fixture" \
    CODEX_CLOJURE_STATE_DIR="$config_state" \
    bb "$helper" config-validate \
    > "$config_fixture/oversized-command.out" 2>&1; then
    fail "Clojure config accepted a command larger than its service transport"
fi
grep -Fq '2048-byte process-service transport limit' \
    "$config_fixture/oversized-command.out" ||
    fail "oversized Clojure command rejection was not useful"

printf '%s\n' \
    "{:runtimes {:only {:kind :lein :repl [\"python3\" \"$fake_nrepl\"]}}}" \
    > "$config_fixture/.codex/clojure-development.edn"
if ! CODEX_PROJECT_ROOT="$config_fixture" \
    CODEX_CLOJURE_STATE_DIR="$config_state" \
    bb "$helper" repl-start > "$config_fixture/start.out"; then
    tail -c 4096 -- "$config_state/repl.log" >&2 || true
    fail "single-runtime REPL process failed during startup"
fi
grep -Fq ':runtime :only' "$config_fixture/start.out" &&
    grep -Fq ':status :running' "$config_fixture/start.out" ||
    fail "single-runtime REPL startup without a default failed"
CODEX_PROJECT_ROOT="$config_fixture" \
    CODEX_CLOJURE_STATE_DIR="$config_state" \
    bb "$helper" repl-eval multiple-values > "$config_fixture/multiple.out"
grep -Fq ':status :done' "$config_fixture/multiple.out" &&
    grep -Fq ':text "\none\n\ncafé"' "$config_fixture/multiple.out" &&
    grep -Fq ':value-count 4' "$config_fixture/multiple.out" ||
    {
        tail -c 4096 -- "$config_fixture/multiple.out" >&2 || true
        fail "nREPL evaluation did not preserve separate values"
    }
CODEX_PROJECT_ROOT="$config_fixture" \
    CODEX_CLOJURE_STATE_DIR="$config_state" \
    bb "$helper" repl-eval eval-error > "$config_fixture/eval-error.out"
grep -Fq ':status :evaluation-error' "$config_fixture/eval-error.out" ||
    fail "nREPL evaluation error was reported as successful"
CODEX_PROJECT_ROOT="$config_fixture" \
    CODEX_CLOJURE_STATE_DIR="$config_state" \
    CODEX_CLOJURE_EVAL_TIMEOUT_MS=100 \
    bb "$helper" repl-eval timeout > "$config_fixture/timeout.out"
grep -Fq ':status :timeout' "$config_fixture/timeout.out" &&
    grep -Fq ':execution-state :unknown' "$config_fixture/timeout.out" &&
    grep -Fq 'partial-before-timeout' "$config_fixture/timeout.out" ||
    fail "nREPL timeout did not retain partial evidence and uncertainty"
raw_record="$(
    bb -e '(println (:raw-record (read-string (slurp *in*))))' \
        < "$config_fixture/timeout.out"
)"
[[ -s "$raw_record" ]] ||
    fail "nREPL timeout referenced a missing raw evidence record"
if CODEX_PROJECT_ROOT="$config_fixture" \
    CODEX_CLOJURE_STATE_DIR="$config_state" \
    bb "$helper" repl-eval retry \
    > "$config_fixture/retry.out" 2>&1; then
    fail "nREPL helper retried after an unresolved timeout"
fi
grep -Fq 'unknown server execution state' "$config_fixture/retry.out" ||
    fail "nREPL retry rejection did not explain the unresolved state"
CODEX_PROJECT_ROOT="$config_fixture" \
    CODEX_CLOJURE_STATE_DIR="$config_state" \
    bb "$helper" repl-status > "$config_fixture/timeout-status.out"
grep -Fq ':evaluation {:status :unknown' "$config_fixture/timeout-status.out" ||
    fail "nREPL status lost unresolved timeout state"
CODEX_PROJECT_ROOT="$config_fixture" \
    CODEX_CLOJURE_STATE_DIR="$config_state" \
    bb "$helper" repl-stop > "$config_fixture/stop.out"
grep -Fq ':termination :confirmed' "$config_fixture/stop.out" ||
    fail "nREPL stop did not confirm process termination"
[[ ! -e "$config_state/state.edn" ]] ||
    fail "nREPL stop removed neither the process nor its state"
CODEX_PROJECT_ROOT="$config_fixture" \
    CODEX_CLOJURE_STATE_DIR="$config_state" \
    bb "$helper" repl-start > "$config_fixture/recovery-start.out"
CODEX_PROJECT_ROOT="$config_fixture" \
    CODEX_CLOJURE_STATE_DIR="$config_state" \
    bb "$helper" repl-eval recovered > "$config_fixture/recovery-eval.out"
grep -Fq ':status :done' "$config_fixture/recovery-eval.out" &&
    grep -Fq ':text "recovered"' "$config_fixture/recovery-eval.out" ||
    fail "nREPL did not recover after the required timeout stop/restart"
CODEX_PROJECT_ROOT="$config_fixture" \
    CODEX_CLOJURE_STATE_DIR="$config_state" \
    bb "$helper" repl-eval disconnect > "$config_fixture/disconnect.out"
grep -Fq ':status :connection-failure' "$config_fixture/disconnect.out" &&
    grep -Fq ':execution-state :unknown' "$config_fixture/disconnect.out" &&
    grep -Fq 'partial-before-disconnect' "$config_fixture/disconnect.out" ||
    fail "nREPL disconnection did not retain partial evidence and uncertainty"
raw_record="$(
    bb -e '(println (:raw-record (read-string (slurp *in*))))' \
        < "$config_fixture/disconnect.out"
)"
[[ -s "$raw_record" ]] ||
    fail "nREPL disconnection referenced a missing raw evidence record"
if CODEX_PROJECT_ROOT="$config_fixture" \
    CODEX_CLOJURE_STATE_DIR="$config_state" \
    bb "$helper" repl-eval retry-after-disconnect \
    > "$config_fixture/disconnect-retry.out" 2>&1; then
    fail "nREPL helper retried after an unresolved disconnection"
fi
grep -Fq 'unknown server execution state' \
    "$config_fixture/disconnect-retry.out" ||
    fail "nREPL disconnection retry rejection did not explain the unresolved state"
CODEX_PROJECT_ROOT="$config_fixture" \
    CODEX_CLOJURE_STATE_DIR="$config_state" \
    bb "$helper" repl-stop > "$config_fixture/disconnect-stop.out"
grep -Fq ':termination :confirmed' "$config_fixture/disconnect-stop.out" ||
    fail "nREPL disconnection recovery stop did not confirm termination"
CODEX_PROJECT_ROOT="$config_fixture" \
    CODEX_CLOJURE_STATE_DIR="$config_state" \
    bb "$helper" repl-start > "$config_fixture/decoder-start.out"
CODEX_PROJECT_ROOT="$config_fixture" \
    CODEX_CLOJURE_STATE_DIR="$config_state" \
    bb "$helper" repl-eval oversized > "$config_fixture/oversized.out"
grep -Fq ':status :connection-failure' "$config_fixture/oversized.out" &&
    grep -Fq 'exceeds the bounded decoder limit' "$config_fixture/oversized.out" ||
    fail "nREPL decoder accepted an unbounded response field"
CODEX_PROJECT_ROOT="$config_fixture" \
    CODEX_CLOJURE_STATE_DIR="$config_state" \
    bb "$helper" repl-stop > "$config_fixture/recovery-stop.out"
grep -Fq ':termination :confirmed' "$config_fixture/recovery-stop.out" ||
    fail "nREPL recovery stop did not confirm termination"

printf '%s\n' \
    '{:default-runtime :jvm :runtimes {:jvm {:kind :lein :repl ["unused"]} :bb {:kind :babashka :workdir "bb-work" :one-off ["bb" "-e"]}}}' \
    > "$config_fixture/.codex/clojure-development.edn"
CODEX_PROJECT_ROOT="$config_fixture" \
    CODEX_CLOJURE_STATE_DIR="$config_state" \
    bb "$helper" one-off '(print (System/getProperty "user.dir"))' bb \
    > "$config_fixture/bb-workdir.out"
grep -Fq ":status :done" "$config_fixture/bb-workdir.out" &&
    grep -Fq "$config_fixture/bb-work" "$config_fixture/bb-workdir.out" ||
    fail "Babashka one-off ignored its configured workdir"
CODEX_PROJECT_ROOT="$config_fixture" \
    CODEX_CLOJURE_STATE_DIR="$config_state" \
    CODEX_CLOJURE_ONE_OFF_TIMEOUT_MS=100 \
    bb "$helper" one-off '(Thread/sleep 2000)' bb \
    > "$config_fixture/bb-timeout.out"
grep -Fq ':status :timeout' "$config_fixture/bb-timeout.out" &&
    grep -Fq ':termination-confirmed true' "$config_fixture/bb-timeout.out" ||
    fail "Babashka one-off timeout did not confirm termination"

descendant_marker="$TEST_ROOT/one-off-descendant-leak"
printf '%s\n' \
    "{:runtimes {:bb {:kind :babashka :one-off [\"bash\" \"-c\" \"python3 -c 'import os,time; os.setsid(); time.sleep(3); open(\\\"$descendant_marker\\\",\\\"w\\\").write(\\\"leaked\\\")' & wait\" \"fixture\"]}}}" \
    > "$config_fixture/.codex/clojure-development.edn"
CODEX_PROJECT_ROOT="$config_fixture" \
    CODEX_CLOJURE_STATE_DIR="$config_state" \
    CODEX_CLOJURE_ONE_OFF_TIMEOUT_MS=100 \
    bb "$helper" one-off ignored > "$config_fixture/bb-tree-timeout.out"
grep -Fq ':status :timeout' "$config_fixture/bb-tree-timeout.out" &&
    grep -Fq ':termination-confirmed true' "$config_fixture/bb-tree-timeout.out" ||
    fail "Babashka process-tree timeout did not confirm termination"
sleep 1.2
[[ ! -e "$descendant_marker" ]] ||
    fail "Babashka timeout left a descendant process running"

completed_descendant_marker="$TEST_ROOT/one-off-completed-descendant-leak"
printf '%s\n' \
    "{:runtimes {:bb {:kind :babashka :one-off [\"bash\" \"-c\" \"python3 -c 'import os,time; os.setsid(); time.sleep(3); open(\\\"$completed_descendant_marker\\\",\\\"w\\\").write(\\\"leaked\\\")' &\" \"fixture\"]}}}" \
    > "$config_fixture/.codex/clojure-development.edn"
CODEX_PROJECT_ROOT="$config_fixture" \
    CODEX_CLOJURE_STATE_DIR="$config_state" \
    bb "$helper" one-off ignored > "$config_fixture/bb-tree-completed.out"
grep -Fq ':status :done' "$config_fixture/bb-tree-completed.out" &&
    grep -Fq ':termination-confirmed true' "$config_fixture/bb-tree-completed.out" ||
    fail "Babashka normal completion did not clean up surviving descendants"
sleep 1.2
[[ ! -e "$completed_descendant_marker" ]] ||
    fail "Babashka normal completion left a descendant process running"

printf '%s\n' \
    '{:runtimes {:bb {:kind :babashka :one-off ["bash" "-c" "printf %4095s x | tr x a; printf é" "fixture"]}}}' \
    > "$config_fixture/.codex/clojure-development.edn"
CODEX_PROJECT_ROOT="$config_fixture" \
    CODEX_CLOJURE_STATE_DIR="$config_state" \
    bb "$helper" one-off ignored > "$config_fixture/bb-unicode.out"
grep -Fq 'é' "$config_fixture/bb-unicode.out" &&
    ! grep -Fq '�' "$config_fixture/bb-unicode.out" ||
    fail "Babashka output corrupted UTF-8 split across a read boundary"

for unsafe_options in \
    '"--bind" "0.0.0.0"' \
    '"--bind=0.0.0.0"' \
    '"--port=4444"' \
    '"-b" "0.0.0.0"' \
    '"-p" "4444"'; do
    printf \
        '{:runtimes {:dev {:kind :deps :repl ["clojure" "-M:dev" "-m" "nrepl.cmdline" "--bind" "127.0.0.1" "--port" "0" %s]}}}\n' \
        "$unsafe_options" \
        > "$config_fixture/.codex/clojure-development.edn"
    if CODEX_PROJECT_ROOT="$config_fixture" \
        CODEX_CLOJURE_STATE_DIR="$config_state" \
        bb "$helper" config-validate \
        > "$config_fixture/unsafe-option.out" 2>&1; then
        fail "Clojure config accepted conflicting option $unsafe_options"
    fi
done

mkdir -p -- "$config_fixture/unsafe-state"
ln -s -- "$config_fixture/unsafe-state" "$TEST_ROOT/clojure-state-link"
if CODEX_PROJECT_ROOT="$config_fixture" \
    CODEX_CLOJURE_STATE_DIR="$TEST_ROOT/clojure-state-link" \
    bb "$helper" repl-status \
    > "$config_fixture/state-overlap.out" 2>&1; then
    fail "Clojure helper accepted a symlinked state directory inside the project"
fi
grep -Fq 'must not be the filesystem root or overlap the project' \
    "$config_fixture/state-overlap.out" ||
    fail "Clojure state overlap rejection was not useful"
[[ -z "$(find "$config_fixture/unsafe-state" -mindepth 1 -print -quit)" ]] ||
    fail "Clojure helper wrote state through an overlapping symlink"

[[ -z "$(find "$config_state" -maxdepth 1 -name 'response-*' -print -quit)" ]] ||
    fail "Clojure REPL service left an orphaned response file"
kill "$config_service_pid"
wait "$config_service_pid" ||
    fail "neutral Clojure REPL service failed during shutdown"
config_service_pid=""
[[ ! -e "$config_state/service-control.fifo" ]] ||
    fail "neutral Clojure REPL service left a stale control channel"
pass "Clojure development runtime lifecycle and bounded probe evidence"
