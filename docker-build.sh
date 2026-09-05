#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

TARGET="${1:-all}"
CODEX_VERSION="${CODEX_VERSION:-latest}"
CODEX_ACP_VERSION="${CODEX_ACP_VERSION:-latest}"
IMAGE_SLUG="${IMAGE_SLUG:-${IMAGE_PREFIX:-}}"
IMAGE_VERSION="${IMAGE_VERSION:-${TAG:-}}"
TAG_LATEST="${TAG_LATEST:-1}"
PULL="${PULL:-1}"

GIT_REVISION=""
GIT_SOURCE=""

usage() {
    cat <<EOF2
Usage: $(basename "$0") [generic|cuda|all]

Environment:
  IMAGE_SLUG=SLUG             Image repository slug; defaults from GitHub origin
  IMAGE_VERSION=VERSION       Docker tag; defaults from Git
  TAG_LATEST=1                Also update the local latest alias
  CODEX_VERSION=latest        @openai/codex npm version
  CODEX_ACP_VERSION=latest    @agentclientprotocol/codex-acp npm version
  PULL=1                     Set to 0 to omit docker build --pull

Compatibility:
  IMAGE_PREFIX and TAG remain aliases for IMAGE_SLUG and IMAGE_VERSION.
EOF2
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

docker_tag_slug() {
    local value="${1,,}"

    value="${value//[^a-z0-9_.-]/-}"
    while [[ "$value" == [.-]* ]]; do
        value="${value:1}"
    done
    while [[ "$value" == *[.-] ]]; do
        value="${value::-1}"
    done
    value="${value:0:100}"

    [[ -n "$value" ]] || die "Could not derive a valid Docker tag"
    printf '%s\n' "$value"
}

resolve_git_metadata() {
    command -v git >/dev/null 2>&1 ||
        die "git is required when IMAGE_VERSION is not set"
    git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
        die "IMAGE_VERSION is required outside a Git checkout"

    GIT_REVISION="$(git -C "$SCRIPT_DIR" rev-parse --verify HEAD)"

    # Use explicit defaults at the point of use as well as at script scope.
    # This keeps the metadata path safe under `set -u` in repositories without
    # an origin remote and in callers that deliberately unset these names.
    GIT_SOURCE="${GIT_SOURCE-}"
    GIT_REVISION="${GIT_REVISION-}"

    local remote=""
    remote="$(git -C "$SCRIPT_DIR" config --get remote.origin.url 2>/dev/null || true)"
    case "$remote" in
        git@*:* )
            local remote_path="${remote#git@}"
            remote_path="${remote_path/:/\/}"
            GIT_SOURCE="https://$remote_path"
            ;;
        http://*|https://*)
            GIT_SOURCE="$remote"
            ;;
        *)
            GIT_SOURCE="$remote"
            ;;
    esac
    GIT_SOURCE="${GIT_SOURCE-}"
    GIT_SOURCE="${GIT_SOURCE%.git}"

    if [[ -z "$IMAGE_SLUG" ]]; then
        if [[ "$GIT_SOURCE" == https://github.com/*/* ]]; then
            IMAGE_SLUG="${GIT_SOURCE#https://github.com/}"
            IMAGE_SLUG="${IMAGE_SLUG,,}"
        else
            IMAGE_SLUG="leafclick/codex-universal"
        fi
    fi

    if [[ -z "$IMAGE_VERSION" ]]; then
        local exact_tag branch short_revision
        exact_tag="$(git -C "$SCRIPT_DIR" describe --tags --exact-match HEAD 2>/dev/null || true)"
        short_revision="$(git -C "$SCRIPT_DIR" rev-parse --short=12 HEAD)"

        if [[ -n "$exact_tag" ]]; then
            IMAGE_VERSION="$(docker_tag_slug "$exact_tag")"
        else
            branch="$(git -C "$SCRIPT_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || echo detached)"
            IMAGE_VERSION="dev-$(docker_tag_slug "$branch")-$short_revision"
        fi

        if [[ -n "$(git -C "$SCRIPT_DIR" status --porcelain --untracked-files=normal)" ]]; then
            IMAGE_VERSION="${IMAGE_VERSION}-dirty"
        fi
    fi
}

case "$TARGET" in
    generic|cuda|all) ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

case "$TAG_LATEST" in
    0|1) ;;
    *) die "TAG_LATEST must be 0 or 1" ;;
esac

resolve_git_metadata

[[ "$IMAGE_VERSION" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] ||
    die "Invalid Docker IMAGE_VERSION: $IMAGE_VERSION"

HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

if [[ "$HOST_UID" == 0 || "$HOST_GID" == 0 ]]; then
    echo "ERROR: Refusing to build a Codex image for UID/GID 0." >&2
    echo "Run this script as the non-root user who will run Codex." >&2
    exit 1
fi

command -v docker >/dev/null 2>&1 || die "docker is not installed"

docker info >/dev/null 2>&1 || die "Docker daemon is not available"

build_one() {
    local profile="$1"
    local dockerfile="$SCRIPT_DIR/Dockerfile.$profile"
    local repository="${IMAGE_SLUG}-${profile}"
    local image="${repository}:${IMAGE_VERSION}"

    [[ -f "$dockerfile" ]] || {
        echo "ERROR: Missing $dockerfile" >&2
        exit 1
    }

    local args=(
        build
        -f "$dockerfile"
        --build-arg "UID=$HOST_UID"
        --build-arg "GID=$HOST_GID"
        --build-arg "CODEX_VERSION=$CODEX_VERSION"
        --build-arg "CODEX_ACP_VERSION=$CODEX_ACP_VERSION"
        --build-arg "IMAGE_VERSION=$IMAGE_VERSION"
        --build-arg "VCS_REF=${GIT_REVISION-}"
        --build-arg "IMAGE_SOURCE=${GIT_SOURCE-}"
        -t "$image"
    )

    if [[ "$TAG_LATEST" == 1 && "$IMAGE_VERSION" != latest ]]; then
        args+=(-t "${repository}:latest")
    fi

    if [[ "$PULL" != 0 ]]; then
        args+=(--pull)
    fi

    args+=("$SCRIPT_DIR")

    echo "==> Building $image"
    if [[ "$TAG_LATEST" == 1 && "$IMAGE_VERSION" != latest ]]; then
        echo "    alias: ${repository}:latest"
    fi
    docker "${args[@]}"
    echo
}

case "$TARGET" in
    generic)
        build_one generic
        ;;
    cuda)
        build_one cuda
        ;;
    all)
        build_one generic
        build_one cuda
        ;;
esac
