# codex-universal

## Overview

`codex-universal` runs OpenAI Codex against one local Git project in a
non-root Docker development environment. The checkout remains in its normal
host location for editors, while Docker restricts the host files visible to
Codex. Codex runs with `workspace-write`, human approval for escalation, and
no full-access mode.

Both the generic Ubuntu and NVIDIA CUDA images include Codex, Java, Node.js,
Clojure CLI, Leiningen, Git, and common build tools. Clojure projects also get
native `bb`, `cljfmt`, `clj-kondo`, and `clojure-lsp`, plus a persistent local
LSP-to-MCP bridge in terminal mode. Optional IntelliJ IDEA integration runs the
same containerized Codex in JetBrains AI Chat and exposes a read-only view of
the IDE's semantic tools.

## One command, one project, full toolchain

One launcher gives Codex a ready-to-use toolchain, persistent sessions and
caches, semantic Clojure navigation, and only the project you selected—without
moving the checkout away from your editor.

```text
$ cd ~/src/my-project
$ run-codex
  project: /home/alice/src/my-project -> /workspace/my-project
  policy:  workspace-write; Git metadata and network writes need your approval

> Use the Clojure LSP tools to find this symbol's callers, fix the bug,
  and run the focused test.
```

Use the generic image for everyday development or the CUDA image when Codex
needs the host GPU. Use it in a terminal, or add the optional IDEA agent when
editor-aware navigation is useful.

## Install

This is the shortest supported setup. Follow the linked detailed sections if a
step fails or needs customization.

1. Install Docker Engine, Bash, Git, AppArmor, `jq`, and `socat`. See
   [host requirements](#host-requirements); CUDA users must also complete
   [CUDA host setup](#cuda-host-setup).

   ```bash
   sudo apt install apparmor apparmor-utils jq socat
   ```

2. Clone the repository and build one image. Substitute `cuda` for `generic`
   when GPU access is required. See [building](#building) for tags and other
   options.

   ```bash
   git clone https://github.com/leafclick/codex-universal.git
   cd codex-universal
   ./docker-build.sh generic
   ```

3. Install the host sandbox policy and launcher commands. Ensure
   `~/.local/bin` is in `PATH`. See [installing commands](#installing-commands)
   for alternatives.

   ```bash
   bin/setup-codex-host-security
   mkdir -p ~/.local/bin
   install -m 755 bin/run-codex bin/setup-codex-idea ~/.local/bin/
   install -m 700 bin/codex-push bin/codex-pull ~/.local/bin/
   ```

4. Register a Git checkout and start Codex. On a machine without existing Codex
   state, follow [First login on a new installation](#first-login-on-a-new-installation)
   to enable device authorization and persist the resulting credentials.

   ```bash
   cd ~/src/my-project
   run-codex --init
   run-codex --new
   ```

5. Optional: after terminal mode works, follow
   [IntelliJ IDEA integration](#intellij-idea-integration) to add the same
   registered project as a Dockerized Codex agent in JetBrains AI Chat.

Continue directly with verification before relying on the installation.

## Verify the installation

First run the environment doctor for the registered project:

```bash
run-codex --doctor my-project
```

The doctor is local-only and does not pull or build images, access the network,
invoke `sudo`, mount the project into its diagnostic container, or modify
persistent Codex state. It reports the registered project and profile, local
image identity, host UID/GID match, sandbox operation, installed tool versions,
and the Clojure LSP MCP initialize handshake. A CUDA project additionally
checks GPU access. Optional integrations are reported as warnings or skips.

Then exit Codex and run the host smoke suite from the `codex-universal`
checkout. This short form skips optional state-synchronization tests but still
checks the launcher, policy, Bubblewrap, installed tools, and any locally
available generic or CUDA image:

```bash
cd /path/to/codex-universal
CODEX_TEST_SKIP_SYNC=1 ./tests/host-smoke.sh
```

A successful run ends with `All host smoke tests passed.` See
[testing on the host](#testing-on-the-host) for the complete suite, image
selection, CUDA-only checks, and troubleshooting.

Next start a new Codex chat and paste the prompt for that client mode. Terminal
and IDEA sessions use intentionally different MCP servers and paths:

| Client mode | MCP server | Expected project path |
| --- | --- | --- |
| `run-codex` | Container-local `clojure_lsp` | Container path, normally `/workspace/<project>` |
| `run-codex --idea` | Host IDEA `idea` through a private relay | Exact absolute host checkout path |

Test the modes in separate chats. In either mode, `pwd` is authoritative; do
not translate paths or move a conversation between the two path forms. The
official [Codex MCP documentation](https://developers.openai.com/codex/mcp/)
documents `/mcp` for viewing active servers in the terminal UI, but a
successful tool call is the definitive connection check.

### Terminal Clojure LSP prompt

Paste this into a terminal-mode Dockerized Codex chat opened on a Clojure
repository:

```text
Perform a read-only connection and path test of the container-local Clojure
LSP MCP server. Do not modify files, use the network, request escalation, or
invoke formatting, rename, refactoring, edit, build, or test tools.

1. Run `pwd -P` and `git status --short` through the container shell. Record
   both exact outputs as the baseline. Use this container path, normally below
   `/workspace`, as the only project root; do not substitute a host path.
2. Use `rg --files -g '*.clj' -g '*.cljc' -g '*.cljs'` only to select one
   existing source file and resolve its absolute path below `pwd`. If none
   exists, report SKIP for the semantic portion.
3. Use only read-only `mcp__clojure_lsp__*` tools to detect the Clojure server,
   list symbols in that file with `language_id="clojure"`, request diagnostics,
   and perform one definition, documentation, or reference query for a symbol
   the server returned. If initialization is required, call `start_lsp` once
   with `root_dir` exactly equal to `pwd`; never initialize another root.
4. Confirm every returned absolute path or `file://` URI remains below the
   exact container `pwd`. These tools do not take IDEA's `projectPath` and must
   not introduce a second path.
5. Run `git status --short` again and compare it byte-for-byte with the
   baseline.

Report every MCP tool called, its root or file path, what it established, and
PASS, FAIL, or SKIP. Pass only if `clojure_lsp` returned semantic project data,
all paths used the container root, no write-capable tool was invoked, and Git
status was unchanged.
```

### IntelliJ IDEA MCP prompt

After completing the optional IDEA setup, paste this into a new Dockerized
Codex ACP chat:

```text
Perform a read-only connection and path test of the IntelliJ MCP server. Do
not modify files, use the network, request escalation, or invoke any
write-capable tool.

1. Run `pwd -P` and `git status --short` through the container shell. Record
   the exact host-style project path and Git-status output as the baseline.
2. For all project inspection, use `mcp__idea__` tools instead of `rg`, `grep`,
   `sed`, `find`, or `cat`: list the project root, read `AGENTS.md` or
   `README.md`, and search for text observed in that file.
3. If the project contains a supported source file, resolve one symbol,
   request its symbol information, and request diagnostics for its file.
4. Pass the exact path returned by `pwd` as `projectPath` in every IDEA call.
   Do not translate it to `/workspace/...` or follow a second-path alias.
5. Run `git status --short` again and compare it byte-for-byte with the
   baseline.

Report every IDEA MCP tool called, the `projectPath` used, what it established,
and PASS, FAIL, or SKIP. Pass only if IDEA tools returned project data, every
path exactly matched `pwd`, no write-capable tool was invoked, and Git status
was unchanged.
```

Once the applicable prompt passes, installation is complete. You can then run
the optional [manual approval-boundary check](#manual-approval-boundary-check),
configure [Clojure interactive development](docs/clojure-agents.md), enable
[state synchronization](docs/codex-sync.md), or continue with the detailed
reference below.

## Docker images

> **Name and relationship:** OpenAI maintains a separate
> [`openai/codex-universal`](https://github.com/openai/codex-universal)
> reference base image for Codex environments. This project was developed
> independently and is not a fork; it focuses on a non-root runtime,
> restricted host mounts, and enforced approval boundaries.

The image repository slug defaults to the owner/repository path derived from the GitHub `origin`, currently `leafclick/codex-universal`. The profile name is appended to form two image repositories:

```text
leafclick/codex-universal-generic
leafclick/codex-universal-cuda
```

Every build tags its image with a Git-derived version. A clean checkout at an exact Git tag uses that tag. Other commits use `dev-<branch-slug>-<short-commit>`, and a modified checkout adds `-dirty`:

```text
leafclick/codex-universal-generic:v1.2.0
leafclick/codex-universal-generic:dev-main-a1b2c3d4e5f6-dirty
```

By default, the same image is also tagged `latest` as a local convenience alias. The versioned tag is the immutable identity; `latest` is not a separate build and moves whenever a new image is built. Images also carry OCI `version`, `revision`, and `source` labels.

Both contain the same development environment, including:

- OpenAI Codex CLI
- Codex ACP adapter for IDE integration
- Ubuntu 24.04
- Node.js 24
- Eclipse Temurin JDK 25
- Clojure CLI
- Leiningen
- deps.clj
- Git / Git LFS
- common build and development tools

The CUDA variant additionally contains the NVIDIA CUDA development environment.

## Host requirements

Building and running the containers requires:

- Bash
- Docker Engine with an available Docker daemon
- Git
- GNU `grep`
- GNU `coreutils`, including `realpath`
- `util-linux`, including `flock`
- `jq`
- `socat` for the optional IntelliJ MCP relay
- AppArmor and `apparmor_parser`
- `sudo` for the one-time AppArmor policy installation

The CUDA profile additionally requires the NVIDIA driver and NVIDIA Container Toolkit. The optional `codex-push` and `codex-pull` commands require more host utilities; see the [Codex state synchronization guide](docs/codex-sync.md#install-required-software).

The synchronization commands run on the host. Installing a utility such as `zstd` inside the Docker image does not make it available to those host commands.

## Building

Build both images:

```bash
./docker-build.sh all
```

Build only the generic image:

```bash
./docker-build.sh generic
```

Build only CUDA:

```bash
./docker-build.sh cuda
```

### Build options

Override the Git-derived version or disable the moving `latest` alias:

```bash
IMAGE_VERSION=1.0.0 TAG_LATEST=0 ./docker-build.sh all
```

A specific Codex, ACP adapter, or LSP bridge version can be used:

```bash
CODEX_VERSION=latest \
CODEX_ACP_VERSION=latest \
AGENT_LSP_VERSION=latest \
  ./docker-build.sh all
```

`CODEX_ACP_VERSION` selects the `@agentclientprotocol/codex-acp` npm version
used by the optional IntelliJ integration. `AGENT_LSP_VERSION` selects the
`agent-lsp` MCP bridge used for Clojure semantic navigation.

For a release build, set all three package versions explicitly instead of using
`latest`. The Git-derived image tag records the source revision and build
configuration, but builds are not byte-for-byte reproducible: Ubuntu package
repositories and several upstream installer channels are resolved at build
time. Do not overwrite a published version tag, and use the registry digest
when an exact image artifact must be selected.

Stable system, Java, and core Clojure layers precede the native Clojure tools,
versioned Codex/ACP/LSP packages, and copied integration files. Updating an
agent package version or an integration script therefore preserves the costly
Java and core Clojure cache. Git-derived OCI labels are applied after every
filesystem layer, so a new source revision alone updates only image metadata.
Dockerfile changes, copied installers, and updated base images still invalidate
the layers they affect.

A different repository slug can be selected:

```bash
IMAGE_SLUG=ghcr.io/myorg/codex-universal ./docker-build.sh all
```

`IMAGE_PREFIX` and `TAG` remain supported as compatibility aliases for `IMAGE_SLUG` and `IMAGE_VERSION`.

`run-codex` uses the `latest` alias unless told otherwise. To select the immutable tag produced by the build:

```bash
CODEX_IMAGE_SLUG=ghcr.io/myorg/codex-universal \
CODEX_IMAGE_TAG=1.0.0 \
  run-codex my-project
```

The images are built using the host numeric UID and GID so bind-mounted files remain owned by the host user. Run the build helper as that non-root user; it rejects UID or GID 0 rather than creating a root Codex image.

## Clojure command-line tooling

Both image profiles install the latest stable native releases of:

- `bb` (Babashka)
- `cljfmt`
- `clj-kondo`
- `clojure-lsp`

The build uses each project's supported installer, which selects the native
binary for the image architecture. `cljfmt` is the standalone GraalVM native
executable, so `cljfmt check` and `cljfmt fix` do not launch `clj`. Each tool
uses its upstream defaults and still discovers project-local configuration such
as `bb.edn`, `.cljfmt.edn`, `.clj-kondo/config.edn`, and `.lsp/config.edn`.

In terminal mode, `run-codex` enables a container-local `clojure_lsp` MCP
server automatically for Clojure projects. Auto-detection looks for a root
`deps.edn`, `project.clj`, `bb.edn`, `shadow-cljs.edn`, or `build.boot`, then
for tracked or unignored `.clj`, `.cljc`, or `.cljs` source anywhere in the
repository. Other projects start without the MCP server or its tool catalog.

The bridge uses `agent-lsp` to keep `clojure-lsp` indexed and expose a curated
set of symbol navigation, references, diagnostics, formatting, and guarded
refactoring tools to Codex. Unrelated agent-lsp workflow, simulation, cache,
cross-repository, build, and test tools are not exposed. The first semantic
tool call starts analysis for the current project; in the Codex TUI, use `/mcp`
to inspect the connection, as described in the official
[Codex MCP documentation](https://developers.openai.com/codex/mcp/).
For example, ask Codex to “use the Clojure LSP tools to find every reference
to `my.app/foo` and check diagnostics before editing” rather than asking for a
text search.

Use the copyable [terminal Clojure LSP prompt](#terminal-clojure-lsp-prompt)
after installation to verify the local server and its container paths.

The terminal bridge runs in a nested networkless Bubblewrap sandbox with a
private PID namespace and an empty `/proc`. It can update the working tree and
its caches, but `.git` and `.codex` remain read-only; Codex prompts before
invoking MCP tools declared as write-capable. This preserves the same outer
boundary as ordinary Codex commands without exposing other container
processes through procfs. Set a persistent per-project override with:

```bash
run-codex --set-clojure-mcp my-project on
run-codex --set-clojure-mcp my-project off
run-codex --set-clojure-mcp my-project auto
```

The `auto` setting is the default. It is useful for mixed repositories and
also restores detection after an explicit override. For a one-session override,
use `CODEX_CLOJURE_LSP_MCP=on` or `off`; the older `1` and `0` forms remain
supported:

```bash
CODEX_CLOJURE_LSP_MCP=0 run-codex my-project
```

The integration follows the persistent MCP/LSP design described in the
[agent-lsp blog post](https://blog.blackwell-systems.com/posts/agent-lsp/).
`clojure-lsp` also remains directly usable from the terminal; its CLI supports
`diagnostics`, `references`, `rename`, `clean-ns`, `format`, and analysis
`dump` commands. IDEA mode instead receives IntelliJ's integrated MCP server
through a private loopback relay, avoiding a second language-server index and
exposing the IDE's project-aware tools to Codex.

For Clojure repositories using these images, copy and adapt the
[suggested `AGENTS.md` interactive-development section](docs/clojure-agents.md).
Its baseline workflow is editor-independent: Babashka tasks, native LSP and
lint/format tools, a persistent nREPL, watchers, and a fresh JVM for final
verification. IDEA MCP is documented as an optional semantic provider.

## Codex sandboxing inside Docker

`run-codex` starts Codex with the low-friction `Auto` policy:

```toml
sandbox_mode = "workspace-write"
approval_policy = "on-request"
approvals_reviewer = "user"

[sandbox_workspace_write]
network_access = false
writable_roots = ["/home/codex"]
```

The terminal launcher supplies these settings on the Codex command line, while
the IDEA launcher supplies equivalent ACP session defaults. The image also
installs enforced requirements that neither client nor user configuration can
loosen. Routine commands, edits, builds, and tests run without confirmation
inside the mounted project and container home. Network access and writes
outside those boundaries require approval.

Codex keeps `.git` and `.codex` recursively read-only to spawned commands even though their parent directories are writable roots. Consequently, `git commit`, `git add`, branch and tag changes, resets, and **any other command or executable that writes Git repository metadata** cannot succeed in the sandbox. Codex must request elevation, and the launcher pins `approvals_reviewer = "user"`, so that request is shown to you rather than sent to automatic approval review. Working-tree file edits remain prompt-free. The Codex client itself can still update its session state.

The images include `bubblewrap`, which Codex uses for its Linux sandbox.
Nested Bubblewrap requires namespace and mount operations that Docker's
default seccomp and AppArmor policies intentionally block. Install this
project's host policy once from the checkout:

```bash
sudo apt install apparmor apparmor-utils jq socat
bin/setup-codex-host-security
```

The setup is idempotent. It loads a `codex-universal` AppArmor profile and
copies the seccomp profile to
`~/.config/run-codex/security/codex-bwrap.json`. The AppArmor policy retains
Docker's normal restrictions while permitting creation of unprivileged user
namespaces and mounts inside them. The container still has an empty capability
set and `no-new-privileges`, so these permissions cannot mount in the initial
container namespace. Bubblewrap drops its namespaced capabilities before the
sandboxed command starts. The seccomp policy is Docker-default-derived and
admits the small set of namespace and mount syscalls required for setup.

`run-codex` performs a networkless, read-only Bubblewrap preflight with the
selected image. It stops with a setup error if either host policy is absent or
rejected; it never silently falls back to running every command outside the
sandbox. Re-run `bin/setup-codex-host-security` after updating either policy in
this repository.

Do not work around a failed preflight with `--privileged`, `--cap-add
SYS_ADMIN`, or unconfined seccomp/AppArmor modes. See
[`security/README.md`](security/README.md) for profile provenance and design.

See the official [Codex sandbox and approval documentation](https://learn.chatgpt.com/docs/agent-approvals-security) for current behavior and host setup guidance.

### Manual approval-boundary check

The host smoke suite verifies the static launcher and image policy. After a
terminal or IDEA session starts, the following small interactive check verifies
the runtime approval boundary as well:

| Operation | Expected result |
| --- | --- |
| Read a project file or edit the working tree | Runs without approval |
| Write below `.git` | Fails in the sandbox, then requires human approval |
| Access the network | Fails in the sandbox, then requires human approval |

First ask Codex to run this block without escalation:

```text
pwd
sed -n '1,3p' AGENTS.md
printf 'sandbox-write-ok\n' > .codex-sandbox-smoke
cat .codex-sandbox-smoke
rm .codex-sandbox-smoke
touch .git/codex-sandbox-smoke
```

The ordinary working-tree write should succeed and be removed. The final
command should fail with a read-only-filesystem error. Then ask Codex to retry
that exact `.git` command outside the sandbox and cancel the approval. Verify
on the host that cancellation did not create it:

```bash
test ! -e .git/codex-sandbox-smoke
```

For the network boundary, ask Codex:

```text
Run exactly:

curl -4 --connect-timeout 10 --max-time 20 -I https://example.com

First try it without escalation. When network access is blocked, request my
approval to rerun that exact command outside the sandbox. Do not use an
alternative.
```

The first attempt should fail to resolve the host. After approval, the same
command should return an HTTP response through the outer container's normal
Docker bridge network. A command run by Codex cannot inspect that outer
network: its route table and resolver are viewed from the deliberately
networkless Bubblewrap namespace. Run `docker inspect` and `docker exec`
diagnostics from the host instead.

## Testing on the host

The host smoke suite does not require Codex to be installed on the host and does not access the internet:

```bash
./tests/host-smoke.sh
```

Before running the complete suite:

- run it from this Git checkout as the non-root user who builds and runs the images;
- install the host sandbox policy with `bin/setup-codex-host-security`;
- install the synchronization dependencies documented in [Codex state synchronization](docs/codex-sync.md#install-required-software);
- stop all running containers whose names begin with `codex-`, because the synchronization safety checks intentionally refuse to run while a Codex session is active.

The suite checks these prerequisites before executing its tests. It then checks shell syntax and security invariants, verifies launcher and build arguments without starting Docker, and exercises the snapshot push/pull state machine with temporary data.

If Docker is available, the suite also checks each generic or CUDA image that
is already present locally. Both checks verify the non-root user, required
commands, Codex policy components, and a real Bubblewrap namespace using the
installed AppArmor policy and repository seccomp policy. The CUDA check additionally starts the
container with `--gpus all` and verifies `nvcc`, CUDA headers, and
`nvidia-smi`. It therefore requires the NVIDIA driver and Container Toolkit
described in [CUDA host setup](#cuda-host-setup).

The suite uses `--pull=never --network none`; it never pulls or builds an
image. Select different local images with:

```bash
CODEX_TEST_GENERIC_IMAGE=myorg/codex-universal-generic:latest \
CODEX_TEST_CUDA_IMAGE=myorg/codex-universal-cuda:latest \
  ./tests/host-smoke.sh
```

`CODEX_TEST_IMAGE` remains a compatibility alias for
`CODEX_TEST_GENERIC_IMAGE`.

For example, after installing the commands and building the generic image, verify the complete installation from the repository checkout:

```bash
command -v run-codex codex-push codex-pull
docker image inspect leafclick/codex-universal-generic:latest >/dev/null
./tests/host-smoke.sh
```

A successful run ends with:

```text
All host smoke tests passed.
```

To run the non-synchronization checks while a Codex container remains active:

```bash
CODEX_TEST_SKIP_SYNC=1 ./tests/host-smoke.sh
```

To check only a locally available CUDA image, use an intentionally absent
generic image name. This form works in Bash and Fish:

```bash
env \
  CODEX_TEST_SKIP_SYNC=1 \
  CODEX_TEST_GENERIC_IMAGE=local/skip-generic:not-present \
  CODEX_TEST_CUDA_IMAGE=leafclick/codex-universal-cuda:latest \
  ./tests/host-smoke.sh
```

This is a lightweight container/runtime check: it verifies the CUDA compiler,
headers, and GPU visibility through `nvidia-smi`. Project-level CUDA workloads
remain the responsibility of the project using the image.

Set `CODEX_TEST_SKIP_CUDA=1` to omit the CUDA image check on a host without an
NVIDIA runtime. Set `CODEX_TEST_SKIP_IMAGE=1` to omit all real-image checks.

## CUDA host setup

The CUDA image requires:

- an NVIDIA GPU
- a compatible NVIDIA driver
- Docker
- NVIDIA Container Toolkit configured for Docker

NVIDIA documents the Docker/container runtime setup here:

https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/docker-specialized.html

Verify the host driver:

```bash
nvidia-smi
```

Verify that Docker can access the GPU:

```bash
docker run --rm --gpus all \
  nvidia/cuda:13.1.2-base-ubuntu24.04 \
  nvidia-smi
```

Verify the CUDA development environment:

```bash
docker run --rm --gpus all \
  nvidia/cuda:13.1.2-devel-ubuntu24.04 \
  bash -lc 'nvcc --version'
```

`run-codex` adds `--gpus all` only for projects configured with the `cuda` profile.

## Installing commands

The commands under `bin/` should be installed into a directory in the user's `PATH`.

The conventional per-user location on modern Linux systems is:

```text
~/.local/bin
```

Install them with:

```bash
mkdir -p ~/.local/bin

install -m 755 bin/run-codex ~/.local/bin/run-codex
install -m 755 bin/setup-codex-idea ~/.local/bin/setup-codex-idea
install -m 700 bin/codex-push ~/.local/bin/codex-push
install -m 700 bin/codex-pull ~/.local/bin/codex-pull
```

Alternatively, `~/bin` can be used if that is already the user's preferred executable directory.

## Project configuration

Project configuration is machine-local:

```text
~/.config/run-codex/projects/
```

Each project has a small configuration file.

For example:

```text
~/.config/run-codex/projects/my-project
```

may contain:

```text
path=/home/leafclick/src/my-project
profile=cuda
clojure_mcp=auto
```

Another project might contain:

```text
path=/home/leafclick/src/website
profile=generic
clojure_mcp=off
```

The host path may differ between machines.
Registrations created by older launcher versions without a `clojure_mcp` field
are read as `auto`; merely launching them does not rewrite the file.

The project name is the stable identity. Inside the container, the project is always mounted at:

```text
/workspace/<project>
```

For example:

```text
PC A: /home/leafclick/src/my-project
PC B: /data/projects/my-project

container on both:
       /workspace/my-project
```

This gives Codex a consistent project path across development machines.

## Initialize a project

### Generic project

From inside its Git repository:

```bash
cd ~/src/foo
run-codex --init
```

The default profile is `generic`.

An explicit form can also be used:

```bash
run-codex --init foo ~/src/foo
```

Initialization is idempotent. Repeating `--init` for the same project and Git
root leaves its registration unchanged. If `--profile` or `--clojure-mcp` is
omitted on a repeat, the existing setting is preserved. Changing the registered
path, profile, or Clojure MCP behavior requires the corresponding explicit
command below.

The default Clojure MCP setting is `auto`. It can be selected explicitly during
initialization:

```bash
run-codex --init --clojure-mcp on foo ~/src/foo
```

### CUDA project

```bash
cd ~/src/my-project
run-codex --init --profile cuda
```

or explicitly:

```bash
run-codex --init --profile cuda my-project ~/src/my-project
```

If a Git checkout exists on another machine but has not yet been registered there, `run-codex` prints the appropriate `--init` command.

## List projects

```bash
run-codex --list
```

Example:

```text
PROJECT              PROFILE    CLOJURE-MCP  STATUS     PATH
my-project            cuda       auto         OK         /home/leafclick/src/my-project
website              generic    off          OK         /home/leafclick/src/website
```

## Diagnose a project environment

From inside a registered project:

```bash
run-codex --doctor
```

Or name it explicitly:

```bash
run-codex --doctor my-project
```

The command exits successfully only when the required host commands, Docker
daemon, registered project, selected image, image UID/GID, managed policy,
AppArmor/seccomp/Bubblewrap sandbox, and image runtime checks pass. When the
terminal Clojure MCP integration is enabled, the runtime check performs a real
MCP initialize handshake and verifies that the selected image advertises every
allowlisted tool. It uses a disposable networkless container with no host
mounts; it never pulls, builds, installs, or changes the registered checkout or
live `~/.codex` state.

## Change a project's profile

Enable CUDA:

```bash
run-codex --set-profile my-project cuda
```

Switch back to the generic image:

```bash
run-codex --set-profile my-project generic
```

The project configuration stores a logical profile rather than a concrete Docker image name.

This keeps project configuration independent of image naming, tags, architectures, and future runtime variants.

## Change a project's Clojure MCP setting

Use automatic project detection, which is the default:

```bash
run-codex --set-clojure-mcp my-project auto
```

Or force the terminal bridge on or off:

```bash
run-codex --set-clojure-mcp my-project on
run-codex --set-clojure-mcp my-project off
```

The setting affects terminal mode. IDEA mode continues to use IntelliJ's
separate semantic MCP integration.

## Move a checkout

If the checkout moves on one machine:

```bash
run-codex --rebind my-project ~/new/path/my-project
```

This changes only that machine's project registry.

## Running Codex

From anywhere inside a configured Git repository:

```bash
run-codex
```

Or explicitly:

```bash
run-codex my-project
```

By default the launcher resumes the most recent Codex session for that project:

```text
codex resume --last
```

Start a new session instead:

```bash
run-codex --new
```

or:

```bash
run-codex my-project --new
```

### Per-session Codex options

Terminal mode accepts a deliberately small set of Codex options through a
repeatable launcher option:

```bash
run-codex my-project --new \
  --codex-option model=gpt-5.6-sol \
  --codex-option reasoning=high \
  --codex-option no-alt-screen
```

Zero `--codex-option` occurrences keeps the normal defaults. Supported values
are:

| Value | Effect |
| --- | --- |
| `model=MODEL` | Select a model for this session. |
| `reasoning=minimal\|low\|medium\|high\|xhigh` | Select a supported reasoning effort. |
| `search` | Enable Codex live web search for this session. |
| `no-alt-screen` | Keep terminal output in the normal scrollback buffer. |
| `strict-config` | Fail if Codex encounters an unknown configuration key. |
| `image=PATH` | Attach a readable file that resolves inside the registered project; repeat for multiple images. |
| `prompt=TEXT` | Send one initial prompt, including when resuming the last session. |

For example:

```bash
run-codex my-project \
  --codex-option image=design/screenshot.png \
  --codex-option 'prompt=compare the implementation with this screenshot'
```

The launcher translates these values directly into individual Codex arguments;
it never evaluates or shell-splits their contents. Empty, duplicate scalar, and
unknown values are rejected. In particular, this interface does not expose raw
configuration, provider, profile, feature, remote-server, working-directory,
writable-root, sandbox, or approval arguments. Project image paths are resolved
before launch and cannot escape the mounted checkout. `search` is an explicit
per-session opt-in to Codex's hosted live-search tool; it does not enable network
access for commands inside the container sandbox.

## Codex authentication and tokens

### First login on a new installation

The images contain Codex but no OpenAI credentials, and no pre-existing
`~/.codex` directory is required. For a new installation, register a checkout
and explicitly start a new terminal session:

```bash
cd /path/to/my-project
run-codex --init my-project
run-codex my-project --new
```

Use `--new` for this first launch because there is no earlier session to resume.
The launcher creates host `~/.codex` with restrictive permissions, mounts it at
the container user's home with the invoking user's numeric UID/GID, and then
starts Codex's interactive login.

For a headless or container installation, the recommended ChatGPT login path is:

1. Enable device-code login in the personal ChatGPT account's security settings,
   or have a workspace administrator enable it in ChatGPT workspace permissions.
2. Select **Sign in with Device Code** in the first-run Codex login screen.
3. Open the displayed link in a host browser, sign in, and enter the one-time
   code.
4. After Codex starts successfully, exit it if desired and configure or start
   the IDEA integration. Terminal and IDEA modes use the same persisted login.

The one-time device code is only used to authorize the login; it is not the
credential stored on disk. Codex caches and refreshes the resulting credentials
under its normal credential-storage rules. In the container's usual file-backed
case, the cache is the host file `~/.codex/auth.json` through the existing bind
mount, so later containers do not require another login.

Codex also supports an OpenAI API key for usage-based API billing and enterprise
Codex access tokens for eligible workspaces. Follow the official
[Codex authentication guide](https://learn.chatgpt.com/docs/auth) for those
login commands, account requirements, fallback methods, and token-rotation
advice.

The login is stored in the host's `~/.codex` state and is therefore available
to both terminal and IDEA modes. Do not put an API key or access token in
`acp.json`, a project `.env` file, Git, or the Docker image. If Codex uses the
file-backed credential store, treat `~/.codex/auth.json` as a password. The
state synchronization guide's encryption and access-control requirements also
apply to that credential file.

JetBrains AI credentials and AI Credits cannot be forwarded to or consumed by
the Dockerized Codex agent. JetBrains documents ACP agents as independently
authenticated agents that can run without a JetBrains AI subscription; Codex
authenticates separately with ChatGPT or an OpenAI API key. Consequently,
`--codex-option` accepts no credential, provider, or endpoint settings. See the
JetBrains [ACP subscription and authentication notes](https://www.jetbrains.com/help/ai-assistant/acp.html#subscription-requirements)
and the official [Codex authentication guide](https://learn.chatgpt.com/docs/auth).

## IntelliJ IDEA integration

IntelliJ IDEA and other JetBrains IDEs with AI Assistant can use the same
Dockerized Codex through a custom Agent Client Protocol (ACP) agent. This
provides IDE chat, editor context, streamed commands, approval prompts, and
file-change presentation without running JetBrains' separately installed
Codex executable on the host. See JetBrains'
[custom ACP agent instructions](https://www.jetbrains.com/help/ai-assistant/activate-agents.html#add-acp-agents)
and the upstream
[Codex ACP adapter](https://github.com/agentclientprotocol/codex-acp) for the
protocol components used here.

The ACP adapter is bundled in both default images; it is not a separate
container-side installation. Communication uses the ACP process's standard
input and output:

```text
IDEA AI Chat <-> run-codex --idea <-> docker run -i <-> codex-acp
```

IDEA starts the configured host command, and Docker carries the same stdin and
stdout streams into the container. No ACP TCP listener or published Docker
port is involved. IntelliJ's MCP server is separate: because it binds only to
host loopback, `run-codex --idea` relays its one TCP port through a private
per-chat Unix socket instead of giving the Codex container host networking.

JetBrains exposes registry agents and custom agents through different parts of
the UI:

- **Settings → Tools → AI Assistant → Agents** and **Install From ACP
  Registry** manage registry agents. The **Codex** entry whose description is
  **ACP adapter for OpenAI's coding assistant** is JetBrains-managed; an
  **Update** button updates that agent. The Dockerized Codex entry does not
  appear in this page or its search.
- **AI Chat → Add Custom Agent (Beta)** opens `~/.jetbrains/acp.json`. Agents
  defined there appear in the agent selector inside AI Chat. This is the path
  used by this project.

Selecting plain **Codex** runs the JetBrains-managed agent instead of this
project's container launcher.

Setup:

1. Install `jq`, `socat`, and the current `run-codex` and
   `setup-codex-idea` commands as described in
   [Install](#install). Images built from the
   current Dockerfiles already contain `codex-acp` and the container side of
   the relay. Rebuild if the local image predates this integration.

2. Register the project and verify the terminal client first. Complete the
   Codex login, then exit the terminal client.

   ```bash
   cd ~/src/my-project
   run-codex --init
   run-codex
   ```

3. On the host, add the registered project to `~/.jetbrains/acp.json`:

   ```bash
   setup-codex-idea my-project
   ```

4. In IDEA, open **AI Chat**, use its upper-right menu, and select **Add Custom
   Agent (Beta)**. IDEA opens the `acp.json` file it reads. Confirm that it
   contains **Dockerized Codex (my-project)**, then save it. In **Settings →
   Tools → MCP Server**, also select **Enable MCP Server** if it is not already
   enabled. Leave **Project Clients Auto-Configuration**, **Clients
   Auto-Configuration**, and **Manual Client Configuration** unused for this
   agent; the launcher supplies its private Streamable HTTP connection.

5. Start a new agent chat and select **Dockerized Codex (my-project)** from
   the AI Chat agent selector. Custom entries normally appear immediately;
   restart the IDE only if the new entry is missing.

6. Keep **Ask for approval** selected. The adapter internally calls this mode
   `read-only`, but it maps to `workspace-write`, `on-request`, and human
   review. Do not select **Approve for me**: that mode requests Codex
   auto-review, which the image policy intentionally rejects. The image also
   rejects `never` and full-access modes.

7. In the new IDEA chat, use the
   [IntelliJ IDEA MCP prompt](#intellij-idea-mcp-prompt). If the client
   exposes MCP connection status, confirm that `idea` is connected first, but
   treat successful tool calls as the authoritative check. Neither the test's
   shell reads nor its IDEA calls should request approval. Perform the
   [manual approval-boundary check](#manual-approval-boundary-check) as a
   separate test if you also want to verify `.git` and network behavior through
   ACP.

The command preserves other agents and settings in the file, and records the
absolute path of the installed `run-codex`. The resulting entry is equivalent
to:

```json
{
  "agent_servers": {
    "Dockerized Codex (my-project)": {
      "command": "/home/alice/.local/bin/run-codex",
      "args": ["--idea", "my-project"],
      "use_idea_mcp": false,
      "use_custom_mcp": false
    }
  }
}
```

`use_idea_mcp` is intentionally disabled. IDEA's ACP integration otherwise
forwards a host-only STDIO launcher path, which does not exist inside the
container and fails with `No such file or directory`. Instead, IDEA mode
connects Codex to `http://127.0.0.1:64342/stream` inside the container. Two
`socat` processes carry that connection through a mode-0600 Unix socket to
IDEA's host-only `127.0.0.1:64342` listener:

```text
Codex -> container loopback -> private Unix socket -> host loopback -> IDEA
```

The container gets a read-only mount of only the per-chat relay directory. It
does not get host networking, a published port, or the IDEA or Snap
installation. The relay is stopped and its socket removed with the ACP
container. Separate IDEA chats use separate sockets and isolated container
loopback listeners.

IDEA mode mounts the checkout at the same absolute host path inside the
container, so `projectPath` values and file paths returned by IDE tools
identify the same files Codex reads and edits. This solves path identity
without creating a second project symlink.

The launcher's Codex MCP configuration uses `enabled_tools` to expose only
project analysis, inspection, symbol, search, navigation, and read tools. Host
terminal execution, run configurations, database/debugger control,
refactoring, formatting, patching, and other IDE-side writes are not exposed,
so IDE MCP cannot bypass the container's approval and filesystem boundaries.
Working-tree changes still go through Codex inside the hardened container.

`use_custom_mcp` also remains disabled. Together, these ACP flags prevent
arbitrary host-configured MCP launch commands, including host or Snap-specific
paths, from being forwarded into the container. Run `setup-codex-idea
my-project` again to replace an older entry, then start a new chat. JetBrains
documents both flags in its
[ACP configuration reference](https://www.jetbrains.com/help/ai-assistant/acp.html).

The defaults use IDEA's Streamable HTTP endpoint. If IDEA displays a different
loopback port or Streamable HTTP path, ensure those environment variables are
visible to the IDEA process that launches the custom agent:

```bash
CODEX_IDEA_MCP_PORT=64342
CODEX_IDEA_MCP_PATH=/stream
```

The legacy `/sse` endpoint is not the default because current Codex clients
use Streamable HTTP. Set `CODEX_IDEA_MCP=0` only to start IDEA mode without the
IDE MCP connection.

To retry IDEA after updating the launcher or host policy, close the affected
agent chat, reinstall the host policy, and refresh the generated ACP entry:

```bash
bin/setup-codex-host-security
setup-codex-idea my-project
docker ps --filter label=codex-universal.project=my-project
```

The final command shows any still-open terminal or IDEA sessions for that
project. Rebuilding the image is necessary only when it predates the bundled
ACP adapter or another Dockerfile change; launcher, AppArmor, seccomp, and
`acp.json` updates do not by themselves require an image rebuild.

Each IDEA chat gets a separate container with a unique name and the
`codex-universal.project` and `codex-universal.mode=idea` labels. Clicking
**New Chat** can therefore keep the previous chat open while starting another
ACP process. The launcher records the exact container ID for each process and
removes its own container when IDEA closes or terminates it.

A container orphaned by a launcher version from before this cleanup was added
must be removed once, after making sure no terminal or IDEA session is using
it:

```bash
docker rm -f codex-my-project
```

With **Ask for approval**, reads, working-tree edits, and commands that remain
inside the sandbox should run without confirmation. If a harmless command such
as `pwd` or `rg` still requests approval, inspect the reason shown in the
approval dialog or ACP logs. Do not work around it by selecting **Approve for
me**; that enables automatic approval review rather than fixing the underlying
sandbox failure.

If the entry is not available in AI Chat:

1. Do not search for it in **Settings → Tools → AI Assistant → Agents**; that
   page lists registry agents, not custom `acp.json` entries.
2. Verify the generated entry on the host:

   ```bash
   jq -e '.agent_servers["Dockerized Codex (my-project)"]' \
     ~/.jetbrains/acp.json
   ```

3. Check **Settings → Plugins → Installed → AI Assistant** and install any
   available update. IntelliJ IDEA 2026.2 had an
   [`acp.json` discovery regression](https://youtrack.jetbrains.com/issue/LLM-29700)
   that was fixed in an AI Assistant plugin update.
4. Restart IDEA. If the entry is still absent, inspect the host log:

   ```bash
   grep -Ei 'acp\.json|Dockerized Codex|agent_servers|custom agent' \
     ~/.cache/JetBrains/IntelliJIdea*/log/idea.log | tail -n 100
   ```

The [official IntelliJ IDEA Snap](https://www.jetbrains.com/help/idea/installation-guide.html#snap)
uses classic confinement, so it reads the normal `~/.jetbrains/acp.json`; do
not move this file under `~/.config/JetBrains/IntelliJIdea*/`. Run
`setup-codex-idea` outside the container as the same host user that runs IDEA.

Run `setup-codex-idea` once for each registered project. The image installs an
enforced `/etc/codex/requirements.toml` for `workspace-write`, `on-request`,
and human review. OpenAI documents this non-overridable policy layer under
[managed Codex configuration](https://learn.chatgpt.com/docs/enterprise/managed-configuration).

IDEA supplies its host project path in ACP requests, so IDEA mode mounts only
the registered checkout at the same absolute path inside the container. This
keeps file references clickable in the IDE. Terminal mode retains the stable
`/workspace/<project>` path. Codex resume selection is working-directory
scoped, and the ACP adapter filters IDEA sessions by their exact working
directory, so the two path forms create separate resumable session histories.
They share authentication and persisted Codex state, but a conversation should
not be moved between terminal and IDEA modes.

Multiple IDEA chats may run for the same project, each in its own container.
Terminal mode remains mutually exclusive with all IDEA chats for that project,
so close its IDEA agent processes before starting `run-codex my-project` in a
terminal, or exit the terminal session before opening an IDEA agent. Check all
active containers for a project with:

```bash
docker ps --filter label=codex-universal.project=my-project
```

The ACP process opens no host network port. Its diagnostics go to stderr so
stdout remains a clean ACP protocol stream. IDEA integration is optional: if
it is not configured, the bundled adapter remains inactive and the image
continues to work as the terminal environment.

## Container profiles

### `generic`

Uses:

```text
leafclick/codex-universal-generic:latest
```

No GPU-specific Docker options are added.

### `cuda`

Uses:

```text
leafclick/codex-universal-cuda:latest
```

and adds:

```text
--gpus all
```

The profile abstraction deliberately hides the concrete Docker configuration from individual projects.

Future profiles can therefore be added without changing existing project identities.

## Runtime mounts

A project such as `my-project` is launched approximately as:

```text
host project       -> /workspace/my-project
~/.codex           -> container user's ~/.codex
~/.m2              -> container user's ~/.m2
```

Sharing `~/.m2` avoids repeatedly downloading large Maven/Clojure dependencies, particularly CUDA libraries.

The container runs using the host numeric UID/GID.

## Codex state synchronization

Do not point Seafile, Dropbox, Syncthing, or similar software directly at the live `~/.codex` directory. `codex-push` publishes immutable compressed snapshots, and `codex-pull` safely validates and restores them:

```text
live ~/.codex
      │
      │ codex-push
      ▼
immutable snapshot
      │
      ▼
encrypted Seafile library
      │
      │ codex-pull
      ▼
live ~/.codex on another machine
```

### Register an existing checkout on another machine

Project registration is machine-local, so an existing Git checkout can be
registered on machine B while Codex is still running on machine A:

```bash
run-codex --init --profile cuda same-project /another/path
```

This command only registers the checkout; it does not start Codex or hand off
its state. There is no need to finish the current task on machine A, but before
starting Codex on machine B, exit every Codex session and container on machine
A, run `codex-push`, and wait for the snapshot directory to finish
synchronizing. On a machine with no local synchronization baseline, inspect the
available generations and explicitly adopt the newest one before launching the
project:

```bash
codex-pull --list
codex-pull --force GENERATION
run-codex same-project
```

After initial adoption, use ordinary `codex-pull` for later handoffs. Only one
machine should actively modify the shared Codex state at a time. The snapshots
contain `~/.codex`, not the project checkout, so transfer commits and any
uncommitted working-tree changes separately.

Protect the Seafile library with a strong, unique password. Snapshots can contain Codex authentication material and session history; keep the password separate from the repository and synchronized data.

See [Codex state synchronization](docs/codex-sync.md) for required host software, Debian/Ubuntu installation commands, initial setup, daily handoff, recovery, locking, and configuration.

## Security

Security is layered: Docker limits host exposure, and Codex applies its `workspace-write` sandbox to spawned commands. The launcher also drops all Linux capabilities and enables Docker's `no-new-privileges` control.

The container receives access to:

- the selected project checkout
- `~/.codex`
- `~/.m2`

Network access by spawned commands is disabled until approved. An approval to use the network or cross a filesystem boundary should be treated as intentionally widening that boundary for the requested action.

`~/.codex` can contain authentication material such as `auth.json`. It is readable inside the container because the Codex client needs it, although sandboxed commands cannot modify it. Use trusted repositories, review network approvals, and keep synchronized snapshots appropriately access-controlled and encrypted.

## Contributing and security reports

See [CONTRIBUTING.md](CONTRIBUTING.md) for development and testing expectations. Follow [SECURITY.md](SECURITY.md) for private vulnerability reporting and the project's security model.
