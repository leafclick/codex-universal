#!/usr/bin/env bash
set -Eeuo pipefail

check_phase="${1:-}"
shift || true
(($# == 4)) || {
    printf "host-smoke: image phase %s requires profile, UID, GID, and image arguments\n" \
        "${check_phase:-<missing>}" >&2
    exit 2
}
trap '
    status=$?
    failed_command=$BASH_COMMAND
    failed_line=$LINENO
    printf "host-smoke: %s container image %s failed during %s at line %s: %s (exit %s)\n" \
        "$1" "$4" "$check_phase" "$failed_line" "$failed_command" "$status" >&2
    exit "$status"
' ERR

case "$check_phase" in
    identity)
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
        ;;
    filesystem-policy)
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
            printf "host-smoke: %s container image %s has a writable image root\n" \
                "$1" "$4" >&2
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
        ;;
    toolchain-availability)
        command -v bwrap >/dev/null
        command -v python3 >/dev/null
        command -v codex >/dev/null
        command -v node >/dev/null
        command -v java >/dev/null
        command -v codex-acp >/dev/null
        command -v codex-acp-entrypoint >/dev/null
        command -v agent-lsp >/dev/null
        [[ "$(agent-lsp --version)" == 0.19.2 ]]
        command -v codex-clojure-lsp-mcp >/dev/null
        command -v codex-lsp-message-proxy >/dev/null
        command -v codex-no-nested-userns >/dev/null
        command -v lsof >/dev/null
        command -v setsid >/dev/null
        command -v timeout >/dev/null
        command -v bb >/dev/null
        command -v clj >/dev/null
        command -v deps >/dev/null
        command -v lein >/dev/null
        command -v cljfmt >/dev/null
        command -v clj-kondo >/dev/null
        command -v clojure-lsp >/dev/null
        command -v rlwrap >/dev/null
        command -v socat >/dev/null
        command -v zstd >/dev/null
        ;;
    clojure-runtime)
        /bin/bash /opt/codex-universal/tests/fixtures/host-smoke-clojure-runtime.sh \
            /opt/codex-universal \
            /usr/local/share/codex-universal/workflow/skills/clojure-development
        [[ "$LEIN_JAR" == /opt/clojure/leiningen-standalone.jar ]]
        [[ -r "$LEIN_JAR" ]]
        [[ "$DEPS_CLJ_TOOLS_DIR" == /usr/local/lib/clojure ]]
        clojure -Sdescribe
        deps -Sdescribe
        lein version
        node --version
        java --version
        rlwrap --version
        test -r /etc/codex/requirements.toml
        [[ "$(stat -c %a /etc/codex)" == 755 ]]
        [[ "$(stat -c %u /usr/local/bin/codex-entrypoint)" == 0 ]]
        [[ "$(stat -c %u /usr/local/share/npm-global/bin/codex)" == 0 ]]
        [[ "$(stat -c %u /etc/codex/requirements.toml)" == 0 ]]
        [[ "$(awk '$1 == "CapEff:" {print $2}' /proc/self/status)" == 0000000000000000 ]]
        [[ "$(awk '$1 == "NoNewPrivs:" {print $2}' /proc/self/status)" == 1 ]]
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
        ;;
    bubblewrap)
        bwrap \
            --unshare-user \
            --unshare-net \
            --ro-bind / / \
            --dev /dev \
            --proc /proc \
            --tmpfs /tmp \
            -- \
            /bin/bash -c '
                set -Eeuo pipefail
                [[ "$(id -un)" == codex && "$(id -gn)" == codex ]]
                [[ -z "${LD_PRELOAD:-}" ]]
                [[ -z "${NSS_WRAPPER_PASSWD:-}" ]]
                [[ -z "${NSS_WRAPPER_GROUP:-}" ]]
                printf "#!/bin/sh\nexit 0\n" > /tmp/sandbox-tmp-is-executable
                chmod 0700 /tmp/sandbox-tmp-is-executable
                /tmp/sandbox-tmp-is-executable
            '
        ;;
    clojure-lsp-runtime)
        codex-clojure-lsp-mcp --check-clojure-lsp >/dev/null
        ;;
    clojure-lsp)
        fixture_source=/opt/codex-universal/tests/fixtures/clojure-lsp-project
        fixture_dir="$HOME/clojure-lsp-smoke"
        mcp_stderr="$fixture_dir/mcp-stderr.log"
        [[ -f "$fixture_source/deps.edn" ]]
        [[ -f "$fixture_source/src/lsp_fixture/core.clj" ]]
        [[ -f "$fixture_source/test/lsp_fixture/core_test.clj" ]]
        mkdir -p "$fixture_dir"
        cp -R -- "$fixture_source/." "$fixture_dir/"
        python3 /opt/codex-universal/tests/fixtures/check-clojure-lsp-mcp.py \
            "$fixture_dir" "$mcp_stderr"
        ;;
    cli-smoke)
        codex-clojure-lsp-mcp --check-java >/dev/null
        codex --version
        bb --version
        cljfmt --version
        clj-kondo --version
        clojure-lsp --version
        codex \
            --sandbox workspace-write \
            --ask-for-approval on-request \
            -c 'approvals_reviewer="user"' \
            --help >/dev/null
        ;;
    cuda-runtime)
        if [[ "$1" == cuda ]]; then
            # The CUDA wrapper (installed as /usr/bin/bwrap) must re-expose the
            # NVIDIA device nodes AFTER Codex's own `--dev /dev`. bwrap applies
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
                    /bin/bash -c '
                        set -Eeuo pipefail
                        test -e /dev/nvidiactl
                        test -e /dev/nvidia0 || ls /dev/nvidia[0-9]* >/dev/null
                    '
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
        ;;
    *)
        printf "host-smoke: unknown image test phase: %s\n" "$check_phase" >&2
        exit 2
        ;;
esac
