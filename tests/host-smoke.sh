#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT="$(mktemp -d)"
namespace_service_pid=""
namespace_service_pgid=""

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
        fail "expected launcher output to contain: $expected"
}

assert_not_contains() {
    local value="$1"
    local unexpected="$2"

    [[ "$value" != *"$unexpected"* ]] ||
        fail "expected launcher output not to contain: $unexpected"
}

for command in bash git grep jq realpath setpriv flock; do
    need "$command"
done

git -C "$ROOT" diff --check
git -C "$ROOT" diff --cached --check

for script in \
    "$ROOT/docker-build.sh" \
    "$ROOT/bin/run-codex" \
    "$ROOT/bin/setup-codex-host-security" \
    "$ROOT/bin/setup-codex-idea" \
    "$ROOT/bin/run-codex-doctor.bash" \
    "$ROOT/bin/codex-push" \
    "$ROOT/bin/codex-pull" \
    "$ROOT/bin/codex-sync-lib" \
    "$ROOT/container/codex-entrypoint" \
    "$ROOT/container/codex-acp-entrypoint" \
    "$ROOT/container/codex-bwrap-cuda" \
    "$ROOT/container/codex-clojure-lsp-mcp" \
    "$ROOT/container/codex-universal-workflow-install" \
    "$ROOT/container/codex-workflow/scripts/codex-worker-observe" \
    "$ROOT/container/install-clojure-tools" \
    "$ROOT/tests/host-smoke-sync.sh"; do
    bash -n "$script"
done
for script in "$ROOT/bin/run-codex" "$ROOT/bin/codex-push" "$ROOT/bin/codex-pull"; do
    nullglob_enable_count="$(grep -c 'shopt -s nullglob' "$script" || true)"
    nullglob_restore_count="$(grep -c 'shopt -u nullglob' "$script" || true)"
    [[ "$nullglob_enable_count" == "$nullglob_restore_count" ]] ||
        fail "$(basename "$script") leaks nullglob shell state"
done

workflow_source="$TEST_ROOT/workflow-source"
workflow_home="$TEST_ROOT/workflow-home"
cp -a -- "$ROOT/container/codex-workflow" "$workflow_source"
mkdir -p -- "$workflow_home"
workflow_install=(
    env
    "HOME=$workflow_home"
    "CODEX_HOME=$workflow_home/codex-state"
    "CODEX_UNIVERSAL_WORKFLOW_TEST_SOURCE=1"
    "CODEX_UNIVERSAL_WORKFLOW_SOURCE=$workflow_source"
    "$ROOT/container/codex-universal-workflow-install"
)
if env HOME="$workflow_home" CODEX_HOME="$workflow_home/rejected-state" \
    CODEX_UNIVERSAL_WORKFLOW_SOURCE="$workflow_source" \
    "$ROOT/container/codex-universal-workflow-install" \
    > "$workflow_home/rejected-source.out" 2>&1; then
    fail "workflow installer accepted a source override without its test boundary"
fi
grep -Fq 'restricted to test fixtures' "$workflow_home/rejected-source.out" ||
    fail "workflow source override rejection was not useful"
[[ ! -e "$workflow_home/rejected-state" ]] ||
    fail "rejected workflow source override modified CODEX_HOME"
CODEX_UNIVERSAL_WORKFLOW=0 "${workflow_install[@]}"
CODEX_UNIVERSAL_WORKFLOW=0 "${workflow_install[@]}"
test ! -e "$workflow_home/codex-state" ||
    fail "fresh workflow opt-out modified the shared Codex home"
"${workflow_install[@]}"
test -f "$workflow_home/codex-state/agents/code_reader.toml" ||
    fail "workflow installer did not install code_reader"
test -f "$workflow_home/codex-state/skills/clojure-development/references/first-project.md" ||
    fail "workflow installer did not install first-project guidance"
test -x "$workflow_home/codex-state/skills/clojure-development/scripts/clojure-development" ||
    fail "workflow installer did not make its helper executable"
test -x "$workflow_home/codex-state/skills/clojure-development/scripts/clojure-process-supervisor" ||
    fail "workflow installer did not make its process supervisor executable"
test -x "$workflow_home/codex-state/scripts/codex-worker-observe" ||
    fail "workflow installer did not make worker observability helper executable"
"${workflow_install[@]}"
printf '%s\n' '# user override' >> "$workflow_home/codex-state/agents/code_reader.toml"
"${workflow_install[@]}"
grep -Fq '# user override' "$workflow_home/codex-state/agents/code_reader.toml" ||
    fail "workflow installer overwrote a user-modified agent"
CODEX_UNIVERSAL_WORKFLOW=0 "${workflow_install[@]}"
CODEX_UNIVERSAL_WORKFLOW=0 "${workflow_install[@]}"
test -e "$workflow_home/codex-state/agents/clojure_probe.toml" ||
    fail "workflow opt-out modified the shared Codex home"
grep -Fq '# user override' "$workflow_home/codex-state/agents/code_reader.toml" ||
    fail "workflow opt-out modified a user-owned agent"
CODEX_UNIVERSAL_WORKFLOW=uninstall "${workflow_install[@]}"
CODEX_UNIVERSAL_WORKFLOW=uninstall "${workflow_install[@]}"
test ! -e "$workflow_home/codex-state/agents/clojure_probe.toml" ||
    fail "explicit workflow uninstall retained an unmodified managed asset"
grep -Fq '# user override' "$workflow_home/codex-state/agents/code_reader.toml" ||
    fail "explicit workflow uninstall removed a user-modified agent"
"${workflow_install[@]}"
test -f "$workflow_home/codex-state/agents/clojure_probe.toml" ||
    fail "workflow installer did not restore enabled assets"
grep -Fq '# user override' "$workflow_home/codex-state/agents/code_reader.toml" ||
    fail "workflow installer overwrote a preserved override after opt-out"
"${workflow_install[@]}" &
workflow_pid_one=$!
"${workflow_install[@]}" &
workflow_pid_two=$!
wait "$workflow_pid_one"
wait "$workflow_pid_two"

upgrade_source="$TEST_ROOT/workflow-upgrade-source"
upgrade_home="$TEST_ROOT/workflow-upgrade-home"
cp -a -- "$ROOT/container/codex-workflow" "$upgrade_source"
mkdir -p -- "$upgrade_home"
upgrade_install=(
    env
    "HOME=$upgrade_home"
    "CODEX_HOME=$upgrade_home/codex-state"
    "CODEX_UNIVERSAL_WORKFLOW_TEST_SOURCE=1"
    "CODEX_UNIVERSAL_WORKFLOW_SOURCE=$upgrade_source"
    "$ROOT/container/codex-universal-workflow-install"
)
"${upgrade_install[@]}"
upgrade_marker="$upgrade_home/codex-state/codex-universal-workflow/agents__clojure_probe.toml.sha256"
upgrade_before_marker="$(cat -- "$upgrade_marker")"
printf '%s\n' '# managed upgrade' >> "$upgrade_source/agents/clojure_probe.toml"
printf '%s\n' '# user override' >> "$upgrade_home/codex-state/agents/mechanical_worker.toml"
"${upgrade_install[@]}"
upgrade_after_marker="$(cat -- "$upgrade_marker")"
test "$upgrade_before_marker" != "$upgrade_after_marker" ||
    fail "workflow installer did not update a changed managed asset marker"
test "$(sha256sum -- "$upgrade_source/agents/clojure_probe.toml" | awk '{print $1}')" = \
    "$upgrade_after_marker" || \
    fail "workflow installer marker does not match upgraded asset"
grep -Fq '# managed upgrade' "$upgrade_home/codex-state/agents/clojure_probe.toml" ||
    fail "workflow installer did not apply a managed asset upgrade"
grep -Fq '# user override' "$upgrade_home/codex-state/agents/mechanical_worker.toml" ||
    fail "workflow installer overwrote a user-modified asset"

global_home="$TEST_ROOT/workflow-global-home"
global_codex_home="$global_home/codex-state"
global_agents='user-owned global guidance'
mkdir -p -- "$global_home" "$global_codex_home"
printf '%s\n' "$global_agents" > "$global_codex_home/AGENTS.md"
env HOME="$global_home" CODEX_HOME="$global_codex_home" \
    CODEX_UNIVERSAL_WORKFLOW_TEST_SOURCE=1 \
    CODEX_UNIVERSAL_WORKFLOW_SOURCE="$workflow_source" \
    "$ROOT/container/codex-universal-workflow-install"
grep -Fxq "$global_agents" "$global_codex_home/AGENTS.md" ||
    fail "workflow installer overwrote a pre-existing global AGENTS.md"
test ! -f "$global_codex_home/codex-universal-workflow/AGENTS.md.sha256" ||
    fail "workflow installer marked a pre-existing global AGENTS.md as managed"

concurrent_home="$TEST_ROOT/workflow-concurrent-home"
mkdir -p -- "$concurrent_home"
concurrent_install=(
    env
    "HOME=$concurrent_home"
    "CODEX_HOME=$concurrent_home/codex-state"
    "CODEX_UNIVERSAL_WORKFLOW_TEST_SOURCE=1"
    "CODEX_UNIVERSAL_WORKFLOW_SOURCE=$workflow_source"
    "$ROOT/container/codex-universal-workflow-install"
)
"${concurrent_install[@]}" &
concurrent_enabled_pid=$!
CODEX_UNIVERSAL_WORKFLOW=0 "${concurrent_install[@]}" &
concurrent_optout_pid=$!
wait "$concurrent_enabled_pid"
wait "$concurrent_optout_pid"
test -f "$concurrent_home/codex-state/agents/code_reader.toml" ||
    fail "session opt-out removed assets during a concurrent enabled install"
test -f "$concurrent_home/codex-state/skills/clojure-development/SKILL.md" ||
    fail "session opt-out removed skill assets during a concurrent enabled install"
grep -Fq 'substantive executable, action, and scope' \
    "$ROOT/container/codex-workflow/AGENTS.md" ||
    fail "workflow guidance does not require substantive approval prompts"
grep -Fq 'Approval of such a prelude never' \
    "$ROOT/container/codex-workflow/AGENTS.md" ||
    fail "workflow guidance lets a shell prelude imply later authorization"
grep -Fq 'name the exact' "$ROOT/container/codex-workflow/AGENTS.md" ||
    fail "workflow guidance does not require destructive target specificity"
grep -Fq 'Keep delegation observable' "$ROOT/container/codex-workflow/AGENTS.md" ||
    fail "workflow guidance does not require observable delegation"
grep -Fq 'Once per Codex session' "$ROOT/container/codex-workflow/AGENTS.md" ||
    fail "workflow guidance does not announce worker inspection"
grep -Fq 'do not assume such messaging exists' \
    "$ROOT/container/codex-workflow/AGENTS.md" ||
    fail "workflow guidance relies on unavailable worker-to-parent messaging"
grep -Fq 'user-facing explanations concise by default' \
    "$ROOT/container/codex-workflow/AGENTS.md" ||
    fail "workflow guidance does not keep user-facing explanations concise by default"
grep -Fq 'genuinely independent' "$ROOT/container/codex-workflow/AGENTS.md" ||
    fail "workflow guidance does not require genuinely independent delegation"
grep -Fq 'Use `summary RUN_ID` first' "$ROOT/container/codex-workflow/AGENTS.md" ||
    fail "workflow guidance does not prefer bounded worker summaries"
if grep -R -Fq '$CODEX_HOME/scripts/codex-worker-observe' \
    "$ROOT/container/codex-workflow/AGENTS.md" \
    "$ROOT/container/codex-workflow/agents"; then
    fail "workflow guidance requires CODEX_HOME to be set"
fi
pass "workflow installer lifecycle and update ownership"

observe_root="$TEST_ROOT/worker-observe"
observe_helper="$ROOT/container/codex-workflow/scripts/codex-worker-observe"
observe_help="$(CODEX_WORKER_OBSERVE_DIR=/not/below/tmp "$observe_helper" help)"
assert_contains "$observe_help" 'Inspect commands run by delegated Codex workers.'
assert_contains "$observe_help" 'codex-worker-observe list'
assert_contains "$observe_help" 'List recorded runs with status, liveness, and start time.'
assert_contains "$observe_help" 'codex-worker-observe show RUN_ID'
assert_contains "$observe_help" 'codex-worker-observe summary RUN_ID'
assert_contains "$observe_help" 'codex-worker-observe tail'
assert_contains "$observe_help" 'Installed path: ~/.codex/scripts/codex-worker-observe'
observe_commands="$("$observe_helper" commands)"
[[ "$observe_commands" == "$observe_help" ]] ||
    fail "worker observability command catalog aliases disagree"
set +e
observe_stdout="$(
    CODEX_WORKER_OBSERVE_DIR="$observe_root" \
        "$observe_helper" run failing-probe -- \
        bash -c 'printf "probe-out\\n"; printf "probe-err\\n" >&2; exit 7' \
        2>"$TEST_ROOT/observe-stderr"
)"
observe_exit=$?
set -e
[[ "$observe_exit" == 7 ]] || fail "worker observability helper lost command exit status"
[[ "$observe_stdout" == probe-out ]] || fail "worker observability helper lost stdout"
grep -Fxq probe-err "$TEST_ROOT/observe-stderr" ||
    fail "worker observability helper lost stderr"
grep -Fxq probe-out "$observe_root/failing-probe/stdout.log" ||
    fail "worker observability helper did not retain stdout"
grep -Fxq probe-err "$observe_root/failing-probe/stderr.log" ||
    fail "worker observability helper did not retain stderr"
grep -Fxq failed "$observe_root/failing-probe/status" ||
    fail "worker observability helper did not record failure"
grep -Fxq 7 "$observe_root/failing-probe/exit-code" ||
    fail "worker observability helper did not record exit status"
observe_show="$(CODEX_WORKER_OBSERVE_DIR="$observe_root" "$observe_helper" show failing-probe)"
assert_contains "$observe_show" 'status:      failed'
assert_contains "$observe_show" 'exit-code:   7'
observe_summary="$(CODEX_WORKER_OBSERVE_DIR="$observe_root" "$observe_helper" summary failing-probe)"
assert_contains "$observe_summary" 'status:      failed'
assert_contains "$observe_summary" 'stdout:      1 lines, 10 bytes'
assert_contains "$observe_summary" 'stderr:      1 lines, 10 bytes'
assert_contains "$observe_summary" 'probe-out'
assert_contains "$observe_summary" 'probe-err'
observe_list="$(CODEX_WORKER_OBSERVE_DIR="$observe_root" "$observe_helper" list)"
assert_contains "$observe_list" 'failing-probe'
[[ "$(CODEX_WORKER_OBSERVE_DIR="$observe_root" "$observe_helper" tail failing-probe)" == probe-out ]] ||
    fail "worker observability helper did not expose stdout tail"
[[ "$(CODEX_WORKER_OBSERVE_DIR="$observe_root" "$observe_helper" tail --stderr failing-probe)" == probe-err ]] ||
    fail "worker observability helper did not expose stderr tail"
set +e
CODEX_WORKER_OBSERVE_DIR="$observe_root" \
    "$observe_helper" run failing-probe -- true >/dev/null 2>&1
observe_reuse_exit=$?
set -e
[[ "$observe_reuse_exit" == 2 ]] ||
    fail "worker observability helper replaced an immutable run ID"
pass "worker command observability"

jq -e '
    .defaultAction == "SCMP_ACT_ERRNO" and
    any(.syscalls[];
        .action == "SCMP_ACT_ALLOW" and
        (.names | index("mount")) and
        (.names | index("pivot_root")) and
        (.names | index("unshare")))
' "$ROOT/security/seccomp/codex-bwrap.json" >/dev/null ||
    fail "Bubblewrap seccomp profile is invalid or incomplete"
grep -Fq 'Copyright The Moby Authors.' \
    "$ROOT/security/seccomp/NOTICE" ||
    fail "Moby seccomp attribution is missing"
grep -Fq 'Copyright 2026 leafclick s. r. o. for modifications.' \
    "$ROOT/security/seccomp/NOTICE" ||
    fail "seccomp modification attribution is missing"
grep -Fq 'Copyright The Moby Authors.' \
    "$ROOT/security/apparmor/NOTICE" ||
    fail "Moby AppArmor attribution is missing"
grep -Fq 'SPDX-License-Identifier: Apache-2.0' \
    "$ROOT/security/apparmor/codex-universal" ||
    fail "AppArmor derivative license is missing"
grep -Fq '/usr/sbin/apparmor_parser' \
    "$ROOT/bin/setup-codex-host-security" ||
    fail "host security setup does not support the standard sbin parser path"
if grep -Eq 'command -v[[:space:]]+apparmor_parser' \
    "$ROOT/bin/setup-codex-host-security"; then
    fail "privileged AppArmor parser may be selected from the caller PATH"
fi
grep -Fq 'sudo apt install apparmor apparmor-utils' \
    "$ROOT/bin/setup-codex-host-security" ||
    fail "host security setup has no AppArmor package guidance"
grep -Fq -- '--entrypoint /bin/sh' "$ROOT/bin/run-codex" ||
    fail "Bubblewrap preflight does not start under the outer AppArmor profile"
grep -Fq -- "-c 'exec /usr/bin/bwrap \"\$@\"'" "$ROOT/bin/run-codex" ||
    fail "Bubblewrap preflight does not exercise the AppArmor transition"
grep -Fq -- '--unshare-pid \' "$ROOT/bin/run-codex" ||
    fail "Bubblewrap preflight does not exercise the private PID namespace"
grep -Fq -- '--tmpfs /proc \' "$ROOT/bin/run-codex" ||
    fail "Bubblewrap preflight does not exercise the private procfs overlay"
grep -Fq -- '--tmpfs "$TMP_TMPFS_SPEC" \' "$ROOT/bin/run-codex" ||
    fail "Bubblewrap preflight does not provide writable temporary storage"
grep -Fq -- '--unshare-net' "$ROOT/container/codex-clojure-lsp-mcp" ||
    fail "Clojure LSP MCP bridge is not network-isolated"
grep -Fq -- '--unshare-pid' "$ROOT/container/codex-clojure-lsp-mcp" ||
    fail "Clojure LSP MCP bridge is not PID-isolated"
grep -Fq -- '--tmpfs /proc' "$ROOT/container/codex-clojure-lsp-mcp" ||
    fail "Clojure LSP MCP bridge does not hide the outer procfs"
if grep -Fq -- '--proc /proc' "$ROOT/container/codex-clojure-lsp-mcp"; then
    fail "Clojure LSP MCP bridge mounts procfs inside its private PID namespace"
fi
grep -Fq 'AGENT_LSP_OUTPUT_FORMAT json' "$ROOT/container/codex-clojure-lsp-mcp" ||
    fail "Clojure LSP MCP bridge does not preserve navigation locations as JSON"
grep -Fq 'LD_LIBRARY_PATH "$jvm_library_path"' "$ROOT/container/codex-clojure-lsp-mcp" ||
    fail "Clojure LSP MCP bridge does not supply selected JDK libraries"
grep -Fq -- '--check-java' "$ROOT/container/codex-clojure-lsp-mcp" ||
    fail "Clojure LSP MCP bridge lacks its in-sandbox Java diagnostic"
grep -Fq -- '\( -name .git -o -name .codex \) -prune -print0' \
    "$ROOT/container/codex-clojure-lsp-mcp" ||
    fail "Clojure LSP MCP bridge does not protect nested Git/Codex metadata"
grep -q '^profile codex-universal ' \
    "$ROOT/security/apparmor/codex-universal" ||
    fail "outer AppArmor profile is missing"
grep -Fq 'HOST_GID="$(id -g)"' "$ROOT/bin/run-codex" ||
    fail "launcher does not use the host primary group"
if grep -Fq 'GROUPS[0]' "$ROOT/bin/run-codex"; then
    fail "launcher still assumes the first supplementary-group entry is primary"
fi
grep -Fq 'source "$doctor_module"' "$ROOT/bin/run-codex" ||
    fail "launcher does not load its doctor companion module"
if grep -Eq '^run_doctor\(\)' "$ROOT/bin/run-codex"; then
    fail "launcher still embeds the extracted doctor implementation"
fi
grep -Eq '^run_doctor\(\)' "$ROOT/bin/run-codex-doctor.bash" ||
    fail "doctor companion module lacks run_doctor"
grep -Fq '"$ROOT/tests/host-smoke-sync.sh"' "$ROOT/tests/host-smoke.sh" ||
    fail "host smoke driver does not invoke the focused snapshot suite"
grep -Fq 'IntelliJ IDEA integration guide](docs/intellij.md)' "$ROOT/README.md" ||
    fail "README does not link to the extracted IntelliJ guide"
if grep -Eq 'Seafile generation|Wait for Seafile' "$ROOT/bin/codex-push"; then
    fail "codex-push still emits provider-specific success text"
fi
grep -Fq 'Wait for your sync provider to report synchronized' \
    "$ROOT/bin/codex-push" ||
    fail "codex-push lacks provider-neutral synchronization guidance"
grep -Fq 'Snapshot listing is intentionally lock-free' \
    "$ROOT/docs/codex-sync.md" ||
    fail "snapshot documentation omits the lock-free listing contract"
grep -Fq 'appear temporarily as' "$ROOT/docs/codex-sync.md" ||
    fail "snapshot documentation omits transient invalid listing guidance"
grep -Fq 'install -m 600 bin/codex-sync-lib' "$ROOT/docs/codex-sync.md" ||
    fail "snapshot documentation does not install the shared validation module"
grep -Fq "enforce\\)( |$)'" \
    "$ROOT/bin/setup-codex-host-security" ||
    fail "host security setup does not require AppArmor enforce mode"
grep -q '^[[:space:]]*userns,' \
    "$ROOT/security/apparmor/codex-universal" ||
    fail "AppArmor profile does not permit unprivileged user namespaces"
grep -q '^[[:space:]]*mount,' \
    "$ROOT/security/apparmor/codex-universal" ||
    fail "AppArmor profile does not permit namespaced mounts"
if grep -R -qE -- '--privileged|--cap-add([= ]|$)|seccomp=unconfined|apparmor=unconfined' \
    "$ROOT/bin" \
    "$ROOT/security/apparmor" \
    "$ROOT/security/seccomp"; then
    fail "unsafe Docker sandbox bypass is present"
fi

grep -qE '^[[:space:]]+zstd([[:space:]\\]|$)' "$ROOT/Dockerfile.generic" ||
    fail "generic image does not install zstd"
grep -qE '^[[:space:]]+zstd([[:space:]\\]|$)' "$ROOT/Dockerfile.cuda" ||
    fail "CUDA image does not install zstd"
grep -Fxq '.local-checks' "$ROOT/.dockerignore" ||
    fail "local validation evidence is not excluded from the Docker build context"
grep -Fxq '.local-fixtures' "$ROOT/.dockerignore" ||
    fail "local integration fixtures are not excluded from the Docker build context"
for dockerfile in "$ROOT/Dockerfile.generic" "$ROOT/Dockerfile.cuda"; do
    java_line="$(grep -n '^# Eclipse Temurin ' "$dockerfile" | cut -d: -f1)"
    clojure_line="$(grep -n '^# Clojure CLI\.' "$dockerfile" | cut -d: -f1)"
    native_tools_line="$(
        grep -n '^RUN /usr/local/src/install-clojure-tools' "$dockerfile" |
            cut -d: -f1
    )"
    npm_install_line="$(grep -n '^RUN npm install -g' "$dockerfile" | cut -d: -f1)"
    mcp_wrapper_line="$(
        grep -n '^COPY .*container/codex-clojure-lsp-mcp ' "$dockerfile" |
            cut -d: -f1
    )"
    (( java_line < clojure_line &&
       clojure_line < native_tools_line &&
       native_tools_line < npm_install_line &&
       npm_install_line < mcp_wrapper_line )) ||
        fail "$(basename "$dockerfile") does not preserve stable toolchain cache ordering"
    for package_arg in CODEX_VERSION CODEX_ACP_VERSION AGENT_LSP_VERSION; do
        package_arg_line="$(
            grep -n "^ARG ${package_arg}=" "$dockerfile" | cut -d: -f1
        )"
        (( native_tools_line < package_arg_line &&
           package_arg_line < npm_install_line )) ||
            fail "$(basename "$dockerfile") declares $package_arg before the stable toolchain"
    done
    grep -Fxq 'ARG CODEX_VERSION=0.154.0' "$dockerfile" ||
        fail "$(basename "$dockerfile") does not default to Codex 0.154.0"
    metadata_arg_line="$(
        grep -n '^ARG IMAGE_VERSION=' "$dockerfile" | cut -d: -f1 || true
    )"
    last_filesystem_line="$(
        grep -nE '^(ADD|COPY|RUN) ' "$dockerfile" |
            tail -n 1 | cut -d: -f1 || true
    )"
    [[ -n "$metadata_arg_line" && -n "$last_filesystem_line" ]] ||
        fail "$(basename "$dockerfile") cannot verify OCI metadata placement"
    (( metadata_arg_line > last_filesystem_line )) ||
        fail "$(basename "$dockerfile") puts changing OCI metadata before cached filesystem layers"
    grep -q 'org.opencontainers.image.version=' "$dockerfile" ||
        fail "$(basename "$dockerfile") has no OCI version label"
    grep -q 'org.opencontainers.image.revision=' "$dockerfile" ||
        fail "$(basename "$dockerfile") has no OCI revision label"
    grep -q 'org.opencontainers.image.source=' "$dockerfile" ||
        fail "$(basename "$dockerfile") has no OCI source label"
    grep -Fq 'ENV LEIN_JAR=/opt/clojure/leiningen-standalone.jar' "$dockerfile" ||
        fail "$(basename "$dockerfile") does not expose a shared Leiningen runtime"
    grep -Fq '&& lein self-install \' "$dockerfile" ||
        fail "$(basename "$dockerfile") does not preinstall the Leiningen runtime"
done
if grep -R -q 'CODEX_UNSAFE_ALLOW_NO_SANDBOX' \
    "$ROOT/Dockerfile.generic" "$ROOT/Dockerfile.cuda" "$ROOT/bin"; then
    fail "unsafe Codex sandbox bypass is present"
fi
grep -Fxq 'allowed_approval_policies = ["on-request"]' \
    "$ROOT/container/requirements.toml" ||
    fail "managed requirements do not require on-request approval"
grep -Fxq 'allowed_approvals_reviewers = ["user"]' \
    "$ROOT/container/requirements.toml" ||
    fail "managed requirements do not require human review"
grep -Fxq 'allowed_sandbox_modes = ["read-only", "workspace-write"]' \
    "$ROOT/container/requirements.toml" ||
    fail "managed requirements permit an unsafe sandbox mode"
for dockerfile in "$ROOT/Dockerfile.generic" "$ROOT/Dockerfile.cuda"; do
    grep -q '@agentclientprotocol/codex-acp@' "$dockerfile" ||
        fail "$(basename "$dockerfile") does not install codex-acp"
    grep -q 'container/requirements.toml /etc/codex/requirements.toml' "$dockerfile" ||
        fail "$(basename "$dockerfile") does not install managed requirements"
    grep -q 'container/install-clojure-tools /usr/local/src/install-clojure-tools' "$dockerfile" ||
        fail "$(basename "$dockerfile") does not install native Clojure tools"
    grep -q '@blackwell-systems/agent-lsp@' "$dockerfile" ||
        fail "$(basename "$dockerfile") does not install the LSP MCP bridge"
    grep -q 'container/codex-lsp-message-proxy /usr/local/bin/codex-lsp-message-proxy' \
        "$dockerfile" ||
        fail "$(basename "$dockerfile") does not install the LSP message proxy"
    grep -q 'container/codex-no-nested-userns.c /usr/local/src/codex-no-nested-userns.c' \
        "$dockerfile" ||
        fail "$(basename "$dockerfile") does not build the nested-userns filter"
    grep -qE '^[[:space:]]+socat([[:space:]\\]|$)' "$dockerfile" ||
        fail "$(basename "$dockerfile") does not install the IntelliJ MCP relay"
    grep -q 'container/libnss_codex.c /usr/local/src/libnss_codex.c' "$dockerfile" ||
        fail "$(basename "$dockerfile") does not install arbitrary-user NSS support"
    if grep -qE '^[[:space:]]+libnss-wrapper([[:space:]\\]|$)' "$dockerfile"; then
        fail "$(basename "$dockerfile") still installs the process-wide NSS preload shim"
    fi
    grep -qE '^[[:space:]]+rlwrap([[:space:]\\]|$)' "$dockerfile" ||
        fail "$(basename "$dockerfile") does not install Clojure REPL line editing"
    grep -Fxq 'USER 65532:65532' "$dockerfile" ||
        fail "$(basename "$dockerfile") does not declare the portable non-root user"
    grep -q 'container/codex-entrypoint /usr/local/bin/codex-entrypoint' "$dockerfile" ||
        fail "$(basename "$dockerfile") does not install the portable-user entrypoint"
    grep -q 'container/codex-workflow/ /usr/local/share/codex-universal/workflow/' "$dockerfile" ||
        fail "$(basename "$dockerfile") does not install bundled workflow assets"
    grep -q 'container/codex-universal-workflow-install /usr/local/bin/codex-universal-workflow-install' "$dockerfile" ||
        fail "$(basename "$dockerfile") does not install the workflow updater"
    grep -q 'workflow -type d -exec chmod 0755' "$dockerfile" ||
        fail "$(basename "$dockerfile") does not make workflow directories traversable"
    grep -q 'workflow/skills/clojure-development/scripts/\*' "$dockerfile" ||
        fail "$(basename "$dockerfile") does not make Clojure skill scripts executable"
    grep -q 'workflow/scripts/\*' "$dockerfile" ||
        fail "$(basename "$dockerfile") does not make workflow scripts executable"
    if grep -qE '^ARG (UID|GID)=' "$dockerfile"; then
        fail "$(basename "$dockerfile") still bakes the host UID/GID into the image"
    fi
done
for agent in code_reader clojure_probe mechanical_worker; do
    agent_file="$ROOT/container/codex-workflow/agents/$agent.toml"
    [[ -f "$agent_file" ]] || fail "missing bundled agent $agent"
    grep -Fxq 'model = "gpt-5.6-luna"' "$agent_file" ||
        fail "bundled agent $agent does not use Luna"
done
for agent in code_reader clojure_probe; do
    grep -Fxq 'model_reasoning_effort = "low"' \
        "$ROOT/container/codex-workflow/agents/$agent.toml" ||
        fail "$agent does not use low reasoning"
done
grep -Fxq 'model_reasoning_effort = "medium"' \
    "$ROOT/container/codex-workflow/agents/mechanical_worker.toml" ||
    fail "mechanical_worker does not use medium reasoning"
for agent in code_reader clojure_probe mechanical_worker; do
    if grep -Eq '^(service_tier = "fast"|features\.fast_mode = true)$' \
        "$ROOT/container/codex-workflow/agents/$agent.toml"; then
        fail "$agent unexpectedly enables agent-local Fast service"
    fi
done
grep -Fq 'Keep routine Git metadata writes local because' \
    "$ROOT/container/codex-workflow/AGENTS.md" ||
    fail "bundled routing does not keep authorized Git bookkeeping in the primary"
grep -Fq 'Use `fork_turns="none"` when that packet is self-contained.' \
    "$ROOT/container/codex-workflow/AGENTS.md" ||
    fail "bundled routing does not minimize inherited worker chat"
grep -Fq 'Do not use the default full-history fork unless the whole' \
    "$ROOT/container/codex-workflow/AGENTS.md" ||
    fail "bundled routing does not guard full-history worker forks"
grep -Fq 'never echo complete files or patches unless asked' \
    "$ROOT/container/codex-workflow/agents/mechanical_worker.toml" ||
    fail "mechanical_worker can echo generated artifacts into primary context"
workflow_skill="$ROOT/container/codex-workflow/skills/clojure-development"
[[ -x "$workflow_skill/scripts/clojure-development" ]] ||
    fail "Clojure development helper is not executable"
[[ -x "$workflow_skill/scripts/clojure-process-supervisor" ]] ||
    fail "Clojure process supervisor is not executable"
[[ -f "$workflow_skill/references/first-project.md" ]] ||
    fail "Clojure development first-project guidance is missing"
grep -Fq 'raw language-server response' \
    "$ROOT/container/codex-workflow/agents/code_reader.toml" ||
    fail "code_reader does not preserve semantic-provider diagnostic evidence"
grep -Fq 'CODEX_CLOJURE_STATE_DIR' "$ROOT/container/codex-entrypoint" ||
    fail "entrypoint does not establish session-local Clojure state"
grep -Fq 'clojure-process-supervisor' "$ROOT/container/codex-entrypoint" ||
    fail "entrypoint does not own the persistent Clojure process service"
grep -Fq '\( -name .git -o -name .codex \) -prune -print0' \
    "$ROOT/container/codex-entrypoint" ||
    fail "persistent Clojure service does not protect Git and Codex metadata"
grep -Fq -- '--unshare-pid' "$ROOT/container/codex-entrypoint" &&
    grep -Fq -- '--tmpfs /proc' "$ROOT/container/codex-entrypoint" &&
    grep -Fq -- '--dir /proc/self' "$ROOT/container/codex-entrypoint" &&
    grep -Fq -- '--symlink "$java_binary" /proc/self/exe' "$ROOT/container/codex-entrypoint" &&
    grep -Fq -- '--namespace-scoped' "$ROOT/container/codex-entrypoint" ||
    fail "persistent Clojure service procfs boundary is incomplete"
if grep -Fq -- '--unshare-net' "$ROOT/container/codex-entrypoint"; then
    fail "persistent Clojure service cannot share container loopback"
fi
grep -Fq '/usr/local/bin/codex-no-nested-userns' \
    "$ROOT/container/codex-entrypoint" ||
    fail "persistent Clojure service can create a nested user namespace"
grep -Fq '/usr/local/bin/codex-no-nested-userns' \
    "$ROOT/container/codex-clojure-lsp-mcp" ||
    fail "Clojure LSP bridge can create a nested user namespace"
if command -v gcc >/dev/null 2>&1; then
    nested_userns_filter="$TEST_ROOT/codex-no-nested-userns"
    gcc -std=c11 -O2 -Wall -Wextra -Werror \
        -o "$nested_userns_filter" \
        "$ROOT/container/codex-no-nested-userns.c"
    "$nested_userns_filter" /bin/true ||
        fail "nested-userns filter rejected an ordinary command"
    if "$nested_userns_filter" unshare --user /bin/true \
        >"$TEST_ROOT/nested-userns.out" 2>&1; then
        fail "nested-userns filter allowed a child user namespace"
    fi
    if command -v python3 >/dev/null 2>&1; then
        "$nested_userns_filter" python3 -c \
            'import threading; t=threading.Thread(target=lambda: None); t.start(); t.join()' ||
            fail "nested-userns filter blocked ordinary runtime threads"
        "$nested_userns_filter" python3 -c \
            'import ctypes, errno; libc=ctypes.CDLL(None, use_errno=True); result=libc.setns(-1, 0); assert result == -1 and ctypes.get_errno() == errno.EPERM' ||
            fail "nested-userns filter did not deny setns"
    fi
fi
grep -Fq '127.0.0.1' "$workflow_skill/scripts/clojure-development" ||
    fail "Clojure development helper does not constrain nREPL to loopback"
grep -Fq 'clojure:/usr/local/bin/codex-lsp-message-proxy' \
    "$ROOT/container/codex-clojure-lsp-mcp" ||
    fail "Clojure MCP wrapper does not route the server through its message proxy"
if grep -Eq '^[[:space:]]+"(execute_command|suggest_fixes)",' \
    "$ROOT/bin/run-codex"; then
    fail "Clojure LSP allowlist exposes broad or semantically ambiguous tools"
fi
[[ -x "$ROOT/container/codex-lsp-message-proxy" ]] ||
    fail "LSP message proxy is not executable"
if command -v python3 >/dev/null 2>&1; then
    python3 "$ROOT/tests/fixtures/check-lsp-message-proxy.py" \
        "$ROOT/container/codex-lsp-message-proxy" \
        "$ROOT/tests/fixtures/fake-lsp-init-error.py" ||
        fail "LSP message proxy did not expose an initialization-time server error"
    python3 - "$ROOT/container/codex-lsp-message-proxy" <<'PY' ||
import subprocess
import sys

proxy = sys.argv[1]
malformed = (
    b"\r\n",
    b"Content-Length: nope\r\n\r\n",
    b"Content-Length: 1\xff\r\n\r\n",
    b"Content-Length: 16777217\r\n\r\n",
)
for payload in malformed:
    result = subprocess.run(
        [proxy, "/bin/cat"], input=payload, capture_output=True, timeout=2
    )
    assert b"Traceback" not in result.stderr, result.stderr
PY
        fail "LSP message proxy mishandled malformed bounded frames"
else
    printf 'skip - LSP message proxy behavior (python3 unavailable on host)\n'
fi
if command -v bb >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
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
    [[ ! -e "$supervisor_fixture/control.fifo" ]] ||
        fail "Clojure process supervisor left a stale control channel"

    if command -v bwrap >/dev/null 2>&1; then
        namespace_fixture="$TEST_ROOT/clojure-namespace-state"
        namespace_project="$TEST_ROOT/clojure-namespace-project"
        mkdir -p -- "$namespace_fixture" "$namespace_project/.git"
        setsid bwrap \
            --unshare-user \
            --unshare-ipc \
            --unshare-pid \
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
            --control "$namespace_fixture/control.fifo" \
            --project-root "$namespace_project" \
            --state-root "$namespace_fixture" \
            --namespace-scoped \
            > "$namespace_fixture/service.out" \
            2> "$namespace_fixture/service.err" &
        namespace_service_pid=$!
        namespace_service_pgid="$namespace_service_pid"
        for _ in {1..100}; do
            [[ -p "$namespace_fixture/control.fifo" ]] && break
            kill -0 "$namespace_service_pid" 2>/dev/null || break
            sleep 0.02
        done
        if [[ -p "$namespace_fixture/control.fifo" ]]; then
            "$process_supervisor" start \
                --log "$namespace_fixture/repl.log" \
                --dir "$namespace_project" \
                "$namespace_fixture/control.fifo" namespace-token \
                -- bash -c \
                '[[ "$(readlink /proc/self/exe)" == /bin/sh && ! -e /proc/1/root ]]; setsid bash -c '\''trap "" TERM; sleep 30'\'' & sleep 30' \
                | grep -Eq '^started [0-9]+$' ||
                fail "namespace-scoped supervisor lost its minimal proc compatibility boundary"
            "$process_supervisor" control \
                "$namespace_fixture/control.fifo" namespace-token stop \
                | grep -Fxq 'stopped confirmed' ||
                fail "namespace-scoped supervisor did not kill a detached descendant"
            "$process_supervisor" control \
                "$namespace_fixture/control.fifo" namespace-token status \
                | grep -Fxq stopped ||
                fail "namespace-scoped supervisor released incomplete process state"
            stop_namespace_service
        else
            stop_namespace_service
            printf 'skip - namespace-scoped REPL supervisor (Bubblewrap unavailable to this user)\n'
        fi
    fi

    config_fixture="$TEST_ROOT/clojure-config"
    config_state="$TEST_ROOT/clojure-runtime"
    helper="$workflow_skill/scripts/clojure-development"
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
        fail "nREPL evaluation did not preserve separate values"
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

    printf '%s\n' \
        "{:runtimes {:wildcard {:kind :lein :repl [\"python3\" \"$fake_nrepl\" \"--host\" \"0.0.0.0\"]}}}" \
        > "$config_fixture/.codex/clojure-development.edn"
    if CODEX_PROJECT_ROOT="$config_fixture" \
        CODEX_CLOJURE_STATE_DIR="$config_state" \
        bb "$helper" repl-start \
        > "$config_fixture/wildcard.out" 2>&1; then
        fail "Clojure helper accepted a wildcard nREPL listener"
    fi
    grep -Fq 'not restricted to loopback' "$config_fixture/wildcard.out" ||
        fail "wildcard listener rejection was not useful"
    [[ ! -e "$config_state/state.edn" ]] ||
        fail "failed REPL startup retained stale owned-process state"
    [[ -z "$(find "$config_state" -maxdepth 1 -name 'response-*' -print -quit)" ]] ||
        fail "Clojure REPL service left an orphaned response file"
    kill "$config_service_pid"
    wait "$config_service_pid" ||
        fail "neutral Clojure REPL service failed during shutdown"
    [[ ! -e "$config_state/service-control.fifo" ]] ||
        fail "neutral Clojure REPL service left a stale control channel"
    pass "Clojure development runtime lifecycle and bounded probe evidence"
else
    printf 'skip - Clojure development runtime checks (bb or python3 unavailable on host)\n'
fi
grep -q 'container/codex-bwrap-cuda /usr/bin/bwrap' "$ROOT/Dockerfile.cuda" ||
    fail "CUDA image does not preserve NVIDIA devices inside Codex Bubblewrap"
grep -q 'mv /usr/bin/bwrap /usr/bin/bwrap.real' "$ROOT/Dockerfile.cuda" ||
    fail "CUDA image does not preserve the real Bubblewrap binary"
grep -q 'container/codex-cuda-failure-signatures /usr/local/share/codex/cuda-failure-signatures' \
    "$ROOT/Dockerfile.cuda" ||
    fail "CUDA image does not install failure signatures"
grep -Fq -- '--dev-bind' "$ROOT/container/codex-bwrap-cuda" ||
    fail "CUDA Bubblewrap shim does not bind GPU devices"
grep -Fq '[[ -c "$nvidia_device" || -d "$nvidia_device" ]]' \
    "$ROOT/container/codex-bwrap-cuda" ||
    fail "CUDA Bubblewrap shim does not require an exposed NVIDIA node"
grep -Fq 'CODEX_CUDA_FAILURE_HINT' "$ROOT/container/codex-bwrap-cuda" ||
    fail "CUDA Bubblewrap shim has no failure hint control"
grep -Fq 'tail -c 65536' "$ROOT/container/codex-bwrap-cuda" ||
    fail "CUDA Bubblewrap shim does not bound failure scanning"
grep -Fq 'mkfifo -m 0600' "$ROOT/container/codex-bwrap-cuda" &&
    grep -Fq 'wait "$stdout_reader_pid"' "$ROOT/container/codex-bwrap-cuda" &&
    grep -Fq 'wait "$stderr_reader_pid"' "$ROOT/container/codex-bwrap-cuda" ||
    fail "CUDA Bubblewrap shim does not wait for diagnostic capture"

fake_bwrap="$TEST_ROOT/fake-bwrap"
signature_file="$TEST_ROOT/cuda-failure-signatures"
printf '%s\n' \
    '# Test signatures are data, not wrapper code.' \
    'CUDA_ERROR_OPERATING_SYSTEM' \
    'CUDA[[:space:]]+error:[[:space:]]*:?(operating-system|operating[[:space:]]+system)' \
    > "$signature_file"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\\n" "$@" >&2' \
    'printf "CUDA error: :operating-system.\\n" >&2' \
    'exit 17' \
    > "$fake_bwrap"
chmod 755 "$fake_bwrap"
if hint_output="$(
    CODEX_CUDA_FAILURE_HINT=on \
    CODEX_BWRAP_REAL="$fake_bwrap" \
        CODEX_CUDA_FAILURE_SIGNATURES="$signature_file" \
        "$ROOT/container/codex-bwrap-cuda" --dev /dev -- /bin/false 2>&1
)"; then
    fail "CUDA Bubblewrap shim masked the wrapped command failure"
fi
[[ "$hint_output" == *"--dev"*"/dev"* ]] ||
    fail "CUDA Bubblewrap shim did not preserve a fresh --dev /dev"
[[ "$hint_output" != *"--dev-bind"*"/dev"*"/dev"* ]] ||
    fail "CUDA Bubblewrap shim exposed the complete container /dev"
no_gpu_bwrap="$TEST_ROOT/no-gpu-bwrap"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\\n" "$@"' > "$no_gpu_bwrap"
chmod 755 "$no_gpu_bwrap"
no_gpu_output="$(CODEX_BWRAP_REAL="$no_gpu_bwrap" \
    "$ROOT/container/codex-bwrap-cuda" --dev /dev -- /bin/true 2>&1)"
assert_contains "$no_gpu_output" "--dev"
assert_contains "$no_gpu_output" "/dev"
assert_not_contains "$no_gpu_output" "--dev-bind"
[[ "$hint_output" == *"Retry the same GPU workload"* ]] ||
    fail "CUDA Bubblewrap shim did not append the CUDA failure hint"
if CODEX_CUDA_FAILURE_HINT=off CODEX_BWRAP_REAL="$fake_bwrap" \
    "$ROOT/container/codex-bwrap-cuda" --dev /dev -- /bin/false >/dev/null 2>&1; then
    fail "CUDA Bubblewrap shim masked the disabled-hint command failure"
fi
if ! CODEX_CUDA_FAILURE_HINT=true CODEX_BWRAP_REAL="$no_gpu_bwrap" \
    "$ROOT/container/codex-bwrap-cuda" --dev /dev -- /bin/true \
    >/dev/null 2>&1; then
    fail "CUDA Bubblewrap shim rejected a truthy failure-hint mode"
fi
no_mktemp_bin="$TEST_ROOT/no-mktemp-bin"
mkdir -p "$no_mktemp_bin"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'exit 1' \
    > "$no_mktemp_bin/mktemp"
chmod 755 "$no_mktemp_bin/mktemp"
set +e
no_mktemp_output="$(
    PATH="$no_mktemp_bin:$PATH" CODEX_CUDA_FAILURE_HINT=on \
        CODEX_BWRAP_REAL="$fake_bwrap" \
        "$ROOT/container/codex-bwrap-cuda" --dev /dev -- /bin/false 2>&1
)"
no_mktemp_status=$?
set -e
(( no_mktemp_status != 0 )) ||
    fail "CUDA Bubblewrap shim masked the failure when temp capture was unavailable"
[[ "$no_mktemp_output" == *"CUDA error: :operating-system"* ]] ||
    fail "CUDA Bubblewrap shim did not delegate when temp capture was unavailable"
[[ "$no_mktemp_output" != *"Retry the same GPU workload"* ]] ||
    fail "CUDA Bubblewrap shim emitted a hint without temp capture"
grep -Fq 'exec /opt/nvidia/nvidia_entrypoint.sh "$0" "$@"' \
    "$ROOT/container/codex-entrypoint" ||
    fail "portable-user entrypoint does not preserve NVIDIA initialization"
grep -Fq 'exec 1>&3 3>&-' "$ROOT/container/codex-entrypoint" ||
    fail "portable-user entrypoint does not restore CUDA ACP stdout"
if grep -Eq 'LD_PRELOAD|NSS_WRAPPER_' \
    "$ROOT/container/codex-entrypoint" "$ROOT/container/libnss_codex.c"; then
    fail "portable-user identity leaks NSS configuration into native loaders"
fi
grep -Fq 'TCP4-LISTEN:${relay_port},bind=127.0.0.1' \
    "$ROOT/container/codex-acp-entrypoint" ||
    fail "ACP entrypoint does not restrict its MCP relay to container loopback"
grep -Fq 'setpriv --pdeathsig TERM -- socat' \
    "$ROOT/container/codex-acp-entrypoint" ||
    fail "container-side IntelliJ relay is not tied to ACP lifetime"
grep -Fq -- '-iTCP:"$relay_port" -sTCP:LISTEN' \
    "$ROOT/container/codex-acp-entrypoint" ||
    fail "ACP entrypoint does not wait for the IntelliJ relay listener"
if grep -Fq 'sleep 0.05' "$ROOT/container/codex-acp-entrypoint"; then
    fail "ACP entrypoint still relies on a fixed relay startup sleep"
fi
grep -Fq 'setpriv --pdeathsig TERM --' "$ROOT/bin/run-codex" ||
    fail "IDEA relay is not tied to the launcher lifetime"
grep -Fq '8>&- 9>&- &' "$ROOT/bin/run-codex" ||
    fail "IDEA relay inherits launcher lock descriptors"
pass "shell syntax and static security invariants"

if command -v python3 >/dev/null 2>&1; then
    relay_failure_fixture="$TEST_ROOT/acp-relay-delayed-failure"
    relay_failure_bin="$relay_failure_fixture/bin"
    relay_failure_socket="$relay_failure_fixture/idea.sock"
    relay_failure_marker="$relay_failure_fixture/acp-started"
    mkdir -p -- "$relay_failure_bin"
    python3 - "$relay_failure_socket" <<'PY'
import socket
import sys

listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
listener.bind(sys.argv[1])
listener.close()
PY
    printf '%s\n' '#!/usr/bin/env bash' 'sleep 0.2' 'exit 23' \
        > "$relay_failure_bin/socat"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 1' \
        > "$relay_failure_bin/lsof"
    printf '%s\n' '#!/usr/bin/env bash' \
        'touch "$CODEX_TEST_ACP_STARTED"' \
        > "$relay_failure_bin/codex-acp"
    chmod 755 "$relay_failure_bin/socat" "$relay_failure_bin/lsof" \
        "$relay_failure_bin/codex-acp"
    set +e
    relay_failure_output="$(
        env PATH="$relay_failure_bin:$PATH" \
            CODEX_IDEA_MCP_RELAY_SOCKET="$relay_failure_socket" \
            CODEX_IDEA_MCP_RELAY_PORT=64342 \
            CODEX_TEST_ACP_STARTED="$relay_failure_marker" \
            bash "$ROOT/container/codex-acp-entrypoint" 2>&1
    )"
    relay_failure_status=$?
    set -e
    (( relay_failure_status != 0 )) ||
        fail "ACP entrypoint accepted a delayed relay startup failure"
    assert_contains "$relay_failure_output" \
        "Failed to start the container-side IntelliJ MCP relay"
    [[ ! -e "$relay_failure_marker" ]] ||
        fail "ACP started after its IntelliJ relay failed"
    pass "delayed IntelliJ relay startup failure"
else
    printf 'skip - delayed IntelliJ relay startup failure (python3 unavailable on host)\n'
fi

# The launcher smoke test uses echo as a Docker frontend. This verifies the
# complete argument vector without requiring Docker or Codex on the host.
mkdir -p "$TEST_ROOT/fake-bin" "$TEST_ROOT/launcher-home" "$TEST_ROOT/repo"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -Eeuo pipefail' \
    'case "${1:-}" in' \
    '    info|ps) exit 0 ;;' \
    '    image)' \
    '        if [[ "${2:-}" == inspect && "${3:-}" == --format ]]; then' \
    '            case "${4:-}" in' \
    '                "{{.Id}}") printf "%s\\n" sha256:doctor-image ;;' \
    '                "{{.Config.User}}") printf "%s\\n" "${CODEX_TEST_IMAGE_USER:-65532:65532}" ;;' \
    '                *org.opencontainers.image.version*) printf "%s\\n" test-version ;;' \
    '                *org.opencontainers.image.revision*) printf "%s\\n" 0123456789abcdef ;;' \
    '            esac' \
    '        fi' \
    '        exit 0' \
    '        ;;' \
    '    run|build)' \
    '        printf "%s\\n" "$*"' \
    '        if [[ -n "${CODEX_TEST_DOCKER_ARGV_LOG:-}" ]]; then' \
    '            printf "%q\\n" "$@" > "$CODEX_TEST_DOCKER_ARGV_LOG"' \
    '        fi' \
    '        ;;' \
    '    *) exit 0 ;;' \
    'esac' \
    > "$TEST_ROOT/fake-bin/docker"
chmod 755 "$TEST_ROOT/fake-bin/docker"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'exit 0' \
    > "$TEST_ROOT/fake-bin/socat"
chmod 755 "$TEST_ROOT/fake-bin/socat"
git -C "$TEST_ROOT/repo" init -q
printf '%s\n' '{:paths ["src"]}' > "$TEST_ROOT/repo/deps.edn"
printf '%s\n' 'not-a-real-png' > "$TEST_ROOT/repo/prompt-image.png"
git -C "$TEST_ROOT/repo" add deps.edn prompt-image.png
git -C "$TEST_ROOT/repo" \
    -c user.name=host-smoke -c user.email=host-smoke.invalid \
    commit -qm 'host smoke fixture'
git -C "$TEST_ROOT/repo" worktree add -q -b smoke-linked \
    "$TEST_ROOT/repo-linked"

launcher_env=(
    env
    "HOME=$TEST_ROOT/launcher-home"
    "XDG_CONFIG_HOME=$TEST_ROOT/launcher-config"
    "CODEX_IMAGE_SLUG=example/codex-universal"
    "CODEX_IMAGE_TAG=test-version"
    "CODEX_GIT_USER_NAME=host-smoke"
    "CODEX_GIT_USER_EMAIL=host-smoke.invalid"
    "CODEX_TEST_SKIP_IDEA_MCP_RELAY=1"
    "CODEX_SECCOMP_PROFILE=$ROOT/security/seccomp/codex-bwrap.json"
    "PATH=$TEST_ROOT/fake-bin:$PATH"
)

launcher_help="$("${launcher_env[@]}" "$ROOT/bin/run-codex" --help)"
assert_contains "$launcher_help" \
    "Codex options (terminal mode, repeat --codex-option as needed):"
assert_contains "$launcher_help" \
    "run-codex PROJECT --set profile generic|cuda"
assert_contains "$launcher_help" \
    "run-codex PROJECT --set clojure-mcp auto|on|off"
for documented_env in \
    CODEX_IMAGE_PREFIX \
    CODEX_DEFAULT_PROFILE \
    CODEX_CONTAINER_HOME \
    CODEX_WORKSPACE_ROOT \
    CODEX_LOCK_FILE \
    CODEX_UNIVERSAL_WORKFLOW \
    CODEX_GIT_USER_NAME \
    CODEX_GIT_USER_EMAIL; do
    assert_contains "$launcher_help" "$documented_env"
done
assert_contains "$launcher_help" "reasoning=minimal|low|medium|high|xhigh"
assert_contains "$launcher_help" "image=PROJECT_PATH"
assert_contains "$launcher_help" "run-codex [PROJECT] --sessions"
assert_contains "$launcher_help" "run-codex [PROJECT] --resume QUERY"
assert_contains "$launcher_help" "--image-version VERSION"

if "${launcher_env[@]}" "$ROOT/bin/run-codex" \
    --init linked-project "$TEST_ROOT/repo-linked" \
    >"$TEST_ROOT/linked-worktree.out" 2>&1; then
    fail "launcher registered a linked Git worktree"
fi
assert_contains "$(<"$TEST_ROOT/linked-worktree.out")" \
    "Git worktrees/submodules with a .git pointer file are not supported yet"

"${launcher_env[@]}" "$ROOT/bin/run-codex" \
    --init --profile generic smoke-project "$TEST_ROOT/repo" >/dev/null

project_config="$TEST_ROOT/launcher-config/run-codex/projects/smoke-project"
grep -Fxq 'clojure_mcp=auto' "$project_config" ||
    fail "new project config does not default Clojure MCP to auto"
config_before="$(<"$project_config")"
init_again_output="$(
    "${launcher_env[@]}" "$ROOT/bin/run-codex" \
        --init smoke-project "$TEST_ROOT/repo"
)"
assert_contains "$init_again_output" "already initialized"
[[ "$(<"$project_config")" == "$config_before" ]] ||
    fail "repeated project initialization changed its configuration"

list_output="$("${launcher_env[@]}" "$ROOT/bin/run-codex" --list)"
assert_contains "$list_output" "smoke-project"
assert_contains "$list_output" "generic"
assert_contains "$list_output" "CLOJURE-MCP"
assert_contains "$list_output" "auto"
assert_contains "$list_output" "OK"

mkdir -p -- "$TEST_ROOT/launcher-home/.codex"
session_db="$TEST_ROOT/launcher-home/.codex/state_5.sqlite"
sqlite3 "$session_db" <<'SQL'
CREATE TABLE threads (
    id TEXT PRIMARY KEY,
    updated_at INTEGER NOT NULL,
    cwd TEXT NOT NULL,
    name TEXT,
    archived INTEGER NOT NULL
);
INSERT INTO threads VALUES
    ('11111111-1111-4111-8111-111111111111', 1788951000, '/workspace/smoke-project', 'GPU tuning baseline', 0),
    ('22222222-2222-4222-8222-222222222222', 1788952000, '/workspace/smoke-project', 'GPU tuning follow-up', 0),
    ('33333333-3333-4333-8333-333333333333', 1788953000, '/workspace/smoke-project', 'Release verification', 0),
    ('44444444-4444-4444-8444-444444444444', 1788954000, '/workspace/other-project', 'Other project session', 0),
    ('55555555-5555-4555-8555-555555555555', 1788955000, '/workspace/smoke-project', 'Archived GPU tuning', 1);
SQL

sessions_docker_log="$TEST_ROOT/sessions-docker-argv.log"
sessions_output="$(
    "${launcher_env[@]}" "CODEX_TEST_DOCKER_ARGV_LOG=$sessions_docker_log" \
        "$ROOT/bin/run-codex" smoke-project --sessions
)"
assert_contains "$sessions_output" "Active Codex sessions for 'smoke-project':"
assert_contains "$sessions_output" 'GPU tuning baseline'
assert_contains "$sessions_output" 'GPU tuning follow-up'
assert_contains "$sessions_output" 'Release verification'
assert_not_contains "$sessions_output" 'Other project session'
assert_not_contains "$sessions_output" 'Archived GPU tuning'
[[ ! -e "$sessions_docker_log" ]] ||
    fail "session listing invoked Docker"

if "${launcher_env[@]}" "$ROOT/bin/run-codex" smoke-project --sessions \
    --image-version immutable-test >"$TEST_ROOT/session-image-version.out" 2>&1; then
    fail "session listing accepted an image-version launch option"
fi
assert_contains "$(<"$TEST_ROOT/session-image-version.out")" \
    "--sessions cannot be combined with launch options"

session_handoff_lock="$TEST_ROOT/launcher-home/.cache/codex-handoff.lock"
session_lock_stdout="$TEST_ROOT/session-lock.out"
session_lock_stderr="$TEST_ROOT/session-lock.err"
mkdir -p -- "$(dirname "$session_handoff_lock")"
exec 7>"$session_handoff_lock"
flock -x 7
"${launcher_env[@]}" "$ROOT/bin/run-codex" smoke-project --sessions \
    >"$session_lock_stdout" 2>"$session_lock_stderr" 7>&- &
session_lock_pid=$!
session_lock_waiting=false
for _ in {1..100}; do
    if grep -Fq "Waiting for Codex state handoff lock: $session_handoff_lock" \
        "$session_lock_stderr"; then
        session_lock_waiting=true
        break
    fi
    kill -0 "$session_lock_pid" 2>/dev/null || break
    sleep 0.02
done
if ! $session_lock_waiting; then
    flock -u 7
    exec 7>&-
    wait "$session_lock_pid" 2>/dev/null || true
    fail "session listing did not report handoff lock contention"
fi
kill -0 "$session_lock_pid" 2>/dev/null || {
    flock -u 7
    exec 7>&-
    fail "session listing exited while the handoff lock was held"
}
sqlite3 "$session_db" <<'SQL'
INSERT INTO threads VALUES
    ('66666666-6666-4666-8666-666666666666', 1788956000, '/workspace/smoke-project', 'Created while handoff locked', 0);
SQL
flock -u 7
exec 7>&-
wait "$session_lock_pid" || fail "session listing failed after handoff lock release"
assert_contains "$(<"$session_lock_stdout")" 'Created while handoff locked'
pass "session reads wait for the shared state handoff lock"

ambiguous_docker_log="$TEST_ROOT/ambiguous-sessions-docker-argv.log"
if "${launcher_env[@]}" "CODEX_TEST_DOCKER_ARGV_LOG=$ambiguous_docker_log" \
    "$ROOT/bin/run-codex" smoke-project --resume GPU \
    >"$TEST_ROOT/ambiguous-sessions.out" 2>&1; then
    fail "ambiguous session substring selected a session"
fi
ambiguous_output="$(<"$TEST_ROOT/ambiguous-sessions.out")"
assert_contains "$ambiguous_output" "Session query 'GPU' is ambiguous"
assert_contains "$ambiguous_output" 'GPU tuning baseline'
assert_contains "$ambiguous_output" 'GPU tuning follow-up'
assert_not_contains "$ambiguous_output" 'Release verification'
[[ ! -e "$ambiguous_docker_log" ]] ||
    fail "ambiguous session selection invoked Docker"

missing_docker_log="$TEST_ROOT/missing-session-docker-argv.log"
if "${launcher_env[@]}" "CODEX_TEST_DOCKER_ARGV_LOG=$missing_docker_log" \
    "$ROOT/bin/run-codex" smoke-project --resume missing-name \
    >"$TEST_ROOT/missing-session.out" 2>&1; then
    fail "missing session substring selected a session"
fi
missing_output="$(<"$TEST_ROOT/missing-session.out")"
assert_contains "$missing_output" "No active session for project 'smoke-project' matches 'missing-name'"
assert_contains "$missing_output" "run-codex 'smoke-project' --sessions"
[[ ! -e "$missing_docker_log" ]] ||
    fail "missing session selection invoked Docker"

unique_session_id='33333333-3333-4333-8333-333333333333'
unique_docker_log="$TEST_ROOT/unique-session-docker-argv.log"
unique_output="$(
    "${launcher_env[@]}" "CODEX_TEST_DOCKER_ARGV_LOG=$unique_docker_log" \
        "$ROOT/bin/run-codex" smoke-project --resume vErIfIcAtIoN
)"
assert_contains "$unique_output" \
    "Resuming Codex session 'Release verification' for 'smoke-project'"
assert_contains "$unique_output" "resume $unique_session_id"
assert_not_contains "$unique_output" 'resume --last'
grep -Fxq -- 'resume' "$unique_docker_log" ||
    fail "unique session selection did not pass the resume subcommand"
grep -Fxq -- "$unique_session_id" "$unique_docker_log" ||
    fail "unique session selection did not pass the resolved UUID"

exact_uuid_docker_log="$TEST_ROOT/exact-session-docker-argv.log"
exact_uuid_output="$(
    "${launcher_env[@]}" "CODEX_TEST_DOCKER_ARGV_LOG=$exact_uuid_docker_log" \
        "$ROOT/bin/run-codex" smoke-project \
        --resume 11111111-1111-4111-8111-111111111111
)"
assert_contains "$exact_uuid_output" \
    "Resuming Codex session 'GPU tuning baseline' for 'smoke-project'"
grep -Fxq -- '11111111-1111-4111-8111-111111111111' \
    "$exact_uuid_docker_log" ||
    fail "exact session UUID was not passed to Codex"

tagged_launch_output="$(
    "${launcher_env[@]}" "$ROOT/bin/run-codex" smoke-project --new \
        --image-version=immutable-test
)"
assert_contains "$tagged_launch_output" \
    "example/codex-universal-generic:immutable-test"
if "${launcher_env[@]}" "$ROOT/bin/run-codex" smoke-project --new \
    --image-version first --image-version second >"$TEST_ROOT/duplicate-image-version.out" 2>&1; then
    fail "launcher accepted duplicate image versions"
fi
assert_contains "$(<"$TEST_ROOT/duplicate-image-version.out")" \
    "--image-version may be specified only once"
if "${launcher_env[@]}" "$ROOT/bin/run-codex" smoke-project --new \
    --image-version '/invalid' >"$TEST_ROOT/invalid-image-version.out" 2>&1; then
    fail "launcher accepted an invalid image version"
fi
assert_contains "$(<"$TEST_ROOT/invalid-image-version.out")" \
    "Invalid image tag '/invalid'"

mkdir -p "$TEST_ROOT/doctor-missing-bin"
ln -s "$(type -P bash)" "$TEST_ROOT/doctor-missing-bin/bash"
if env \
    "HOME=$TEST_ROOT/doctor-missing-home" \
    "XDG_CONFIG_HOME=$TEST_ROOT/doctor-missing-config" \
    "PATH=$TEST_ROOT/doctor-missing-bin" \
    "$ROOT/bin/run-codex" --doctor smoke-project \
    >"$TEST_ROOT/doctor-missing.out" 2>&1; then
    fail "doctor accepted missing required host commands"
fi
doctor_missing_output="$(<"$TEST_ROOT/doctor-missing.out")"
assert_contains "$doctor_missing_output" \
    "FAIL  Missing required host commands: git realpath docker flock"
[[ ! -e "$TEST_ROOT/doctor-missing-config/run-codex" ]] ||
    fail "doctor created project configuration while reporting missing commands"

doctor_output="$("${launcher_env[@]}" "$ROOT/bin/run-codex" --doctor smoke-project)"
assert_contains "$doctor_output" "PASS  Required host commands are available"
assert_contains "$doctor_output" "PASS  Host runtime identity is non-root ($(id -u):$(id -g))"
assert_contains "$doctor_output" "PASS  Docker daemon is available"
assert_contains "$doctor_output" "PASS  Project 'smoke-project' resolves to $TEST_ROOT/repo (generic)"
assert_contains "$doctor_output" \
    "PASS  Clojure LSP MCP selected (auto-detected Clojure project)"
assert_contains "$doctor_output" "PASS  Host sandbox policy is readable"
assert_contains "$doctor_output" "PASS  Local image is available: example/codex-universal-generic:test-version"
assert_contains "$doctor_output" "image id: sha256:doctor-image"
assert_contains "$doctor_output" "version:  test-version"
assert_contains "$doctor_output" "revision: 0123456789abcdef"
assert_contains "$doctor_output" "PASS  Image declares a fixed non-root user (65532:65532)"
# The fake Docker frontend below only records argv; it cannot prove that the
# host kernel, AppArmor, seccomp, and Bubblewrap actually enforced the probe.
assert_contains "$doctor_output" \
    "PASS  Portable runtime identity, read-only image, tools, and managed Codex policy"
assert_contains "$doctor_output" "PASS  Clojure LSP MCP handshake and tool allowlist"
assert_contains "$doctor_output" "Diagnostics passed with 0 warning(s)."
assert_contains "$doctor_output" "--network none"
assert_contains "$doctor_output" "--cap-drop=ALL"
assert_not_contains "$doctor_output" "$TEST_ROOT/repo:"

installed_launcher_dir="$TEST_ROOT/installed-launcher"
mkdir -p "$installed_launcher_dir"
install -m 755 "$ROOT/bin/run-codex" "$installed_launcher_dir/run-codex"
install -m 644 "$ROOT/bin/run-codex-doctor.bash" \
    "$installed_launcher_dir/run-codex-doctor.bash"
installed_doctor_output="$(
    "${launcher_env[@]}" "$installed_launcher_dir/run-codex" \
        --doctor smoke-project
)"
assert_contains "$installed_doctor_output" \
    "PASS  Project 'smoke-project' resolves to $TEST_ROOT/repo (generic)"

missing_module_dir="$TEST_ROOT/missing-doctor-module"
mkdir -p "$missing_module_dir"
install -m 755 "$ROOT/bin/run-codex" "$missing_module_dir/run-codex"
if "${launcher_env[@]}" "$missing_module_dir/run-codex" \
    --doctor smoke-project >"$missing_module_dir/output" 2>&1; then
    fail "installed launcher accepted a missing doctor companion module"
fi
assert_contains "$(<"$missing_module_dir/output")" "Missing doctor module:"
pass "launcher doctor companion installation"

for unsafe_apparmor_profile in unconfined docker-default arbitrary-profile; do
    set +e
    unsafe_doctor_output="$(
        "${launcher_env[@]}" CODEX_APPARMOR_PROFILE="$unsafe_apparmor_profile" \
            "$ROOT/bin/run-codex" --doctor smoke-project 2>&1
    )"
    unsafe_doctor_status=$?
    unsafe_launch_output="$(
        "${launcher_env[@]}" CODEX_APPARMOR_PROFILE="$unsafe_apparmor_profile" \
            "$ROOT/bin/run-codex" smoke-project --new 2>&1
    )"
    unsafe_launch_status=$?
    set -e
    (( unsafe_doctor_status != 0 )) ||
        fail "doctor accepted unsupported AppArmor profile: $unsafe_apparmor_profile"
    (( unsafe_launch_status != 0 )) ||
        fail "launcher accepted unsupported AppArmor profile: $unsafe_apparmor_profile"
    assert_contains "$unsafe_doctor_output" "Unsupported CODEX_APPARMOR_PROFILE"
    assert_contains "$unsafe_launch_output" "Unsupported CODEX_APPARMOR_PROFILE"
done
pass "unsupported AppArmor profile rejection"

if "${launcher_env[@]}" CODEX_TEST_IMAGE_USER=0:0 \
    "$ROOT/bin/run-codex" --doctor smoke-project \
    >"$TEST_ROOT/doctor-root-image.out" 2>&1; then
    fail "doctor accepted an image with a root default user"
fi
assert_contains "$(<"$TEST_ROOT/doctor-root-image.out")" \
    "FAIL  Image must declare an explicit non-root numeric user: '0:0'"

doctor_no_mcp_output="$(
    "${launcher_env[@]}" CODEX_CLOJURE_LSP_MCP=0 \
        "$ROOT/bin/run-codex" --doctor smoke-project
)"
assert_contains "$doctor_no_mcp_output" \
    "SKIP  Clojure LSP MCP handshake (environment override: off)"

if "${launcher_env[@]}" \
    CODEX_SECCOMP_PROFILE="$TEST_ROOT/missing-seccomp.json" \
    "$ROOT/bin/run-codex" --doctor smoke-project \
    >"$TEST_ROOT/doctor-failure.out" 2>&1; then
    fail "doctor accepted a missing host sandbox policy"
fi
doctor_failure_output="$(<"$TEST_ROOT/doctor-failure.out")"
assert_contains "$doctor_failure_output" \
    "FAIL  Host sandbox policy is not readable: $TEST_ROOT/missing-seccomp.json"
assert_contains "$doctor_failure_output" \
    "SKIP  Runtime probes because an earlier required check failed"
assert_contains "$doctor_failure_output" "Diagnostics failed: 1 failure(s)"

new_output="$("${launcher_env[@]}" "$ROOT/bin/run-codex" smoke-project --new)"
resume_output="$("${launcher_env[@]}" "$ROOT/bin/run-codex" smoke-project)"

for output in "$new_output" "$resume_output"; do
    assert_contains "$output" "--read-only"
    assert_contains "$output" "--pull=never"
    assert_contains "$output" "--tmpfs /home/codex:rw,exec,nosuid,nodev,uid=$(id -u),gid=$(id -g),mode=0700"
    assert_contains "$output" "--tmpfs /tmp:rw,exec,nosuid,nodev,mode=1777"
    assert_contains "$output" "--cap-drop=ALL"
    assert_contains "$output" "--security-opt=no-new-privileges"
    assert_contains "$output" "--security-opt apparmor=codex-universal"
    assert_contains "$output" "--security-opt seccomp=$ROOT/security/seccomp/codex-bwrap.json"
    assert_contains "$output" "--user $(id -u):$(id -g)"
    assert_contains "$output" "--sandbox workspace-write"
    assert_contains "$output" "--ask-for-approval on-request"
    assert_contains "$output" 'approvals_reviewer="user"'
    assert_contains "$output" "sandbox_workspace_write.network_access=false"
    assert_contains "$output" 'mcp_servers.clojure_lsp.command="/usr/local/bin/codex-clojure-lsp-mcp"'
    assert_contains "$output" 'mcp_servers.clojure_lsp.args=["clojure:clojure-lsp"]'
    assert_contains "$output" 'mcp_servers.clojure_lsp.enabled_tools=['
    assert_contains "$output" '"start_lsp"'
    assert_contains "$output" '"find_references"'
    assert_not_contains "$output" '"blast_radius"'
    assert_contains "$output" '"safe_apply_edit"'
    assert_not_contains "$output" '"run_tests"'
    assert_contains "$output" 'mcp_servers.clojure_lsp.default_tools_approval_mode="writes"'
    assert_contains "$output" "Clojure MCP: enabled (auto-detected Clojure project)"
    assert_contains "$output" "$TEST_ROOT/repo:/workspace/smoke-project"
    assert_contains "$output" "example/codex-universal-generic:test-version"
done
assert_contains "$resume_output" "resume --last"

forwarded_argv_log="$TEST_ROOT/forwarded-docker-argv.log"
forwarded_new_output="$(
    "${launcher_env[@]}" \
        "CODEX_TEST_DOCKER_ARGV_LOG=$forwarded_argv_log" \
        "$ROOT/bin/run-codex" smoke-project --new \
        --codex-option model=gpt-5.6-sol \
        --codex-option reasoning=high \
        --codex-option search \
        --codex-option no-alt-screen \
        --codex-option strict-config \
        --codex-option image=prompt-image.png \
        --codex-option 'prompt=review this project'
)"
assert_contains "$forwarded_new_output" "--model gpt-5.6-sol"
assert_contains "$forwarded_new_output" 'model_reasoning_effort="high"'
assert_contains "$forwarded_new_output" "--search"
assert_contains "$forwarded_new_output" "--no-alt-screen"
assert_contains "$forwarded_new_output" "--strict-config"
assert_contains "$forwarded_new_output" "--image /workspace/smoke-project/prompt-image.png"
assert_contains "$forwarded_new_output" "-- review this project"
assert_not_contains "$forwarded_new_output" "resume --last"
grep -Fxq -- '--model' "$forwarded_argv_log" ||
    fail "forwarded model flag is not a distinct Docker argument"
grep -Fxq -- 'gpt-5.6-sol' "$forwarded_argv_log" ||
    fail "forwarded model value is not a distinct Docker argument"
grep -Fxq -- 'codex' "$forwarded_argv_log" ||
    fail "launcher did not select Codex through the portable-user entrypoint"
grep -Fxq -- 'model_reasoning_effort=\"high\"' "$forwarded_argv_log" ||
    fail "forwarded reasoning setting changed argument boundaries"
grep -Fxq -- '/workspace/smoke-project/prompt-image.png' "$forwarded_argv_log" ||
    fail "forwarded image path is not container-relative"
grep -Fxq -- '--' "$forwarded_argv_log" ||
    fail "forwarded prompt is not separated from Codex options"
grep -Fxq -- 'review\ this\ project' "$forwarded_argv_log" ||
    fail "forwarded prompt was split into multiple arguments"
if grep -Fxq -- 'review' "$forwarded_argv_log" ||
   grep -Fxq -- 'this' "$forwarded_argv_log" ||
   grep -Fxq -- 'project' "$forwarded_argv_log"; then
    fail "forwarded prompt words leaked into separate arguments"
fi

forwarded_resume_output="$(
    "${launcher_env[@]}" "$ROOT/bin/run-codex" \
        --codex-option model=gpt-5.6-sol smoke-project
)"
assert_contains "$forwarded_resume_output" "resume --last --model gpt-5.6-sol"

for unsafe_codex_option in \
    '' \
    'sandbox=danger-full-access' \
    'config=approval_policy="never"' \
    'profile=unsafe' \
    'add-dir=/tmp' \
    'approve-for-me' \
    'dangerously-bypass-approvals-and-sandbox' \
    'remote=ws://example.invalid' \
    'enable=unknown' \
    'oss' \
    'local-provider=ollama'; do
    if "${launcher_env[@]}" "$ROOT/bin/run-codex" smoke-project \
        --codex-option "$unsafe_codex_option" \
        >"$TEST_ROOT/unsafe-codex-option.out" 2>&1; then
        fail "launcher accepted unsafe Codex option '$unsafe_codex_option'"
    fi
done
assert_contains "$(<"$TEST_ROOT/unsafe-codex-option.out")" \
    "Unsupported Codex option 'local-provider=ollama'"

if "${launcher_env[@]}" "$ROOT/bin/run-codex" smoke-project \
    --codex-option model=gpt-5.6-sol \
    --codex-option model=gpt-5.6-sol \
    >"$TEST_ROOT/duplicate-codex-option.out" 2>&1; then
    fail "launcher accepted a duplicate scalar Codex option"
fi
assert_contains "$(<"$TEST_ROOT/duplicate-codex-option.out")" \
    "Codex option 'model' may be specified only once"

printf '%s\n' 'outside' > "$TEST_ROOT/outside-image.png"
if "${launcher_env[@]}" "$ROOT/bin/run-codex" smoke-project \
    --codex-option "image=$TEST_ROOT/outside-image.png" \
    >"$TEST_ROOT/outside-image.out" 2>&1; then
    fail "launcher accepted an image outside the registered project"
fi
assert_contains "$(<"$TEST_ROOT/outside-image.out")" \
    "Codex image must resolve inside the registered project"

idea_output="$("${launcher_env[@]}" "$ROOT/bin/run-codex" --idea smoke-project)"
assert_contains "$idea_output" "--entrypoint /usr/local/bin/codex-entrypoint"
assert_contains "$idea_output" "/usr/local/bin/codex-acp-entrypoint"
assert_contains "$idea_output" "INITIAL_AGENT_MODE=read-only"
assert_contains "$idea_output" 'CODEX_PATH=/usr/local/share/npm-global/bin/codex'
assert_contains "$idea_output" 'approval_policy":"on-request"'
assert_contains "$idea_output" 'mcp_servers":{"idea":{"url":"http://127.0.0.1:64342/stream"'
assert_contains "$idea_output" 'enabled_tools":["analyze_calls","get_file_problems"'
assert_contains "$idea_output" 'default_tools_approval_mode":"writes"'
assert_contains "$idea_output" 'CODEX_IDEA_MCP_RELAY_SOCKET=/run/codex-idea-mcp/idea-mcp.sock'
assert_contains "$idea_output" 'CODEX_IDEA_MCP_RELAY_PORT=64342'
assert_contains "$idea_output" ':/run/codex-idea-mcp:ro'
assert_not_contains "$idea_output" '--network host'
assert_not_contains "$idea_output" 'mcp_servers":{"clojure_lsp'
assert_contains "$idea_output" "--name codex-smoke-project-idea-"
assert_contains "$idea_output" "$TEST_ROOT/repo:$TEST_ROOT/repo"
assert_contains "$idea_output" "--cidfile"
assert_contains "$idea_output" "--label codex-universal.mode=idea"
assert_contains "$idea_output" "--label codex-universal.project=smoke-project"
if [[ "$idea_output" == *"-it"* ]]; then
    fail "IDEA launcher allocated a TTY and would corrupt ACP stdio"
fi

lsp_disabled_output="$(
    "${launcher_env[@]}" CODEX_CLOJURE_LSP_MCP=0 \
        "$ROOT/bin/run-codex" smoke-project --new
)"
assert_not_contains "$lsp_disabled_output" "mcp_servers.clojure_lsp"
assert_contains "$lsp_disabled_output" "Clojure MCP: disabled (environment override: off)"

# Non-Clojure repositories should not pay the MCP startup or tool-catalog cost
# unless their project configuration or a one-shot environment override opts in.
mkdir -p "$TEST_ROOT/non-clojure-repo"
git -C "$TEST_ROOT/non-clojure-repo" init -q
"${launcher_env[@]}" "$ROOT/bin/run-codex" \
    --init plain-project "$TEST_ROOT/non-clojure-repo" >/dev/null
plain_output="$("${launcher_env[@]}" "$ROOT/bin/run-codex" plain-project --new)"
assert_not_contains "$plain_output" "mcp_servers.clojure_lsp"
assert_contains "$plain_output" \
    "Clojure MCP: disabled (no Clojure project signals detected)"

"${launcher_env[@]}" "$ROOT/bin/run-codex" \
    plain-project --set clojure-mcp on >/dev/null
plain_forced_output="$("${launcher_env[@]}" "$ROOT/bin/run-codex" plain-project --new)"
assert_contains "$plain_forced_output" "mcp_servers.clojure_lsp.enabled=true"
assert_contains "$plain_forced_output" "Clojure MCP: enabled (project setting: on)"

"${launcher_env[@]}" "$ROOT/bin/run-codex" \
    plain-project --set profile cuda >/dev/null
plain_config="$TEST_ROOT/launcher-config/run-codex/projects/plain-project"
grep -Fxq 'profile=cuda' "$plain_config" &&
    grep -Fxq 'clojure_mcp=on' "$plain_config" ||
    fail "project profile setter did not preserve the Clojure MCP setting"
"${launcher_env[@]}" "$ROOT/bin/run-codex" \
    plain-project --set profile generic >/dev/null

"${launcher_env[@]}" "$ROOT/bin/run-codex" \
    plain-project --set clojure-mcp auto >/dev/null
grep -Fxq 'clojure_mcp=auto' \
    "$TEST_ROOT/launcher-config/run-codex/projects/plain-project" ||
    fail "project Clojure MCP setter did not update the project configuration"

for removed_setter in --set-profile --set-clojure-mcp; do
    if "${launcher_env[@]}" "$ROOT/bin/run-codex" \
        "$removed_setter" plain-project value >"$TEST_ROOT/removed-setter.out" 2>&1; then
        fail "removed project setter '$removed_setter' was still accepted"
    fi
    grep -Fq "Unknown launch option '$removed_setter'" \
        "$TEST_ROOT/removed-setter.out" ||
        fail "removed project setter '$removed_setter' did not fail clearly"
done

set_error="$TEST_ROOT/project-setter-error.out"
if "${launcher_env[@]}" "$ROOT/bin/run-codex" \
    plain-project --set unknown value >"$set_error" 2>&1; then
    fail "project setter accepted an unknown setting"
fi
grep -Fq "Supported settings: profile, clojure-mcp" "$set_error" ||
    fail "unknown project setting error does not list supported settings"
if "${launcher_env[@]}" "$ROOT/bin/run-codex" \
    plain-project --set profile >"$set_error" 2>&1; then
    fail "project setter accepted a missing value"
fi
grep -Fq "Usage: run-codex PROJECT --set profile|clojure-mcp VALUE" \
    "$set_error" || fail "project setter arity error is not useful"

plain_env_output="$(
    "${launcher_env[@]}" CODEX_CLOJURE_LSP_MCP=1 \
        "$ROOT/bin/run-codex" plain-project --new
)"
assert_contains "$plain_env_output" "mcp_servers.clojure_lsp.enabled=true"
assert_contains "$plain_env_output" "Clojure MCP: enabled (environment override: on)"

# Registrations written by older launchers have no clojure_mcp field and must
# acquire the new auto behavior without being rewritten merely by launching.
mkdir -p "$TEST_ROOT/legacy-repo"
git -C "$TEST_ROOT/legacy-repo" init -q
legacy_config="$TEST_ROOT/launcher-config/run-codex/projects/legacy-project"
printf 'path=%s\nprofile=generic\n' "$TEST_ROOT/legacy-repo" > "$legacy_config"
legacy_before="$(<"$legacy_config")"
legacy_output="$("${launcher_env[@]}" "$ROOT/bin/run-codex" legacy-project --new)"
assert_not_contains "$legacy_output" "mcp_servers.clojure_lsp"
assert_contains "$legacy_output" \
    "Clojure MCP: disabled (no Clojure project signals detected)"
[[ "$(<"$legacy_config")" == "$legacy_before" ]] ||
    fail "launching rewrote a legacy project registration"

# IDEA may terminate the attached ACP launcher abruptly. Verify that the host
# launcher retains ownership of the container and removes its exact ID when
# the simulated Docker client exits.
mkdir -p "$TEST_ROOT/cleanup-bin"
cleanup_log="$TEST_ROOT/idea-cleanup.log"
cleanup_cid="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -Eeuo pipefail' \
    'if [[ "${1:-}" == run ]]; then' \
    '    while (($#)); do' \
    '        if [[ "$1" == --cidfile ]]; then' \
    '            printf "%s\\n" "$CODEX_TEST_CLEANUP_CID" > "$2"' \
    '            break' \
    '        fi' \
    '        shift' \
    '    done' \
    'elif [[ "${1:-}" == rm ]]; then' \
    '    printf "%s\\n" "$*" >> "$CODEX_TEST_CLEANUP_LOG"' \
    'fi' \
    > "$TEST_ROOT/cleanup-bin/docker"
chmod 755 "$TEST_ROOT/cleanup-bin/docker"

env \
    "HOME=$TEST_ROOT/launcher-home" \
    "XDG_CONFIG_HOME=$TEST_ROOT/launcher-config" \
    "CODEX_IMAGE_SLUG=example/codex-universal" \
    "CODEX_IMAGE_TAG=test-version" \
    "CODEX_GIT_USER_NAME=host-smoke" \
    "CODEX_GIT_USER_EMAIL=host-smoke.invalid" \
    "CODEX_TEST_SKIP_IDEA_MCP_RELAY=1" \
    "CODEX_SECCOMP_PROFILE=$ROOT/security/seccomp/codex-bwrap.json" \
    "CODEX_TEST_CLEANUP_CID=$cleanup_cid" \
    "CODEX_TEST_CLEANUP_LOG=$cleanup_log" \
    "PATH=$TEST_ROOT/cleanup-bin:$TEST_ROOT/fake-bin:$PATH" \
    "$ROOT/bin/run-codex" --idea smoke-project >/dev/null 2>&1

grep -Fxq "rm -f -- $cleanup_cid" "$cleanup_log" ||
    fail "IDEA launcher did not remove its container when ACP exited"

# SIGKILL cannot run the launcher's EXIT trap. The relay guard must receive a
# kernel parent-death signal, remove the exact container, and—most
# importantly—not retain either launcher lock descriptor.
test_idea_parent_death_cleanup() (
    local guard_runtime=""
    local guard_parent_pid=""
    local guard_pid=""
    local guard_relay_pid=""
    local process_pid=""
    local guard_ready=false
    local guard_cleanup_log="$TEST_ROOT/idea-guard-cleanup.log"
    local guard_cid="abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
    local guard_lock="$TEST_ROOT/idea-guard.lock"
    local guard_pid_file="$TEST_ROOT/idea-guard.pid"
    local guard_relay_pid_file="$TEST_ROOT/idea-guard-relay.pid"

    cleanup_guard_test() {
        trap - EXIT
        if [[ "$guard_parent_pid" =~ ^[0-9]+$ ]]; then
            kill "$guard_parent_pid" >/dev/null 2>&1 || true
            wait "$guard_parent_pid" 2>/dev/null || true
        fi
        if [[ "$guard_pid" =~ ^[0-9]+$ ]]; then
            kill "$guard_pid" >/dev/null 2>&1 || true
            wait "$guard_pid" 2>/dev/null || true
        fi
        if [[ -n "$guard_runtime" ]]; then
            rm -f -- \
                "$guard_runtime/container.cid" \
                "$guard_runtime/idea-mcp.sock" \
                "$guard_runtime/idea-mcp-relay.log"
            rmdir -- "$guard_runtime" 2>/dev/null || true
        fi
    }
    trap cleanup_guard_test EXIT

    mkdir -p "$TEST_ROOT/guard-bin"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -Eeuo pipefail' \
        'if [[ "${1:-}" == rm ]]; then' \
        '    printf "%s\\n" "$*" >> "$CODEX_TEST_GUARD_CLEANUP_LOG"' \
        'fi' \
        > "$TEST_ROOT/guard-bin/docker"
    chmod 755 "$TEST_ROOT/guard-bin/docker"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -Eeuo pipefail' \
        'printf "%s\\n" "$BASHPID" > "$CODEX_TEST_GUARD_RELAY_PID_FILE"' \
        'exec tail -f /dev/null' \
        > "$TEST_ROOT/guard-bin/socat"
    chmod 755 "$TEST_ROOT/guard-bin/socat"

    guard_runtime="$(mktemp -d -- /tmp/codex-idea-mcp.XXXXXX)"
    printf '%s\n' "$guard_cid" > "$guard_runtime/container.cid"

    (
        guard_launcher_pid="$BASHPID"
        exec 8>"$guard_lock"
        flock -x 8
        env \
            "CODEX_TEST_GUARD_CLEANUP_LOG=$guard_cleanup_log" \
            "CODEX_TEST_GUARD_RELAY_PID_FILE=$guard_relay_pid_file" \
            "PATH=$TEST_ROOT/guard-bin:$PATH" \
            setpriv --pdeathsig TERM -- \
            "$ROOT/bin/run-codex" --internal-idea-relay-guard \
            "$guard_launcher_pid" \
            "$guard_runtime" \
            "$guard_runtime/idea-mcp.sock" \
            "$guard_runtime/idea-mcp-relay.log" \
            64342 \
            "$guard_runtime/container.cid" \
            8>&- 9>&- &
        printf '%s\n' "$!" > "$guard_pid_file"
        wait
    ) &
    guard_parent_pid=$!

    for _ in {1..100}; do
        if [[ -s "$guard_pid_file" && -s "$guard_relay_pid_file" ]]; then
            guard_ready=true
            break
        fi
        kill -0 "$guard_parent_pid" 2>/dev/null || break
        sleep 0.05
    done
    $guard_ready || fail "IntelliJ relay guard did not become ready"
    guard_pid="$(<"$guard_pid_file")"
    guard_relay_pid="$(<"$guard_relay_pid_file")"
    [[ "$guard_pid" =~ ^[0-9]+$ ]] && kill -0 "$guard_pid" 2>/dev/null ||
        fail "IntelliJ relay guard exited before parent-death test"
    [[ "$guard_relay_pid" =~ ^[0-9]+$ ]] &&
        kill -0 "$guard_relay_pid" 2>/dev/null ||
        fail "IntelliJ relay exited before parent-death test"
    for process_pid in "$guard_pid" "$guard_relay_pid"; do
        [[ ! -e "/proc/$process_pid/fd/8" &&
           ! -e "/proc/$process_pid/fd/9" ]] ||
            fail "IntelliJ relay process inherited launcher lock descriptors"
    done
    if (exec 8>"$guard_lock"; flock -xn 8); then
        fail "parent-death test did not acquire its launcher lock"
    fi

    kill -KILL "$guard_parent_pid"
    wait "$guard_parent_pid" 2>/dev/null || true
    guard_parent_pid=""

    for _ in {1..100}; do
        if [[ ! -e "$guard_runtime" ]] && ! kill -0 "$guard_pid" 2>/dev/null; then
            guard_ready=true
            break
        fi
        guard_ready=false
        sleep 0.05
    done
    $guard_ready || fail "IntelliJ relay guard survived launcher SIGKILL"
    (exec 8>"$guard_lock"; flock -xn 8) ||
        fail "IntelliJ relay retained the project lock after launcher SIGKILL"
    grep -Fxq "rm -f -- $guard_cid" "$guard_cleanup_log" ||
        fail "IntelliJ relay guard did not remove its exact container"

    guard_pid=""
    guard_runtime=""
    trap - EXIT
)
test_idea_parent_death_cleanup

mkdir -p "$TEST_ROOT/no-jq-bin"
ln -s "$(type -P bash)" "$TEST_ROOT/no-jq-bin/bash"
ln -s "$(type -P dirname)" "$TEST_ROOT/no-jq-bin/dirname"
if env PATH="$TEST_ROOT/no-jq-bin" \
    "$ROOT/bin/run-codex" --idea smoke-project \
    >"$TEST_ROOT/no-jq.out" 2>"$TEST_ROOT/no-jq.err"; then
    fail "IDEA launcher accepted a host without jq"
fi
grep -Fxq 'ERROR: Missing command: jq' "$TEST_ROOT/no-jq.err" ||
    fail "IDEA launcher did not report missing jq"
pass "project registry and launcher policy"

# IDEA setup must merge its entry without replacing unrelated JetBrains
# settings or agents. Override paths keep the test entirely temporary.
ACP_FILE="$TEST_ROOT/jetbrains/acp.json"
mkdir -p "$(dirname "$ACP_FILE")"
printf '%s\n' '{"theme":"dark","agent_servers":{"Existing":{"command":"existing-agent"}}}' \
    > "$ACP_FILE"

env \
    "HOME=$TEST_ROOT/launcher-home" \
    "XDG_CONFIG_HOME=$TEST_ROOT/launcher-config" \
    "CODEX_IDEA_ACP_FILE=$ACP_FILE" \
    "CODEX_RUN_CODEX=$ROOT/bin/run-codex" \
    "$ROOT/bin/setup-codex-idea" smoke-project >/dev/null

jq -e '.theme == "dark"' "$ACP_FILE" >/dev/null ||
    fail "IDEA setup replaced unrelated top-level configuration"
jq -e '.agent_servers.Existing.command == "existing-agent"' "$ACP_FILE" >/dev/null ||
    fail "IDEA setup replaced an existing agent"
jq -e \
    --arg command "$(realpath -e "$ROOT/bin/run-codex")" \
    '.agent_servers["Dockerized Codex (smoke-project)"] == {
        "command": $command,
        "args": ["--idea", "smoke-project"],
        "use_idea_mcp": false,
        "use_custom_mcp": false
    }' "$ACP_FILE" >/dev/null ||
    fail "IDEA setup did not create the expected Dockerized Codex agent"
pass "JetBrains ACP configuration"

# Verify that one build is portable instead of capturing the builder's UID/GID.
# Use a clean fixture checkout so the explicit-version assertion is independent
# of the development worktree's dirty state.
portable_build_repo="$TEST_ROOT/portable-build"
mkdir -p -- "$portable_build_repo"
cp -- "$ROOT/docker-build.sh" "$ROOT/Dockerfile.generic" "$portable_build_repo/"
git -C "$portable_build_repo" init -q
git -C "$portable_build_repo" add docker-build.sh Dockerfile.generic
git -C "$portable_build_repo" \
    -c user.name=host-smoke \
    -c user.email=host-smoke.invalid \
    -c commit.gpgSign=false \
    commit -q -m initial
build_output="$(
    "${launcher_env[@]}" \
        IMAGE_SLUG=codex-host-smoke \
        IMAGE_VERSION=test-version \
        TAG_LATEST=1 \
        PULL=0 \
        "$portable_build_repo/docker-build.sh" generic
)"
assert_not_contains "$build_output" "--build-arg UID="
assert_not_contains "$build_output" "--build-arg GID="
assert_contains "$build_output" "--build-arg CODEX_VERSION=0.154.0"
assert_contains "$build_output" "--build-arg CODEX_ACP_VERSION=latest"
assert_contains "$build_output" "--build-arg AGENT_LSP_VERSION=latest"
assert_contains "$build_output" "--build-arg IMAGE_VERSION=test-version"
assert_contains "$build_output" "-t codex-host-smoke-generic:test-version"
assert_contains "$build_output" "-t codex-host-smoke-generic:latest"
pass "portable non-root image build policy"

# Explicit image names do not waive the repository's immutable Git-provenance
# requirement. Keep the failure clear instead of implying that IMAGE_VERSION
# alone makes a source tarball build supported.
mkdir -p -- "$TEST_ROOT/non-git-build"
cp -- "$ROOT/docker-build.sh" "$ROOT/Dockerfile.generic" \
    "$TEST_ROOT/non-git-build/"
set +e
non_git_build_output="$(
    env IMAGE_SLUG=codex-host-smoke IMAGE_VERSION=test-version \
        TAG_LATEST=0 PULL=0 \
        "$TEST_ROOT/non-git-build/docker-build.sh" generic 2>&1
)"
non_git_build_status=$?
set -e
(( non_git_build_status != 0 )) ||
    fail "explicit image metadata unexpectedly allowed a non-Git build"
assert_contains "$non_git_build_output" \
    "must run from a Git checkout to derive immutable image provenance"
pass "explicit image metadata preserves Git provenance requirement"

# A local checkout without an origin remote must still derive a version and
# use the documented fallback image slug without tripping Bash nounset mode.
mkdir -p "$TEST_ROOT/no-origin"
cp -- "$ROOT/docker-build.sh" "$ROOT/Dockerfile.generic" "$TEST_ROOT/no-origin/"
git -C "$TEST_ROOT/no-origin" init -q
git -C "$TEST_ROOT/no-origin" add docker-build.sh Dockerfile.generic
git -C "$TEST_ROOT/no-origin" \
    -c user.name=host-smoke \
    -c user.email=host-smoke.invalid \
    -c commit.gpgSign=false \
    commit -q -m initial

no_origin_output="$(
    "${launcher_env[@]}" \
        TAG_LATEST=0 \
        PULL=0 \
        "$TEST_ROOT/no-origin/docker-build.sh" generic
)"
assert_contains "$no_origin_output" "leafclick/codex-universal-generic:dev-"
assert_contains "$no_origin_output" "--build-arg IMAGE_SOURCE="
pass "Git metadata fallback without origin"

# Git-derived image versions must remain stable and informative in isolated
# local checkouts. Keep these builds behind the fake Docker frontend above so
# the cases do not require a daemon, network, or image build.
make_version_repo() {
    local repo="$1"
    mkdir -p -- "$repo"
    cp -- "$ROOT/docker-build.sh" "$ROOT/Dockerfile.generic" "$repo/"
    git -C "$repo" init -q
    git -C "$repo" config user.name host-smoke
    git -C "$repo" config user.email host-smoke.invalid
    git -C "$repo" add docker-build.sh Dockerfile.generic
    git -C "$repo" commit -q -m initial
}

tagged_repo="$TEST_ROOT/tagged-version"
make_version_repo "$tagged_repo"
git -C "$tagged_repo" tag 'Release/1.2.3'
tagged_output="$({
    cd -- "$tagged_repo"
    env PATH="$TEST_ROOT/fake-bin:$PATH" TAG_LATEST=0 PULL=0 ./docker-build.sh generic
})"
assert_contains "$tagged_output" \
    "-t leafclick/codex-universal-generic:release-1.2.3"
pass "exact Git tag image version slug"

descended_repo="$TEST_ROOT/descended-version"
make_version_repo "$descended_repo"
git -C "$descended_repo" tag v2.4.0
printf '%s\n' descended > "$descended_repo/marker"
git -C "$descended_repo" add marker
git -C "$descended_repo" commit -q -m descended
descended_sha="$(git -C "$descended_repo" rev-parse --short=12 HEAD)"
descended_output="$({
    cd -- "$descended_repo"
    env PATH="$TEST_ROOT/fake-bin:$PATH" TAG_LATEST=0 PULL=0 ./docker-build.sh generic
})"
assert_contains "$descended_output" \
    "-t leafclick/codex-universal-generic:v2.4.0-1-g$descended_sha"
assert_not_contains "$descended_output" "dev-master-$descended_sha"
pass "descended Git tag image version"

long_descended_repo="$TEST_ROOT/long-descended-version"
make_version_repo "$long_descended_repo"
long_tag="release-$(printf 'x%.0s' {1..110})"
git -C "$long_descended_repo" tag "$long_tag"
printf '%s\n' long-descended > "$long_descended_repo/marker"
git -C "$long_descended_repo" add marker
git -C "$long_descended_repo" commit -q -m long-descended
long_descended_sha="$(git -C "$long_descended_repo" rev-parse --short=12 HEAD)"
long_descended_output="$({
    cd -- "$long_descended_repo"
    env PATH="$TEST_ROOT/fake-bin:$PATH" TAG_LATEST=0 PULL=0 ./docker-build.sh generic
})"
assert_contains "$long_descended_output" "-1-g$long_descended_sha"
pass "long Git tag preserves descendant suffix"

fallback_repo="$TEST_ROOT/fallback-version"
make_version_repo "$fallback_repo"
git -C "$fallback_repo" checkout -q -b 'feature/smoke'
fallback_sha="$(git -C "$fallback_repo" rev-parse --short=12 HEAD)"
fallback_output="$({
    cd -- "$fallback_repo"
    env PATH="$TEST_ROOT/fake-bin:$PATH" TAG_LATEST=0 PULL=0 ./docker-build.sh generic
})"
assert_contains "$fallback_output" \
    "-t leafclick/codex-universal-generic:dev-feature-smoke-$fallback_sha"
pass "unreachable-tag Git branch fallback image version"

mkdir -p -- "$tagged_repo/container"
printf '%s\n' dirty > "$tagged_repo/container/untracked"
dirty_output="$({
    cd -- "$tagged_repo"
    env PATH="$TEST_ROOT/fake-bin:$PATH" TAG_LATEST=1 PULL=0 \
        ./docker-build.sh generic 2>&1
})"
assert_contains "$dirty_output" \
    "-t leafclick/codex-universal-generic:release-1.2.3-dirty"
assert_contains "$dirty_output" \
    "-t leafclick/codex-universal-generic:latest"
assert_contains "$dirty_output" \
    "dirty image inputs are updating leafclick/codex-universal-generic:latest; use TAG_LATEST=0 to retain the existing alias"
pass "dirty Git-derived image version suffix"

explicit_dirty_output="$({
    cd -- "$tagged_repo"
    env PATH="$TEST_ROOT/fake-bin:$PATH" IMAGE_VERSION=manual-version \
        TAG_LATEST=1 PULL=0 ./docker-build.sh generic 2>&1
})"
assert_contains "$explicit_dirty_output" \
    "-t leafclick/codex-universal-generic:manual-version-dirty"
assert_contains "$explicit_dirty_output" \
    "-t leafclick/codex-universal-generic:latest"
assert_contains "$explicit_dirty_output" \
    "dirty image inputs are updating leafclick/codex-universal-generic:latest; use TAG_LATEST=0 to retain the existing alias"
pass "explicit dirty image version and latest warning"

rm -f -- "$tagged_repo/container/untracked"
rmdir -- "$tagged_repo/container"
printf '%s\n' review-only > "$tagged_repo/review.md"
unrelated_dirty_output="$({
    cd -- "$tagged_repo"
    env PATH="$TEST_ROOT/fake-bin:$PATH" TAG_LATEST=1 PULL=0 \
        ./docker-build.sh generic 2>&1
})"
assert_contains "$unrelated_dirty_output" \
    "-t leafclick/codex-universal-generic:release-1.2.3"
assert_contains "$unrelated_dirty_output" \
    "-t leafclick/codex-universal-generic:latest"
assert_not_contains "$unrelated_dirty_output" "-dirty"
pass "unrelated untracked file does not dirty image inputs"

git -C "$tagged_repo" remote add origin \
    'https://build-user:build-secret@example.com/acme/codex-universal.git'
credential_source_output="$({
    cd -- "$tagged_repo"
    env PATH="$TEST_ROOT/fake-bin:$PATH" TAG_LATEST=0 PULL=0 \
        ./docker-build.sh generic
})"
assert_not_contains "$credential_source_output" "build-user"
assert_not_contains "$credential_source_output" "build-secret"
assert_contains "$credential_source_output" \
    "--build-arg IMAGE_SOURCE=https://example.com/acme/codex-universal"
pass "sanitized Git image source metadata"

"$ROOT/tests/host-smoke-sync.sh"

# If built images and a Docker daemon are present, inspect the real containers.
# The host does not need Codex installed; Codex is invoked only in the images.
# CODEX_TEST_IMAGE remains a compatibility alias for the generic image.
GENERIC_TEST_IMAGE="${CODEX_TEST_GENERIC_IMAGE:-${CODEX_TEST_IMAGE:-leafclick/codex-universal-generic:latest}}"
CUDA_TEST_IMAGE="${CODEX_TEST_CUDA_IMAGE:-leafclick/codex-universal-cuda:latest}"

smoke_image() {
    local profile="$1"
    local image="$2"
    local runtime_uid=42424
    local runtime_gid=42425
    local docker_args=(
        run
        --rm
        --pull=never
        --network none
        --read-only
        --tmpfs "/home/codex:rw,exec,nosuid,nodev,uid=$runtime_uid,gid=$runtime_gid,mode=0700"
        --tmpfs "/tmp:rw,exec,nosuid,nodev,mode=1777"
        --tmpfs "/workspace:rw,nosuid,nodev,uid=$runtime_uid,gid=$runtime_gid,mode=0700"
        --cap-drop=ALL
        --security-opt=no-new-privileges
        --security-opt apparmor=codex-universal
        --security-opt "seccomp=$ROOT/security/seccomp/codex-bwrap.json"
        --user "$runtime_uid:$runtime_gid"
        -e HOME=/home/codex
        -w /workspace
        --entrypoint /usr/local/bin/codex-entrypoint
    )

    if [[ "$profile" == cuda ]]; then
        docker_args+=(--gpus all)
    fi

    docker_args+=("$image" /bin/bash)

    docker "${docker_args[@]}" -c '
        set -Eeuo pipefail
        [[ "$(id -u)" == "$2" ]]
        [[ "$(id -g)" == "$3" ]]
        [[ "$(id -un)" == codex ]]
        [[ "$(id -gn)" == codex ]]
        [[ -z "${LD_PRELOAD:-}" ]]
        [[ -z "${NSS_WRAPPER_PASSWD:-}" ]]
        [[ -z "${NSS_WRAPPER_GROUP:-}" ]]
        passwd_entry="$(getent passwd "$2")"
        group_entry="$(getent group "$3")"
        [[ "$passwd_entry" == "codex:x:$2:$3:"*":$HOME:/bin/bash" ]]
        [[ "$group_entry" == "codex:x:$3:" ]]
        [[ "$(getent passwd codex)" == "$passwd_entry" ]]
        [[ "$(getent group codex)" == "$group_entry" ]]
        grep -Eq "^passwd:[[:space:]]+codex([[:space:]]|$)" /etc/nsswitch.conf
        grep -Eq "^group:[[:space:]]+codex([[:space:]]|$)" /etc/nsswitch.conf
        touch "$HOME/runtime-home-is-writable"
        touch /tmp/runtime-tmp-is-writable
        touch /workspace/runtime-workspace-is-writable
        printf "#!/bin/sh\nexit 0\n" > "$HOME/runtime-home-is-executable"
        chmod 0700 "$HOME/runtime-home-is-executable"
        "$HOME/runtime-home-is-executable"
        printf "#!/bin/sh\nexit 0\n" > /tmp/runtime-tmp-is-executable
        chmod 0700 /tmp/runtime-tmp-is-executable
        /tmp/runtime-tmp-is-executable
        if touch /usr/local/bin/image-root-is-read-only 2>/dev/null; then
            exit 1
        fi
        root_mount_options=""
        while read -r _ mountpoint _ options _; do
            if [[ "$mountpoint" == / ]]; then
                root_mount_options="$options"
                break
            fi
        done < /proc/mounts
        [[ ",$root_mount_options," == *,ro,* ]]
        command -v bwrap >/dev/null
        command -v codex >/dev/null
        command -v codex-acp >/dev/null
        command -v codex-acp-entrypoint >/dev/null
        command -v agent-lsp >/dev/null
        command -v codex-clojure-lsp-mcp >/dev/null
        command -v codex-lsp-message-proxy >/dev/null
        command -v codex-no-nested-userns >/dev/null
        command -v lsof >/dev/null
        command -v setsid >/dev/null
        command -v bb >/dev/null
        command -v clj >/dev/null
        command -v lein >/dev/null
        command -v cljfmt >/dev/null
        command -v clj-kondo >/dev/null
        command -v clojure-lsp >/dev/null
        command -v rlwrap >/dev/null
        command -v socat >/dev/null
        command -v zstd >/dev/null
        [[ "$LEIN_JAR" == /opt/clojure/leiningen-standalone.jar ]]
        [[ -r "$LEIN_JAR" ]]
        lein version
        rlwrap --version
        test -r /etc/codex/requirements.toml
        [[ "$(stat -c %a /etc/codex)" == 755 ]]
        [[ "$(stat -c %u /usr/local/bin/codex-entrypoint)" == 0 ]]
        [[ "$(stat -c %u /usr/local/share/npm-global/bin/codex)" == 0 ]]
        [[ "$(stat -c %u /etc/codex/requirements.toml)" == 0 ]]
        [[ "$(awk '\''$1 == "CapEff:" {print $2}'\'' /proc/self/status)" == 0000000000000000 ]]
        [[ "$(awk '\''$1 == "NoNewPrivs:" {print $2}'\'' /proc/self/status)" == 1 ]]
        [[ "$(cat /proc/self/attr/current)" == "codex-universal (enforce)" ]]
        test -x /usr/local/share/codex-universal/workflow/skills/clojure-development/scripts/clojure-development
        test -x /usr/local/share/codex-universal/workflow/skills/clojure-development/scripts/clojure-process-supervisor
        test -x /usr/local/share/codex-universal/workflow/scripts/codex-worker-observe
        test -p "$CODEX_CLOJURE_STATE_DIR/service-control.fifo"
        /usr/local/share/codex-universal/workflow/skills/clojure-development/scripts/clojure-process-supervisor \
            control "$CODEX_CLOJURE_STATE_DIR/service-control.fifo" neutral status \
            | grep -Fxq stopped
        nss_module="$(find /usr/lib -name libnss_codex.so.2 -print -quit)"
        [[ -n "$nss_module" && "$(stat -c %u:%g:%a "$nss_module")" == 0:0:644 ]]
        bwrap \
            --unshare-user \
            --unshare-net \
            --ro-bind / / \
            --dev /dev \
            --proc /proc \
            --tmpfs /tmp \
            -- \
            /bin/bash -c '\''
                set -Eeuo pipefail
                [[ "$(id -un)" == codex && "$(id -gn)" == codex ]]
                [[ -z "${LD_PRELOAD:-}" ]]
                [[ -z "${NSS_WRAPPER_PASSWD:-}" ]]
                [[ -z "${NSS_WRAPPER_GROUP:-}" ]]
                printf "#!/bin/sh\nexit 0\n" > /tmp/sandbox-tmp-is-executable
                chmod 0700 /tmp/sandbox-tmp-is-executable
                /tmp/sandbox-tmp-is-executable
            '\''
        fixture_dir="$HOME/clojure-lsp-smoke"
        mkdir -p "$fixture_dir/src/example" "$fixture_dir/test/example" "$fixture_dir/dev"
        printf "%s\n" \
            "{:paths [\"src\" \"test\" \"dev\"] :aliases {:dev {} :test {}}}" \
            > "$fixture_dir/deps.edn"
        printf "%s\n" \
            "(ns example.core)" \
            "(defn public-fn [] :ok)" \
            > "$fixture_dir/src/example/core.clj"
        printf "%s\n" \
            "(ns example.core-test" \
            "  (:require [clojure.test :refer [deftest is]]" \
            "            [example.core :as sut]))" \
            "(deftest public-fn-test" \
            "  (is (= :ok (sut/public-fn))))" \
            > "$fixture_dir/test/example/core_test.clj"
        cd "$fixture_dir"
        coproc MCP_BRIDGE {
            exec codex-clojure-lsp-mcp clojure:clojure-lsp
        }
        mcp_pid="$MCP_BRIDGE_PID"
        mcp_input_fd="${MCP_BRIDGE[1]}"
        mcp_output_fd="${MCP_BRIDGE[0]}"
        mcp_ready=0
        printf '\''%s\n'\'' \
            '\''{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"host-smoke","version":"1"}}}'\'' \
            >&"$mcp_input_fd"
        for _ in {1..10}; do
            if IFS= read -r -t 1 -u "$mcp_output_fd" mcp_line &&
               jq -e \
                   '\''.id == 1 and .result.serverInfo.name == "agent-lsp"'\'' \
                   <<<"$mcp_line" >/dev/null 2>&1; then
                mcp_ready=1
                break
            fi
        done
        (( mcp_ready == 1 ))
        lsp_ready=0
        printf '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"start_lsp","arguments":{"root_dir":"%s","language_id":"clojure","ready_timeout_seconds":60}}}\n' \
            "$fixture_dir" >&"$mcp_input_fd"
        for _ in {1..75}; do
            if IFS= read -r -t 1 -u "$mcp_output_fd" mcp_line &&
               jq -e \
                   '\''.id == 2 and .result.content[0].text == "LSP server started successfully"'\'' \
                   <<<"$mcp_line" >/dev/null 2>&1; then
                lsp_ready=1
                break
            fi
        done
        (( lsp_ready == 1 ))
        references_ready=0
        printf '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"find_references","arguments":{"file_path":"%s/src/example/core.clj","line":2,"column":7,"language_id":"clojure","include_declaration":true}}}\n' \
            "$fixture_dir" >&"$mcp_input_fd"
        for _ in {1..75}; do
            if IFS= read -r -t 1 -u "$mcp_output_fd" mcp_line &&
               jq -e --arg test_file "$fixture_dir/test/example/core_test.clj" \
                   '\''.id == 3 and ([.result.content[]?.text] | join("\\n") | contains($test_file))'\'' \
                   <<<"$mcp_line" >/dev/null 2>&1; then
                references_ready=1
                break
            fi
        done
        kill "$mcp_pid" 2>/dev/null || true
        wait "$mcp_pid" 2>/dev/null || true
        (( references_ready == 1 ))
        codex-clojure-lsp-mcp --check-java >/dev/null
        codex --version
        bb --version
        cljfmt --version
        clj-kondo --version
        clojure-lsp --version
        codex \
            --sandbox workspace-write \
            --ask-for-approval on-request \
            -c '\''approvals_reviewer="user"'\'' \
            --help >/dev/null
        if [[ "$1" == cuda ]]; then
            # The CUDA wrapper (installed as /usr/bin/bwrap) must re-expose the
            # NVIDIA device nodes AFTER Codex'\''s own `--dev /dev`. bwrap applies
            # options in order, so an earlier `--dev /dev` mounts a fresh devtmpfs
            # that would discard binds emitted before it. nvidia-smi uses NVML and
            # would pass even with the nodes missing, so assert the nodes directly.
            if [[ -e /dev/nvidiactl ]]; then
                bwrap \
                    --unshare-user \
                    --ro-bind / / \
                    --dev /dev \
                    --proc /proc \
                    --tmpfs /tmp \
                    -- \
                    /bin/bash -c '\''
                        set -Eeuo pipefail
                        test -e /dev/nvidiactl
                        test -e /dev/nvidia0 || ls /dev/nvidia[0-9]* >/dev/null
                    '\''
            fi
            bwrap \
                --unshare-user \
                --ro-bind / / \
                --dev /dev \
                --proc /proc \
                --tmpfs /tmp \
                -- \
                /bin/bash -c "nvidia-smi >/dev/null"
            [[ "${CODEX_NVIDIA_ENTRYPOINT_RAN:-}" == 1 ]]
            command -v nvcc >/dev/null
            command -v nvidia-smi >/dev/null
            test -f /usr/local/cuda/include/cuda.h
            test -f /usr/local/cuda/include/cuda_runtime.h
            nvcc --version
            nvidia-smi >/dev/null
        fi
    ' host-smoke "$profile" "$runtime_uid" "$runtime_gid"
    pass "$profile container image $image"
}

if [[ "${CODEX_TEST_SKIP_IMAGE:-0}" == 1 ]]; then
    printf 'skip - container images (CODEX_TEST_SKIP_IMAGE=1)\n'
elif ! command -v docker >/dev/null 2>&1 ||
     ! docker info >/dev/null 2>&1; then
    printf 'skip - container images (Docker daemon is not available)\n'
else
    if docker image inspect "$GENERIC_TEST_IMAGE" >/dev/null 2>&1; then
        smoke_image generic "$GENERIC_TEST_IMAGE"
    else
        printf 'skip - generic container image %s is not locally available\n' \
            "$GENERIC_TEST_IMAGE"
    fi

    if [[ "${CODEX_TEST_SKIP_CUDA:-0}" == 1 ]]; then
        printf 'skip - CUDA container image (CODEX_TEST_SKIP_CUDA=1)\n'
    elif docker image inspect "$CUDA_TEST_IMAGE" >/dev/null 2>&1; then
        smoke_image cuda "$CUDA_TEST_IMAGE"
    else
        printf 'skip - CUDA container image %s is not locally available\n' \
            "$CUDA_TEST_IMAGE"
    fi
fi

printf '\n=== ALL HOST SMOKE TESTS PASSED ===\n'
