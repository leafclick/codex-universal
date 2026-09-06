#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

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

for command in bash git grep jq realpath; do
    need "$command"
done

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
fi

git -C "$ROOT" diff --check
git -C "$ROOT" diff --cached --check

for script in \
    "$ROOT/docker-build.sh" \
    "$ROOT/bin/run-codex" \
    "$ROOT/bin/setup-codex-host-security" \
    "$ROOT/bin/setup-codex-idea" \
    "$ROOT/bin/codex-push" \
    "$ROOT/bin/codex-pull" \
    "$ROOT/container/codex-entrypoint" \
    "$ROOT/container/codex-acp-entrypoint" \
    "$ROOT/container/codex-clojure-lsp-mcp" \
    "$ROOT/container/install-clojure-tools"; do
    bash -n "$script"
done

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
grep -Fq -- '--unshare-net' "$ROOT/container/codex-clojure-lsp-mcp" ||
    fail "Clojure LSP MCP bridge is not network-isolated"
grep -Fq -- '--unshare-pid' "$ROOT/container/codex-clojure-lsp-mcp" ||
    fail "Clojure LSP MCP bridge is not PID-isolated"
grep -Fq -- '--tmpfs /proc' "$ROOT/container/codex-clojure-lsp-mcp" ||
    fail "Clojure LSP MCP bridge does not hide the outer procfs"
if grep -Fq -- '--proc /proc' "$ROOT/container/codex-clojure-lsp-mcp"; then
    fail "Clojure LSP MCP bridge mounts procfs inside its private PID namespace"
fi
grep -Fq -- '\( -name .git -o -name .codex \) -prune -print0' \
    "$ROOT/container/codex-clojure-lsp-mcp" ||
    fail "Clojure LSP MCP bridge does not protect nested Git/Codex metadata"
grep -q '^profile codex-universal ' \
    "$ROOT/security/apparmor/codex-universal" ||
    fail "outer AppArmor profile is missing"
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
    grep -qE '^[[:space:]]+socat([[:space:]\\]|$)' "$dockerfile" ||
        fail "$(basename "$dockerfile") does not install the IntelliJ MCP relay"
    grep -qE '^[[:space:]]+libnss-wrapper([[:space:]\\]|$)' "$dockerfile" ||
        fail "$(basename "$dockerfile") does not install arbitrary-user NSS support"
    grep -Fxq 'USER 65532:65532' "$dockerfile" ||
        fail "$(basename "$dockerfile") does not declare the portable non-root user"
    grep -q 'container/codex-entrypoint /usr/local/bin/codex-entrypoint' "$dockerfile" ||
        fail "$(basename "$dockerfile") does not install the portable-user entrypoint"
    if grep -qE '^ARG (UID|GID)=' "$dockerfile"; then
        fail "$(basename "$dockerfile") still bakes the host UID/GID into the image"
    fi
done
grep -Fq 'exec /opt/nvidia/nvidia_entrypoint.sh "$0" "$@"' \
    "$ROOT/container/codex-entrypoint" ||
    fail "portable-user entrypoint does not preserve NVIDIA initialization"
grep -Fq 'exec 1>&3 3>&-' "$ROOT/container/codex-entrypoint" ||
    fail "portable-user entrypoint does not restore CUDA ACP stdout"
grep -Fq 'TCP4-LISTEN:${relay_port},bind=127.0.0.1' \
    "$ROOT/container/codex-acp-entrypoint" ||
    fail "ACP entrypoint does not restrict its MCP relay to container loopback"
pass "shell syntax and static security invariants"

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
assert_contains "$launcher_help" "reasoning=minimal|low|medium|high|xhigh"
assert_contains "$launcher_help" "image=PROJECT_PATH"

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
assert_contains "$doctor_output" "PASS  AppArmor, seccomp, and Bubblewrap sandbox probe"
assert_contains "$doctor_output" \
    "PASS  Portable runtime identity, read-only image, tools, and managed Codex policy"
assert_contains "$doctor_output" "PASS  Clojure LSP MCP handshake and tool allowlist"
assert_contains "$doctor_output" "Diagnostics passed with 0 warning(s)."
assert_contains "$doctor_output" "--network none"
assert_contains "$doctor_output" "--cap-drop=ALL"
assert_not_contains "$doctor_output" "$TEST_ROOT/repo:"

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
    assert_contains "$output" "--tmpfs /home/codex:rw,nosuid,nodev,uid=$(id -u),gid=$(id -g),mode=0700"
    assert_contains "$output" "--tmpfs /tmp:rw,nosuid,nodev,mode=1777"
    assert_contains "$output" \
        "--tmpfs /run/codex-runtime:rw,nosuid,nodev,noexec,uid=$(id -u),gid=$(id -g),mode=0700"
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
    --set-clojure-mcp plain-project on >/dev/null
plain_forced_output="$("${launcher_env[@]}" "$ROOT/bin/run-codex" plain-project --new)"
assert_contains "$plain_forced_output" "mcp_servers.clojure_lsp.enabled=true"
assert_contains "$plain_forced_output" "Clojure MCP: enabled (project setting: on)"

"${launcher_env[@]}" "$ROOT/bin/run-codex" \
    --set-profile plain-project cuda >/dev/null
plain_config="$TEST_ROOT/launcher-config/run-codex/projects/plain-project"
grep -Fxq 'profile=cuda' "$plain_config" &&
    grep -Fxq 'clojure_mcp=on' "$plain_config" ||
    fail "--set-profile did not preserve the Clojure MCP setting"
"${launcher_env[@]}" "$ROOT/bin/run-codex" \
    --set-profile plain-project generic >/dev/null

"${launcher_env[@]}" "$ROOT/bin/run-codex" \
    --set-clojure-mcp plain-project auto >/dev/null
grep -Fxq 'clojure_mcp=auto' \
    "$TEST_ROOT/launcher-config/run-codex/projects/plain-project" ||
    fail "--set-clojure-mcp did not update the project configuration"

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
build_output="$(
    "${launcher_env[@]}" \
        IMAGE_SLUG=codex-host-smoke \
        IMAGE_VERSION=test-version \
        TAG_LATEST=1 \
        PULL=0 \
        "$ROOT/docker-build.sh" generic
)"
assert_not_contains "$build_output" "--build-arg UID="
assert_not_contains "$build_output" "--build-arg GID="
assert_contains "$build_output" "--build-arg CODEX_ACP_VERSION=latest"
assert_contains "$build_output" "--build-arg AGENT_LSP_VERSION=latest"
assert_contains "$build_output" "--build-arg IMAGE_VERSION=test-version"
assert_contains "$build_output" "-t codex-host-smoke-generic:test-version"
assert_contains "$build_output" "-t codex-host-smoke-generic:latest"
pass "portable non-root image build policy"

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

if [[ "${CODEX_TEST_SKIP_SYNC:-0}" != 1 ]]; then
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
    sqlite3 "$TEST_ROOT/a/live/state.sqlite" \
        'CREATE TABLE smoke (value TEXT); INSERT INTO smoke VALUES ("ok");'

    if env \
        "HOME=$TEST_ROOT/a/home" \
        "CODEX_DIR=$TEST_ROOT/a/live" \
        'CODEX_SYNC_DIR=relative/sync' \
        "CODEX_LOCK_FILE=$LOCK_FILE" \
        "XDG_STATE_HOME=$TEST_ROOT/a/state" \
        "$ROOT/bin/codex-push" >/dev/null 2>&1; then
        fail "snapshot push accepted a relative synchronization path"
    fi
    if env \
        "HOME=$TEST_ROOT/a/home" \
        "CODEX_DIR=$TEST_ROOT/a/live" \
        "CODEX_SYNC_DIR=$TEST_ROOT/a/live/snapshots" \
        "CODEX_LOCK_FILE=$LOCK_FILE" \
        "XDG_STATE_HOME=$TEST_ROOT/a/state" \
        "$ROOT/bin/codex-pull" --list >/dev/null 2>&1; then
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
        run_machine a "$ROOT/bin/codex-push" \
        >"$TEST_ROOT/offenders.log" 2>&1; then
        fail "snapshot push ignored running Codex containers"
    fi
    grep -Fxq '  codex-first' "$TEST_ROOT/offenders.log" &&
        grep -Fxq '  codex-second' "$TEST_ROOT/offenders.log" ||
        fail "snapshot push did not report every running Codex container"

    run_machine a "$ROOT/bin/codex-push" >/dev/null
    no_change="$(run_machine a "$ROOT/bin/codex-push")"
    assert_contains "$no_change" "No changes"

    mkdir -p "$TEST_ROOT/b/live" "$TEST_ROOT/b/home"
    printf 'replace me\n' > "$TEST_ROOT/b/live/payload"
    run_machine b "$ROOT/bin/codex-pull" --force 1 >/dev/null
    [[ "$(sha256sum "$TEST_ROOT/a/live/payload" | awk '{print $1}')" == \
       "$(sha256sum "$TEST_ROOT/b/live/payload" | awk '{print $1}')" ]] ||
        fail "forced pull did not restore generation 1"

    printf 'generation two\n' > "$TEST_ROOT/a/live/payload"
    run_machine a "$ROOT/bin/codex-push" >/dev/null
    run_machine b "$ROOT/bin/codex-pull" >/dev/null
    [[ "$(sha256sum "$TEST_ROOT/a/live/payload" | awk '{print $1}')" == \
       "$(sha256sum "$TEST_ROOT/b/live/payload" | awk '{print $1}')" ]] ||
        fail "forward pull did not restore generation 2"

    printf 'local divergence\n' > "$TEST_ROOT/b/live/payload"
    printf 'generation three\n' > "$TEST_ROOT/a/live/payload"
    run_machine a "$ROOT/bin/codex-push" >/dev/null
    if run_machine b "$ROOT/bin/codex-pull" \
        >"$TEST_ROOT/divergence.log" 2>&1; then
        fail "divergent pull unexpectedly succeeded"
    fi
    grep -q 'DIVERGENCE' "$TEST_ROOT/divergence.log" ||
        fail "divergent pull did not report divergence"

    run_machine b "$ROOT/bin/codex-pull" --force 1 >/dev/null
    run_machine b "$ROOT/bin/codex-push" >/dev/null
    grep -R -q '^generation=4$' "$SYNC_ROOT"/*.state ||
        fail "recovery did not publish a new generation"

    snapshot_list="$(run_machine b "$ROOT/bin/codex-pull" --list)"
    [[ "$snapshot_list" == *"OK"* ]] ||
        fail "snapshot listing did not report valid archives: $snapshot_list"
    pass "snapshot push, pull, divergence, and recovery"
else
    printf 'skip - snapshot integration (CODEX_TEST_SKIP_SYNC=1)\n'
fi

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
        --tmpfs "/home/codex:rw,nosuid,nodev,uid=$runtime_uid,gid=$runtime_gid,mode=0700"
        --tmpfs "/tmp:rw,nosuid,nodev,mode=1777"
        --tmpfs "/run/codex-runtime:rw,nosuid,nodev,noexec,uid=$runtime_uid,gid=$runtime_gid,mode=0700"
        --tmpfs "/workspace:rw,nosuid,nodev,uid=$runtime_uid,gid=$runtime_gid,mode=0700"
        --cap-drop=ALL
        --security-opt=no-new-privileges
        --security-opt apparmor=codex-universal
        --security-opt "seccomp=$ROOT/security/seccomp/codex-bwrap.json"
        --user "$runtime_uid:$runtime_gid"
        -e HOME=/home/codex
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
        [[ "$NSS_WRAPPER_PASSWD" == /run/codex-runtime/* ]]
        [[ -r "$NSS_WRAPPER_PASSWD" && -r "$NSS_WRAPPER_GROUP" ]]
        touch "$HOME/runtime-home-is-writable"
        touch /tmp/runtime-tmp-is-writable
        touch /workspace/runtime-workspace-is-writable
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
        command -v bb >/dev/null
        command -v cljfmt >/dev/null
        command -v clj-kondo >/dev/null
        command -v clojure-lsp >/dev/null
        command -v socat >/dev/null
        command -v zstd >/dev/null
        test -r /etc/codex/requirements.toml
        [[ "$(stat -c %u /usr/local/bin/codex-entrypoint)" == 0 ]]
        [[ "$(stat -c %u /usr/local/share/npm-global/bin/codex)" == 0 ]]
        [[ "$(stat -c %u /etc/codex/requirements.toml)" == 0 ]]
        bwrap \
            --unshare-user \
            --unshare-pid \
            --unshare-net \
            --ro-bind / / \
            --tmpfs /proc \
            --tmpfs /tmp \
            /bin/bash -c '\''[[ "$(id -un)" == codex && "$(id -gn)" == codex ]]'\''
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
        kill "$mcp_pid" 2>/dev/null || true
        wait "$mcp_pid" 2>/dev/null || true
        (( mcp_ready == 1 ))
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

printf 'All host smoke tests passed.\n'
