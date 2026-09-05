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
    "$ROOT/container/codex-acp-entrypoint"; do
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
done
pass "shell syntax and static security invariants"

# The launcher smoke test uses echo as a Docker frontend. This verifies the
# complete argument vector without requiring Docker or Codex on the host.
mkdir -p "$TEST_ROOT/fake-bin" "$TEST_ROOT/launcher-home" "$TEST_ROOT/repo"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -Eeuo pipefail' \
    'case "${1:-}" in' \
    '    info|ps) exit 0 ;;' \
    '    image) exit 0 ;;' \
    '    run|build) printf "%s\\n" "$*" ;;' \
    '    *) exit 0 ;;' \
    'esac' \
    > "$TEST_ROOT/fake-bin/docker"
chmod 755 "$TEST_ROOT/fake-bin/docker"
git -C "$TEST_ROOT/repo" init -q

launcher_env=(
    env
    "HOME=$TEST_ROOT/launcher-home"
    "XDG_CONFIG_HOME=$TEST_ROOT/launcher-config"
    "CODEX_IMAGE_SLUG=example/codex-universal"
    "CODEX_IMAGE_TAG=test-version"
    "CODEX_GIT_USER_NAME=host-smoke"
    "CODEX_GIT_USER_EMAIL=host-smoke.invalid"
    "CODEX_SECCOMP_PROFILE=$ROOT/security/seccomp/codex-bwrap.json"
    "PATH=$TEST_ROOT/fake-bin:$PATH"
)

"${launcher_env[@]}" "$ROOT/bin/run-codex" \
    --init --profile generic smoke-project "$TEST_ROOT/repo" >/dev/null

project_config="$TEST_ROOT/launcher-config/run-codex/projects/smoke-project"
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
assert_contains "$list_output" "OK"

new_output="$("${launcher_env[@]}" "$ROOT/bin/run-codex" smoke-project --new)"
resume_output="$("${launcher_env[@]}" "$ROOT/bin/run-codex" smoke-project)"

for output in "$new_output" "$resume_output"; do
    assert_contains "$output" "--cap-drop=ALL"
    assert_contains "$output" "--security-opt=no-new-privileges"
    assert_contains "$output" "--security-opt apparmor=codex-universal"
    assert_contains "$output" "--security-opt seccomp=$ROOT/security/seccomp/codex-bwrap.json"
    assert_contains "$output" "--user $(id -u):$(id -g)"
    assert_contains "$output" "--sandbox workspace-write"
    assert_contains "$output" "--ask-for-approval on-request"
    assert_contains "$output" 'approvals_reviewer="user"'
    assert_contains "$output" "sandbox_workspace_write.network_access=false"
    assert_contains "$output" "example/codex-universal-generic:test-version"
done
assert_contains "$resume_output" "resume --last"

idea_output="$("${launcher_env[@]}" "$ROOT/bin/run-codex" --idea smoke-project)"
assert_contains "$idea_output" "--entrypoint codex-acp-entrypoint"
assert_contains "$idea_output" "INITIAL_AGENT_MODE=read-only"
assert_contains "$idea_output" 'CODEX_PATH=/usr/local/share/npm-global/bin/codex'
assert_contains "$idea_output" 'approval_policy":"on-request"'
assert_contains "$idea_output" "--name codex-smoke-project-idea-"
assert_contains "$idea_output" "$TEST_ROOT/repo:$TEST_ROOT/repo"
assert_contains "$idea_output" "--cidfile"
assert_contains "$idea_output" "--label codex-universal.mode=idea"
assert_contains "$idea_output" "--label codex-universal.project=smoke-project"
if [[ "$idea_output" == *"-it"* ]]; then
    fail "IDEA launcher allocated a TTY and would corrupt ACP stdio"
fi

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
    "CODEX_SECCOMP_PROFILE=$ROOT/security/seccomp/codex-bwrap.json" \
    "CODEX_TEST_CLEANUP_CID=$cleanup_cid" \
    "CODEX_TEST_CLEANUP_LOG=$cleanup_log" \
    "PATH=$TEST_ROOT/cleanup-bin:$PATH" \
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

# Verify that the build helper propagates the invoking user rather than using
# root. A root invocation must fail before reaching Docker.
if ((EUID == 0 || $(id -g) == 0)); then
    if "${launcher_env[@]}" "$ROOT/docker-build.sh" generic >/dev/null 2>&1; then
        fail "build helper accepted UID/GID 0"
    fi
else
    build_output="$(
        "${launcher_env[@]}" \
            IMAGE_SLUG=codex-host-smoke \
            IMAGE_VERSION=test-version \
            TAG_LATEST=1 \
            PULL=0 \
            "$ROOT/docker-build.sh" generic
    )"
    assert_contains "$build_output" "--build-arg UID=$(id -u)"
    assert_contains "$build_output" "--build-arg GID=$(id -g)"
    assert_contains "$build_output" "--build-arg CODEX_ACP_VERSION=latest"
    assert_contains "$build_output" "--build-arg IMAGE_VERSION=test-version"
    assert_contains "$build_output" "-t codex-host-smoke-generic:test-version"
    assert_contains "$build_output" "-t codex-host-smoke-generic:latest"
fi
pass "non-root image build policy"

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

if ((EUID != 0 && $(id -g) != 0)); then
    no_origin_output="$(
        "${launcher_env[@]}" \
            TAG_LATEST=0 \
            PULL=0 \
            "$TEST_ROOT/no-origin/docker-build.sh" generic
    )"
    assert_contains "$no_origin_output" "leafclick/codex-universal-generic:dev-"
    assert_contains "$no_origin_output" "--build-arg IMAGE_SOURCE="
fi
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
    local docker_args=(
        run
        --rm
        --pull=never
        --network none
        --cap-drop=ALL
        --security-opt=no-new-privileges
        --security-opt apparmor=codex-universal
        --security-opt "seccomp=$ROOT/security/seccomp/codex-bwrap.json"
    )

    if [[ "$profile" == cuda ]]; then
        docker_args+=(
            --gpus all
            --entrypoint /opt/nvidia/nvidia_entrypoint.sh
        )
    else
        docker_args+=(--entrypoint /bin/bash)
    fi

    docker_args+=("$image")
    if [[ "$profile" == cuda ]]; then
        docker_args+=(/bin/bash)
    fi

    docker "${docker_args[@]}" -c '
        set -Eeuo pipefail
        (( $(id -u) > 0 ))
        (( $(id -g) > 0 ))
        command -v bubblewrap >/dev/null
        command -v codex >/dev/null
        command -v codex-acp >/dev/null
        command -v codex-acp-entrypoint >/dev/null
        command -v zstd >/dev/null
        test -r /etc/codex/requirements.toml
        bwrap \
            --unshare-user \
            --unshare-net \
            --ro-bind / / \
            /bin/true
        codex --version
        codex \
            --sandbox workspace-write \
            --ask-for-approval on-request \
            -c '\''approvals_reviewer="user"'\'' \
            --help >/dev/null
        if [[ "$1" == cuda ]]; then
            command -v nvcc >/dev/null
            command -v nvidia-smi >/dev/null
            test -f /usr/local/cuda/include/cuda.h
            test -f /usr/local/cuda/include/cuda_runtime.h
            nvcc --version
            nvidia-smi >/dev/null
        fi
    ' host-smoke "$profile"
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
