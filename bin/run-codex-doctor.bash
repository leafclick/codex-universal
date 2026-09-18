# shellcheck shell=bash
# Sourced by run-codex. The launcher supplies configuration, project-resolution,
# image-selection, and shared sandbox-probe functions.

DOCTOR_FAILURES=0
DOCTOR_WARNINGS=0

doctor_pass() {
    printf 'PASS  %s\n' "$*"
}

doctor_warn() {
    printf 'WARN  %s\n' "$*"
    ((DOCTOR_WARNINGS += 1))
}

doctor_fail() {
    printf 'FAIL  %s\n' "$*"
    ((DOCTOR_FAILURES += 1))
}

doctor_skip() {
    printf 'SKIP  %s\n' "$*"
}

doctor_note() {
    printf '      %s\n' "$*"
}

doctor_runtime_probe() {
    local image="$1"
    local profile="$2"
    local docker_args=(
        run
        --rm
        --pull=never
        --network none
        --cap-drop=ALL
        --security-opt=no-new-privileges
    )
    if [[ "$CODEX_HOST_BACKEND" == gnu-linux ]]; then
        docker_args+=(--security-opt "apparmor=$APPARMOR_PROFILE")
    fi
    docker_args+=(--security-opt "seccomp=$SECCOMP_PROFILE")
    docker_args+=(
        --read-only
        --tmpfs "$HOME_TMPFS_SPEC"
        --tmpfs "$TMP_TMPFS_SPEC"
        --tmpfs "$DOCTOR_WORKSPACE_TMPFS_SPEC"
        --user "$HOST_UID:$HOST_GID"
        -e "HOME=$CONTAINER_HOME"
        -e "CODEX_UNIVERSAL_WORKFLOW=1"
        --entrypoint /usr/local/bin/codex-entrypoint
    )

    if [[ "$profile" == cuda ]]; then
        docker_args+=(--gpus all)
    fi

    docker_args+=("$image")

    # Writable runtime data is confined to disposable tmpfs mounts. There are
    # no host mounts, so the project and persistent Codex state stay untouched.
    docker "${docker_args[@]}" /bin/bash -c '
        set -Eeuo pipefail

        [[ "$(id -u)" == "$1" ]]
        [[ "$(id -g)" == "$2" ]]
        [[ "$(id -un)" == codex ]]
        [[ "$(id -gn)" == codex ]]
        [[ -z "${LD_PRELOAD:-}" ]]
        [[ -z "${NSS_WRAPPER_PASSWD:-}" ]]
        [[ -z "${NSS_WRAPPER_GROUP:-}" ]]
        passwd_entry="$(getent passwd "$1")"
        group_entry="$(getent group "$2")"
        [[ "$passwd_entry" == "codex:x:$1:$2:"*":$HOME:/bin/bash" ]]
        [[ "$group_entry" == "codex:x:$2:" ]]
        [[ "$(getent passwd codex)" == "$passwd_entry" ]]
        [[ "$(getent group codex)" == "$group_entry" ]]
        grep -Eq "^passwd:[[:space:]]+codex([[:space:]]|$)" /etc/nsswitch.conf
        grep -Eq "^group:[[:space:]]+codex([[:space:]]|$)" /etc/nsswitch.conf
        nss_module="$(find /usr/lib -name libnss_codex.so.2 -print -quit)"
        [[ -n "$nss_module" ]]
        [[ "$(stat -c %u:%g:%a "$nss_module")" == 0:0:644 ]]
        printf "#!/bin/sh\nexit 0\n" > "$HOME/.codex-runtime-write-probe"
        chmod 0700 "$HOME/.codex-runtime-write-probe"
        "$HOME/.codex-runtime-write-probe"
        rm "$HOME/.codex-runtime-write-probe"
        touch /tmp/codex-runtime-write-probe
        rm /tmp/codex-runtime-write-probe
        printf "#!/bin/sh\nexit 0\n" > /tmp/codex-runtime-exec-probe
        chmod 0700 /tmp/codex-runtime-exec-probe
        /tmp/codex-runtime-exec-probe
        rm /tmp/codex-runtime-exec-probe
        if touch /usr/local/bin/.codex-runtime-write-probe 2>/dev/null; then
            exit 1
        fi
        test -r /etc/codex/requirements.toml
        [[ "$(stat -c %a /etc/codex)" == 755 ]]
        [[ "$(stat -c %u /usr/local/bin/codex-entrypoint)" == 0 ]]
        grep -Fxq '\''allowed_approval_policies = ["on-request"]'\'' \
            /etc/codex/requirements.toml
        grep -Fxq '\''allowed_approvals_reviewers = ["user"]'\'' \
            /etc/codex/requirements.toml
        grep -Fxq '\''allowed_sandbox_modes = ["read-only", "workspace-write"]'\'' \
            /etc/codex/requirements.toml
        command -v codex-acp >/dev/null
        command -v codex-acp-entrypoint >/dev/null
        command -v codex-universal-workflow-install >/dev/null
        test -f /usr/local/share/codex-universal/workflow/agents/code_reader.toml
        test -f /usr/local/share/codex-universal/workflow/agents/clojure_probe.toml
        test -f /usr/local/share/codex-universal/workflow/agents/mechanical_worker.toml
        test -x /usr/local/share/codex-universal/workflow/skills/clojure-development/scripts/clojure-development
        test -f "$HOME/.codex/agents/code_reader.toml"
        test -f "$HOME/.codex/agents/clojure_probe.toml"
        test -f "$HOME/.codex/agents/mechanical_worker.toml"
        test -f "$HOME/.codex/skills/clojure-development/SKILL.md"

        printf '\''codex: '\''
        codex --version
        printf '\''agent-lsp: '\''
        agent-lsp --version
        printf '\''bb: '\''
        bb --version
        printf '\''cljfmt: '\''
        cljfmt --version
        printf '\''clj-kondo: '\''
        clj-kondo --version
        printf '\''clojure-lsp: '\''
        clojure-lsp --version
        printf '\''rlwrap: '\''
        rlwrap --version
        printf '\''bundled workflow: code_reader, clojure_probe, mechanical_worker, clojure-development\n'\''
        command -v clj >/dev/null

        if [[ "$3" == cuda ]]; then
            [[ "${CODEX_NVIDIA_ENTRYPOINT_RAN:-}" == 1 ]]
            command -v nvcc >/dev/null
            command -v nvidia-smi >/dev/null
            bwrap \
                --unshare-user \
                --ro-bind / / \
                --dev /dev \
                --proc /proc \
                --tmpfs /tmp \
                -- \
                /bin/bash -c "nvidia-smi >/dev/null"
            nvidia-smi >/dev/null
        fi
    ' run-codex-doctor "$HOST_UID" "$HOST_GID" "$profile"
}

doctor_mcp_probe() {
    local image="$1"
    local required_tools="$2"
    local docker_args=(
        run
        --rm
        --pull=never
        --network none
        --cap-drop=ALL
        --security-opt=no-new-privileges
    )
    if [[ "$CODEX_HOST_BACKEND" == gnu-linux ]]; then
        docker_args+=(--security-opt "apparmor=$APPARMOR_PROFILE")
    fi
    docker_args+=(--security-opt "seccomp=$SECCOMP_PROFILE")
    docker_args+=(
        --read-only
        --tmpfs "$HOME_TMPFS_SPEC"
        --tmpfs "$TMP_TMPFS_SPEC"
        --tmpfs "$DOCTOR_WORKSPACE_TMPFS_SPEC"
        --user "$HOST_UID:$HOST_GID"
        -e "HOME=$CONTAINER_HOME"
        --entrypoint /usr/local/bin/codex-entrypoint
        "$image"
    )

    # Keep this separate from the tool/policy probe so a failed MCP startup or
    # semantic query has a precise diagnosis. Like the runtime probe, it has no
    # host mounts.
    docker "${docker_args[@]}" /bin/bash -c '
            set -Eeuo pipefail

            fixture_dir=/workspace/clojure-lsp-doctor
            bridge_stderr="$HOME/clojure-lsp-doctor.stderr"
            mkdir -p "$fixture_dir/src/doctor_fixture"
            printf "%s\n" \
                "{:paths [\"src\"]}" \
                > "$fixture_dir/deps.edn"
            printf "%s\n" \
                "(ns doctor-fixture.core)" \
                "" \
                "(defn health-check [value]" \
                "  (str \"healthy:\" value))" \
                > "$fixture_dir/src/doctor_fixture/core.clj"
            cd "$fixture_dir"
            coproc MCP_BRIDGE {
                exec codex-clojure-lsp-mcp clojure:clojure-lsp
            } 2>"$bridge_stderr"
            mcp_pid="$MCP_BRIDGE_PID"
            mcp_input_fd="${MCP_BRIDGE[1]}"
            mcp_output_fd="${MCP_BRIDGE[0]}"
            mcp_ready=0

            cleanup_mcp_bridge() {
                kill "$mcp_pid" 2>/dev/null || true
                wait "$mcp_pid" 2>/dev/null || true
            }
            fail_mcp_probe() {
                tail -n 40 -- "$bridge_stderr" >&2 || true
                exit 1
            }
            trap cleanup_mcp_bridge EXIT

            printf '\''%s\n'\'' \
                '\''{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"run-codex-doctor","version":"1"}}}'\'' \
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

            ((mcp_ready == 1)) || fail_mcp_probe

            printf '\''%s\n'\'' \
                '\''{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'\'' \
                >&"$mcp_input_fd"
            printf '\''%s\n'\'' \
                '\''{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'\'' \
                >&"$mcp_input_fd"

            tools_response=""
            for _ in {1..10}; do
                if IFS= read -r -t 1 -u "$mcp_output_fd" mcp_line &&
                   jq -e '\''.id == 2'\'' <<<"$mcp_line" >/dev/null 2>&1; then
                    tools_response="$mcp_line"
                    break
                fi
            done

            [[ -n "$tools_response" ]] || fail_mcp_probe
            jq -e --argjson required "$1" \
                '\''($required - [.result.tools[].name]) | length == 0'\'' \
                <<<"$tools_response" >/dev/null || fail_mcp_probe

            printf '\''{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"start_lsp","arguments":{"root_dir":"%s","language_id":"clojure","ready_timeout_seconds":30}}}\n'\'' \
                "$fixture_dir" >&"$mcp_input_fd"
            start_response=""
            for _ in {1..45}; do
                if IFS= read -r -t 1 -u "$mcp_output_fd" mcp_line &&
                   jq -e '\''.id == 3'\'' <<<"$mcp_line" >/dev/null 2>&1; then
                    start_response="$mcp_line"
                    break
                fi
            done
            if ! jq -e \
                '\''.result.isError != true and
                   ([.result.content[]?.text] | join("\\n") |
                    contains("LSP server started successfully"))'\'' \
                <<<"$start_response" >/dev/null; then
                fail_mcp_probe
            fi

            printf '\''{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"inspect_symbol","arguments":{"file_path":"%s/src/doctor_fixture/core.clj","line":3,"column":7,"language_id":"clojure"}}}\n'\'' \
                "$fixture_dir" >&"$mcp_input_fd"
            semantic_response=""
            for _ in {1..30}; do
                if IFS= read -r -t 1 -u "$mcp_output_fd" mcp_line &&
                   jq -e '\''.id == 4'\'' <<<"$mcp_line" >/dev/null 2>&1; then
                    semantic_response="$mcp_line"
                    break
                fi
            done
            if ! jq -e \
                '\''.result.isError != true and
                   ([.result.content[]?.text] | join("\\n") | length > 0)'\'' \
                <<<"$semantic_response" >/dev/null; then
                fail_mcp_probe
            fi

            cleanup_mcp_bridge
            trap - EXIT
        ' run-codex-doctor "$required_tools"
}

run_doctor() {
    local requested_project="${1:-}"
    local missing=()
    local command compatibility_error

    echo "Codex environment doctor"
    echo

    # Preserve the complete missing-command diagnostic even when the fixture
    # (or a damaged host PATH) cannot identify its kernel at all.
    if [[ -z "$CODEX_HOST_BACKEND" ]]; then
        CODEX_HOST_BACKEND=gnu-linux
    fi

    local required_commands=(git docker)
    if [[ "$CODEX_HOST_BACKEND" == gnu-linux ]]; then
        required_commands=(git realpath docker flock)
    fi
    for command in "${required_commands[@]}"; do
        if ! command -v "$command" >/dev/null 2>&1; then
            missing+=("$command")
        fi
    done

    if ((${#missing[@]})); then
        doctor_fail "Missing required host commands: ${missing[*]}"
        doctor_note "Install the listed commands, then rerun the doctor."
        echo
        printf 'Diagnostics failed: %d failure(s), %d warning(s).\n' \
            "$DOCTOR_FAILURES" "$DOCTOR_WARNINGS"
        return 1
    fi
    doctor_pass "Required host commands are available"

    if [[ "$CODEX_HOST_BACKEND" == gnu-linux ]]; then
        if ! compatibility_error="$(
            codex_host_require_linux_security 2>&1
        )"; then
            doctor_fail "Hardened launcher host check failed"
            doctor_note "${compatibility_error#ERROR: }"
            echo
            printf 'Diagnostics failed: %d failure(s), %d warning(s).\n' \
                "$DOCTOR_FAILURES" "$DOCTOR_WARNINGS"
            return 1
        fi
    fi

    if ! compatibility_error="$(
        codex_host_require_capabilities path lock 2>&1
    )"; then
        doctor_fail "Host utility compatibility check failed"
        doctor_note "${compatibility_error#ERROR: }"
        echo
        printf 'Diagnostics failed: %d failure(s), %d warning(s).\n' \
            "$DOCTOR_FAILURES" "$DOCTOR_WARNINGS"
        return 1
    fi
    if [[ "$CODEX_HOST_BACKEND" == gnu-linux ]]; then
        doctor_pass "GNU/Linux host utility compatibility is available"
    else
        doctor_pass "macOS GNU host utility compatibility is available"
    fi

    if ((HOST_UID == 0 || HOST_GID == 0)); then
        doctor_fail "Host UID/GID must both be non-root ($HOST_UID:$HOST_GID)"
        doctor_note "Run Codex as a regular Docker user."
        echo
        printf 'Diagnostics failed: %d failure(s), %d warning(s).\n' \
            "$DOCTOR_FAILURES" "$DOCTOR_WARNINGS"
        return 1
    fi
    doctor_pass "Host runtime identity is non-root ($HOST_UID:$HOST_GID)"

    if ! docker info >/dev/null 2>&1; then
        doctor_fail "Docker daemon is not available"
        doctor_note "Start Docker Engine and confirm this user can run 'docker info'."
        echo
        printf 'Diagnostics failed: %d failure(s), %d warning(s).\n' \
            "$DOCTOR_FAILURES" "$DOCTOR_WARNINGS"
        return 1
    fi
    doctor_pass "Docker daemon is available"

    resolve_project "$requested_project"
    PROJECT="$RESOLVED_NAME"
    PROJECT_PATH="$RESOLVED_PATH"
    PROFILE="$RESOLVED_PROFILE"
    IMAGE="$(profile_image "$PROFILE")"
    doctor_pass "Project '$PROJECT' resolves to $PROJECT_PATH ($PROFILE)"
    if [[ "$CODEX_HOST_BACKEND" == darwin-gnu && "$PROFILE" != generic ]]; then
        doctor_fail "The macOS backend supports only the generic profile"
        doctor_note "CUDA requires a GNU/Linux host; select the generic profile for Docker Desktop."
    fi
    resolve_clojure_mcp "$PROJECT_PATH" "$RESOLVED_CLOJURE_MCP"
    if [[ "$EFFECTIVE_CLOJURE_LSP_MCP" == 1 ]]; then
        doctor_pass "Clojure LSP MCP selected ($EFFECTIVE_CLOJURE_LSP_MCP_REASON)"
    else
        doctor_skip "Clojure LSP MCP not selected ($EFFECTIVE_CLOJURE_LSP_MCP_REASON)"
    fi

    if [[ "$CODEX_HOST_BACKEND" == gnu-linux ]]; then
        if [[ "$APPARMOR_PROFILE" != codex-universal ]]; then
            doctor_fail "Unsupported CODEX_APPARMOR_PROFILE: $APPARMOR_PROFILE (expected codex-universal)"
        fi
    else
        doctor_warn "Docker Desktop does not expose the GNU/Linux AppArmor host-policy contract"
        doctor_note "The container still uses a read-only root, tmpfs runtime storage, dropped capabilities, and no-new-privileges."
    fi
    if [[ ! -f "$SECCOMP_PROFILE" || ! -r "$SECCOMP_PROFILE" ]]; then
        doctor_fail "Host sandbox policy is not readable: $SECCOMP_PROFILE"
        if [[ "$CODEX_HOST_BACKEND" == gnu-linux ]]; then
            doctor_note "Run bin/setup-codex-host-security from the codex-universal checkout."
        else
            doctor_note "Reinstall the codex-universal host tools."
        fi
    else
        SECCOMP_PROFILE="$(codex_host_path_existing "$SECCOMP_PROFILE")"
        doctor_pass "Host sandbox policy is readable"
    fi

    if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
        doctor_fail "Required local image is unavailable: $IMAGE"
        doctor_note "Build it with './docker-build.sh $PROFILE' or select an existing CODEX_IMAGE_TAG."
    else
        local image_id image_user image_version image_revision
        image_id="$(docker image inspect --format '{{.Id}}' "$IMAGE")"
        image_user="$(docker image inspect --format '{{.Config.User}}' "$IMAGE")"
        image_version="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "$IMAGE")"
        image_revision="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$IMAGE")"

        doctor_pass "Local image is available: $IMAGE"
        printf '      image id: %s\n' "${image_id:-unknown}"
        printf '      version:  %s\n' "${image_version:-unknown}"
        printf '      revision: %s\n' "${image_revision:-unknown}"

        if [[ "$image_user" =~ ^[1-9][0-9]*:[1-9][0-9]*$ ]]; then
            doctor_pass "Image declares a fixed non-root user ($image_user)"
        else
            doctor_fail "Image must declare an explicit non-root numeric user: '$image_user'"
            doctor_note "Select a portable codex-universal image with a fixed non-root USER."
        fi

        if ((DOCTOR_FAILURES == 0)); then
            local probe_output=""
            if probe_output="$(run_sandbox_probe "$IMAGE" 2>&1)"; then
                if [[ "$CODEX_HOST_BACKEND" == gnu-linux ]]; then
                    doctor_pass "AppArmor, seccomp, and Bubblewrap sandbox probe"
                else
                    doctor_pass "Docker Desktop seccomp and Bubblewrap sandbox probe"
                fi
            else
                if [[ "$CODEX_HOST_BACKEND" == gnu-linux ]]; then
                    doctor_fail "AppArmor, seccomp, or Bubblewrap sandbox probe failed"
                else
                    doctor_fail "Docker Desktop seccomp or Bubblewrap sandbox probe failed"
                fi
                [[ -z "$probe_output" ]] || printf '      %s\n' "$probe_output"
                doctor_note "Reinstall the host policy, then rerun the doctor."
            fi

            local runtime_output=""
            if runtime_output="$(doctor_runtime_probe "$IMAGE" "$PROFILE" 2>&1)"; then
                doctor_pass "Portable runtime identity, read-only image, tools, and managed Codex policy"
                while IFS= read -r line; do
                    [[ -z "$line" ]] || printf '      %s\n' "$line"
                done <<<"$runtime_output"
            else
                doctor_fail "Portable runtime, image boundary, tools, policy, or CUDA probe failed"
                [[ -z "$runtime_output" ]] || printf '      %s\n' "$runtime_output"
                doctor_note "Rebuild or replace the selected image, then rerun the doctor."
            fi

            if [[ "$EFFECTIVE_CLOJURE_LSP_MCP" == 1 ]]; then
                local mcp_output=""
                if mcp_output="$(doctor_mcp_probe "$IMAGE" "$CLOJURE_LSP_MCP_ALLOWED_TOOLS" 2>&1)"; then
                    doctor_pass "Clojure LSP MCP semantic query and tool allowlist"
                else
                    doctor_fail "Clojure LSP MCP semantic query or tool allowlist failed"
                    [[ -z "$mcp_output" ]] || printf '      %s\n' "$mcp_output"
                    doctor_note "Rebuild or replace the selected image, then rerun the doctor."
                fi
            else
                doctor_skip "Clojure LSP MCP semantic query ($EFFECTIVE_CLOJURE_LSP_MCP_REASON)"
            fi
        else
            doctor_skip "Runtime probes because an earlier required check failed"
        fi
    fi

    if [[ "$CODEX_HOST_BACKEND" == gnu-linux ]]; then
        local optional_missing=()
        for command in jq socat setpriv; do
            if ! command -v "$command" >/dev/null 2>&1; then
                optional_missing+=("$command")
            fi
        done
        if ((${#optional_missing[@]})); then
            doctor_warn "Optional IntelliJ host commands missing: ${optional_missing[*]}"
            doctor_note "Install jq, socat, and util-linux (setpriv) before using IDEA integration."
        else
            doctor_pass "Optional IntelliJ host commands are available"
        fi
    else
        doctor_skip "IntelliJ integration is not supported by the macOS generic backend"
    fi

    echo
    if ((DOCTOR_FAILURES)); then
        printf 'Diagnostics failed: %d failure(s), %d warning(s).\n' \
            "$DOCTOR_FAILURES" "$DOCTOR_WARNINGS"
        return 1
    fi

    printf 'Diagnostics passed with %d warning(s).\n' "$DOCTOR_WARNINGS"
}
