# codex-universal

## Overview

`codex-universal` runs OpenAI Codex against one local Git project in a
non-root Docker development environment. The checkout remains in its normal
host location for editors, while Docker restricts the host files visible to
Codex. Codex runs with `workspace-write`, human approval for escalation, and
no full-access mode.

Both the generic Ubuntu and NVIDIA CUDA images include Codex, Java, Node.js,
Clojure CLI, Leiningen, Git, and common build tools. Clojure projects also get
native `bb`, `cljfmt`, and `clj-kondo`, a Java-backed `clojure-lsp`, and a
persistent local LSP-to-MCP bridge in terminal mode. Optional IntelliJ IDEA
integration runs the same containerized Codex in JetBrains AI Chat and exposes
a read-only view of the IDE's semantic tools.

See the concise [change log](CHANGELOG.md) for release history.

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

1. Install Docker Engine, Bash, Git, AppArmor, `jq`, `sqlite3`, `socat`, and
   `util-linux`. See
   [host requirements](#host-requirements); CUDA users must also complete
   [CUDA host setup](#cuda-host-setup).

   ```bash
   sudo apt install apparmor apparmor-utils jq sqlite3 socat util-linux
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
   install -m 644 bin/run-codex-doctor.bash ~/.local/bin/
   install -m 700 bin/codex-push bin/codex-pull bin/codex-collab ~/.local/bin/
   install -m 600 bin/codex-sync-lib ~/.local/bin/
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
persistent Codex state. It reports the registered project and profile, fixed
non-root image identity, host runtime UID/GID, read-only image boundary,
sandbox operation, installed tool versions, and the Clojure LSP MCP initialize
handshake. A CUDA project additionally checks GPU access and NVIDIA entrypoint
execution. Optional integrations are reported as warnings or skips.

Then exit Codex and run the host smoke suite from the `codex-universal`
checkout. This short form skips optional state-synchronization tests but still
checks the launcher, policy, Bubblewrap, installed tools, and any locally
available generic or CUDA image:

```bash
cd /path/to/codex-universal
CODEX_TEST_SKIP_SYNC=1 ./tests/host-smoke.sh
```

A successful run ends with `=== ALL HOST SMOKE TESTS PASSED ===`. See
[testing on the host](#testing-on-the-host) for the complete suite, image
selection, CUDA-only checks, and troubleshooting.

Next start a new Codex chat and paste the prompt for that client mode. Terminal
and IDEA sessions use intentionally different paths; IDEA can expose both
semantic providers when Clojure MCP is enabled:

| Client mode | MCP server | Expected project path |
| --- | --- | --- |
| `run-codex` | Container-local `clojure_lsp` | Container path, normally `/workspace/<project>` |
| `run-codex --idea` | Host IDEA `idea`, plus container-local `clojure_lsp` when enabled | Exact absolute host checkout path |

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

Every build tags its image with a Git-derived version. A clean checkout at an
exact Git tag uses that tag. Descendant commits use the nearest tag's slug plus
their distance and short commit, while a repository without a reachable tag
uses `dev-<branch-slug>-<short-commit>`. A modified checkout adds `-dirty`:

```text
leafclick/codex-universal-generic:v1.2.0
leafclick/codex-universal-generic:v1.2.0-2-ga1b2c3d4e5f6
leafclick/codex-universal-generic:dev-main-a1b2c3d4e5f6-dirty
```

By default, the same clean image is also tagged `latest` as a local convenience
alias. Dirty builds receive only their `-dirty` version tag and never move
`latest`. The versioned tag is the immutable identity; `latest` is not a
separate build. Images also carry OCI `version`, `revision`, and `source`
labels; URL credentials are removed from the Git-derived source label.

Both contain the same development environment, including:

- OpenAI Codex CLI
- Codex ACP adapter for IDE integration
- Ubuntu 24.04
- Node.js 24
- Eclipse Temurin JDK 25
- Clojure CLI
- rlwrap for interactive Clojure REPL sessions
- Leiningen
- deps.clj
- Git / Git LFS
- `lsof` for process and endpoint inspection
- common build and development tools

The CUDA variant additionally contains the NVIDIA CUDA development environment.

## Host requirements

Building and running the containers requires:

- Bash
- Docker Engine with an available Docker daemon
- Git
- GNU `grep`
- GNU `coreutils`, including `realpath`
- `util-linux`, including `flock` and `setpriv`
- `jq`
- `sqlite3`
- `socat` for the optional IntelliJ MCP relay
- AppArmor and `apparmor_parser`
- `sudo` for the one-time AppArmor policy installation

The CUDA profile additionally requires the NVIDIA driver and NVIDIA Container Toolkit. The optional `codex-push` and `codex-pull` commands require more host utilities; see the [Codex state synchronization guide](docs/codex-sync.md#install-required-software).

The synchronization commands run on the host. Installing a utility such as `zstd` inside the Docker image does not make it available to those host commands.

## Building

Builds must run from a Git checkout so every image receives Git-derived
revision and source metadata. Explicit `IMAGE_SLUG` and `IMAGE_VERSION` values
do not remove that provenance requirement.

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

Dirty image inputs (`.dockerignore`, either Dockerfile, `docker-build.sh`, or
anything below `container/`) receive a `-dirty` suffix, including when
`IMAGE_VERSION` is supplied explicitly. `TAG_LATEST=1` keeps its literal,
convenient behavior and updates `latest`; when image inputs are dirty, the
build prints a prominent warning and also retains the identifiable `-dirty`
tag. Set `TAG_LATEST=0` when the existing alias must not move, and use
`run-codex PROJECT --image-version VERSION` when an exact image is required.
Unrelated working files do not change the image version.

A specific Codex, ACP adapter, or LSP bridge version can be used:

```bash
CODEX_VERSION=0.154.0 \
CODEX_ACP_VERSION=1.11.0 \
AGENT_LSP_VERSION=0.19.1 \
  ./docker-build.sh all
```

`CODEX_ACP_VERSION` selects the `@agentclientprotocol/codex-acp` npm version
used by the optional IntelliJ integration. `AGENT_LSP_VERSION` selects the
`agent-lsp` MCP bridge used for Clojure semantic navigation.

To update an agent package, first build both profiles with the candidate
version supplied explicitly, run `./tests/host-smoke.sh` with those local
images selected, and verify the installed package versions. Then update the
matching defaults in both Dockerfiles and `docker-build.sh` together. Keep the
previous image's immutable version tag available for rollback; do not replace
a pin with `latest`.

Refresh all audited remote-tool inputs with:

```bash
./scripts/update-tool-versions
```

The updater writes `container/clojure-tool-versions.conf` and
`container/system-tool-versions.conf`. It selects the latest stable Clojure
releases and their published SHA-256 digests, refreshes the NodeSource and
Adoptium key-file hashes, and leaves the deliberately selected Node and Java
major versions unchanged. A signing-key fingerprint change stops the update
for manual audit. Review the small config diff, then rebuild both profiles and
run the smoke suite. The configs can also be edited directly when a specific
version is wanted.

All three agent packages have versioned defaults and can be overridden
explicitly. The Git-derived image tag records the source revision and build
configuration, but builds are not byte-for-byte reproducible: Ubuntu package
repositories and some non-Clojure package channels are resolved at build time.
Do not overwrite a published version tag, and use the registry digest when an
exact image artifact must be selected.

Stable system, Java, and core Clojure layers precede the standalone Clojure tools,
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

`run-codex` uses the `latest` alias unless told otherwise. It requires the
selected image to exist locally and never pulls it implicitly. A pre-built
image can be pulled once and selected by its immutable tag without rebuilding
it for the local UID/GID:

```bash
docker pull ghcr.io/myorg/codex-universal-generic:1.0.0
CODEX_IMAGE_SLUG=ghcr.io/myorg/codex-universal \
CODEX_IMAGE_TAG=1.0.0 \
  run-codex my-project
```

For a one-session override, pass the immutable tag directly:

```bash
run-codex my-project --image-version 1.0.0
```

The command-line value overrides `CODEX_IMAGE_TAG` for that invocation only;
the default remains `latest`.

Images use a fixed non-root default identity (`65532:65532`) and do not capture
the builder's UID or GID. `run-codex` replaces that identity with the invoking
host user's numeric UID/GID, supplies the stable `codex` name through a private
root-owned NSS module, and starts the container with a read-only root filesystem.
Consequently, the same immutable pre-built image can be used on machines whose
users have different numeric identities. Installed image content remains
root-owned; writable state is provided only through explicit bind mounts and
per-container tmpfs mounts.

## Clojure command-line tooling

Both image profiles install checksum-verified, pinned native releases of:

- `bb` (Babashka)
- `cljfmt`
- `clj-kondo`

They install the architecture-independent, Java-backed upstream `clojure-lsp`
executable. Unlike its GraalVM native-image alternative, it starts inside the
terminal bridge's deliberately empty `/proc` while retaining the same pinned
server version and checksum validation. The image smoke fixture uses a
config-free Clojure source tree so this startup check remains networkless and
does not launch a native build tool inside that sandbox.

See [GraalVM Native Image in procfs-hidden sandboxes](docs/graalvm-native-image-procfs.md)
for the general compatibility finding and packaging recommendation behind this
choice.

They also install pinned Clojure CLI, Leiningen, native deps.clj, and `rlwrap`.
The current versions and SHA-256 values are in
`container/clojure-tool-versions.conf`.
The Clojure CLI's interactive `clj` wrapper therefore has line editing and
command history available out of the box. Leiningen's standalone runtime is
preinstalled in the immutable image and exposed through `LEIN_JAR`; non-root
containers can run a configured Leiningen project while the container network
is disabled, without bootstrapping files into the mounted user home.
`DEPS_CLJ_TOOLS_DIR` points deps.clj at the same preinstalled Clojure tools
payload, preserving its fast native startup without a first-use download.

The build downloads immutable release assets and checks every Clojure-tool
download against a pinned SHA-256 value. `cljfmt` is the standalone GraalVM
native executable, so `cljfmt check` and `cljfmt fix` do not launch `clj`.
Each tool uses its upstream defaults and still discovers project-local
configuration such as `bb.edn`, `.cljfmt.edn`, `.clj-kondo/config.edn`, and
`.lsp/config.edn`.

`run-codex` enables a container-local `clojure_lsp` MCP server automatically
for Clojure projects in terminal and IDEA modes. Auto-detection looks for a root
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
processes through procfs. The allowlist excludes broad command execution and
quick-fix entry points whose apply semantics are not locally established;
scoped edit and refactoring tools remain subject to user review. The bridge
derives the selected image JDK's library
directories and carries required inherited native-library paths into that
boundary, so Clojure CLI classpath discovery remains usable despite the empty
`/proc`. A child seccomp filter also prevents nested user namespaces from
remounting writable parents around protected `.git` or `.codex` paths and
denies `setns` after Bubblewrap finishes namespace setup. Set a
persistent per-project override with:

```bash
run-codex my-project --set clojure-mcp on
run-codex my-project --set clojure-mcp off
run-codex my-project --set clojure-mcp auto
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

Semantic navigation can be incomplete while indexing is in progress. Treat
synthetic names, locationless references, and self-edges as diagnostic clues,
not proof of a Clojure LSP or adapter defect. Record the MCP provider, symbol,
and query; compare raw language-server output with the adapter result when the
provider exposes both. If raw output is unavailable, report that limitation,
preserve usable source locations, and label the result incomplete rather than
inventing locations or silently filtering edges.

Semantic MCP is optional best-effort tooling. If a connection returns
`Transport closed`, retain successful results, stop retrying that connection in
the current client, and report incomplete coverage to the primary. Never
automatically replay the interrupted request, especially a state-changing one.
Use IDEA MCP when available with its exact project path; otherwise use bounded
`rg` and numbered source context, labeled as textual evidence. A fresh/resumed
Codex process may establish a new connection. Known upstream stdio lifecycle
reports ([#16899](https://github.com/openai/codex/issues/16899),
[#35486](https://github.com/openai/codex/issues/35486)) do not by themselves prove
which recovery is present in a particular installed Codex version. The server
remains non-required: `required=true`, longer timeouts, and startup grace do not
provide mid-session reconnection. This limitation alone does not invalidate
working Clojure runtime/REPL evidence. An HTTP MCP experiment is deferred; no
HTTP service, reconnect proxy, watchdog or Codex fork is installed here.

The Clojure server runs through a small protocol proxy because the selected
adapter does not consume `window/showMessage`. Error and warning messages are
duplicated as `window/logMessage`, which the adapter forwards to Codex. If the
server reports a type-1 error before returning its initialize result, the proxy
turns that result into an initialization error, so `start_lsp` cannot report a
successful start after a known classpath/indexing failure. Later server errors
remain visible notifications; readiness still requires semantic evidence.

The terminal bridge requests agent-lsp JSON output so native LSP URI/range
locations survive navigation results. This is a location-preservation
mitigation, not a repair for derived impact analysis. `blast_radius` is not
exposed while its adapter cache and Clojure caller/test/export classification
remain unverified; use `find_references` and `find_callers`, retaining the
reported locations and treating incomplete indexing explicitly. A successful
MCP initialize handshake proves connection only. It does not prove classpath
resolution or indexing readiness: report explicit server/classpath failures
and establish readiness with project-appropriate semantic evidence rather than
assuming a particular symbol or namespace count.

For Clojure repositories, the bundled `clojure-development` skill supplies the
editor-independent workflow. A project needs only its own invariants in
`AGENTS.md` and an optional `.codex/clojure-development.edn` recording selected
runtime recipes; see [Clojure development](#bundled-codex-routing-and-clojure-development).
IDEA MCP remains an optional semantic provider.

## Bundled Codex routing and Clojure development

New `run-codex` containers install a small managed workflow into the mounted
Codex home. It provides three custom agents without changing the selected
primary model or its reasoning effort:

| Agent | Fixed model and effort | Use |
| --- | --- | --- |
| `code_reader` | `gpt-5.6-luna`, low | Read-heavy exploration and compact evidence. |
| `clojure_probe` | `gpt-5.6-luna`, low | Execute configured Clojure probes and reduce runtime output. |
| `mechanical_worker` | `gpt-5.6-luna`, medium | Specified repetitive edits and deterministic focused checks. |

All bundled agent files leave Fast disabled, so Standard is the default. Fast is
an explicit user choice for a session or globally; agents respect that live
choice. Codex CLI 0.153.4 was observed loading agent-local model and effort but
applying `service_tier=default` when Fast keys were placed in custom-agent TOML,
so selective agent-local Fast is not claimed. Fast targets roughly 1.5x model
speed at 2.5x ChatGPT credit consumption. Reconsider agent-local Fast only after
runtime telemetry simultaneously proves a child on Fast and the primary on
default.

The global routing instruction is advisory: it recommends delegation based on
avoided context and specialization, even for a Luna primary. Architecture,
probe design, ambiguous behavior, integration, and final review stay with the
primary. The reader owns its delegated semantic query, bounded source reads,
and corroborating searches; the parent consumes that evidence and repeats only
targeted verification where necessary. Once delegated, the parent consumes
that result without repeating its investigation; independent work may continue
meanwhile. Small targeted work remains local, and primary explanations are
concise by default unless requested detail or correctness requires more.

Several already-identified trivial tasks may be dispatched to workers
concurrently when they are genuinely independent and overlapping them should
materially reduce elapsed time. Their boundaries must be disjoint, all should
start before the primary waits, and their compact results should be collected
once. A lone trivial task stays local; dependent work is not split merely to
create parallelism, and workers do not fan out further.

Keep exact targeted tools local when their output is known and bounded, batching
such calls into a few primary turns. Delegate uncertain or noisy execution plus
reduction when safe. If approval, state, or architecture boundaries require
primary-owned execution, capture stdout and stderr in explicit shared files and
delegate only reduction without loading raw output into primary context; consume
the compact packet without rereading the full output.

After the user explicitly authorizes a commit, the primary performs the final
diff review, exact-path staging, and commit itself. These short Git metadata
writes cross the user approval boundary and are not delegated merely to use a
cheaper worker. A mechanical worker may still perform substantial repetitive
pre-commit validation or a complex staging audit.

Agent routing is explicitly optimized for Codex credit spending, elapsed time,
and accepted evidence rather than raw token count. Each delegation defines an
exclusive evidence boundary and acceptance criteria; the primary stays out of
that boundary until it consumes the worker summary. A deficient result is
corrected by reusing the same worker and its retained evidence before starting
over. Related questions
known initially are sent as one assignment with one compact result; follow-ups
are reserved for new information or a specific acceptance failure. Primary-side
tool operations should be batched and output-bounded because each additional
model turn can cost more than the Luna worker it coordinates. Semantic readers
validate arguments against each tool schema, apply small symbol-search limits,
select exact matches before downstream queries, and bound result volume.
Numerical summaries must reconcile their components and totals before the
primary accepts them.

Delegation prompts contain only a short task packet: the exclusive boundary,
questions, acceptance criteria, and requested compact result. They reference
paths instead of copying source and do not repeat stable role or tool guidance.
Self-contained assignments use no inherited chat; otherwise they inherit only
the smallest useful number of recent turns instead of the full conversation.
Workers write predictable requested artifacts directly to disk and return paths
and validation rather than echoing generated files into the primary context.

Workers deliberately absorb evidence-processing volume when that keeps raw
results and repair work out of the more expensive primary context. Before
handoff, a worker self-audits every acceptance criterion, reconciles call and
credit totals, treats empty results cautiously when indexing is incomplete,
performs allowed bounded fallback, and removes unrelated findings. It returns a
compact decision packet rather than a transcript. The primary sends an
objective defect back to the same worker for correction from retained evidence
instead of reconstructing the investigation.
Semantic MCP readiness can be client-local. When substantial semantic work is
likely, one reader starts the LSP early for the exact root with a bounded
readiness timeout while the primary continues disjoint work. The same reader
and its resident LSP are reused across later assignments and idle turns; a
healthy LSP is not restarted between tasks. An isolated lookup should not pay
an explicit startup cost, a stalled start is not retried in the same client,
and restart requires concrete evidence of an unhealthy resident LSP. No hook
enforces these practices or blocks a primary or worker, so normal targeted
`rg`, `sed`, Clojure LSP, and IDEA MCP operations remain available.

Provider lifecycle follows the client. Terminal Codex readers use the
container-local Clojure LSP lifecycle above. IntelliJ ACP readers prefer IDEA's
already-running project index; when `clojure_lsp` is also enabled, they start it
only for Clojure-specific gaps or explicit corroboration. Ordinary questions
use one provider. For an ambiguous, incomplete, or high-risk claim, readers may
query both in parallel and return a compact agreement or discrepancy report.
This deliberate corroboration does not authorize the primary to repeat either
search.

Delegated substantial and long-running commands are observable without an
experimental Codex feature. The primary announces the role, scope, assigned run
ID, and separate stdout/stderr paths before execution, then reads the exact
command, cwd, PID, and status from the run record. Fresh-process commands use
the managed helper:

```bash
~/.codex/scripts/codex-worker-observe help
~/.codex/scripts/codex-worker-observe run cla-gpu-1 -- clojure -M:mkl:cuda -m simulation ...
~/.codex/scripts/codex-worker-observe list
~/.codex/scripts/codex-worker-observe show cla-gpu-1
~/.codex/scripts/codex-worker-observe summary cla-gpu-1
~/.codex/scripts/codex-worker-observe tail cla-gpu-1
~/.codex/scripts/codex-worker-observe tail --stderr --follow cla-gpu-1
```

On its first user-visible response in a session, the primary announces the
natural-language `agent status` and `show active probes` requests and points to
the helper's `help` catalog. The primary assigns run IDs before substantial
delegated commands and reads the durable record directly. It uses the bounded
`summary` view first and opens a longer log tail only when needed;
worker-to-parent messaging is used when available but is not required.

The helper mirrors output into the normal tool transcript while retaining
immutable, per-run metadata and separate logs under
`/tmp/codex-worker-observe`. Set `CODEX_WORKER_OBSERVE_DIR` only to another
private path below `/tmp`. The records last for the container session, never
enter the repository or synchronized Codex state, and must not contain
credentials. Because tool calls can use different PID namespaces, status
reports `not-visible-or-exited` rather than treating an invisible PID as proof
that a command stopped. Persistent Clojure REPL evaluations keep using the
skill's existing raw records instead of this fresh-process wrapper.

The workflow guidance requires approval prompts to identify the substantive
executable, action, and scope. A shell prelude such as `set -Eeuo pipefail`, an
environment assignment, or a generic shell wrapper is not a meaningful
approval target, and approving one never authorizes a later command. In
particular, destructive operations must name their exact action and target in
their own approval request. This is advisory guidance rather than a CLI policy
enforcement hook.

The assets require Codex CLI 0.153.4 or newer, which supports
`~/.codex/agents`, `~/.codex/skills`, and a global `~/.codex/AGENTS.md`.
Inspect active agent roles in the Codex agent picker and verify the skill with
`$clojure-development`. Routing is advisory, not enforced: Codex has no
supported parent-only routing hook in this version. A pre-existing global
`AGENTS.md` is intentionally preserved and cannot be safely composed by the
installer. To retain central routing in that case, add one reference to the
image-owned routing text in your global file, or move its short text there;
projects do not need a copy. Set `CODEX_UNIVERSAL_WORKFLOW=0 run-codex ...` to
skip workflow installation and updates for that launch without modifying the
shared Codex home. Already-installed assets remain available. To explicitly
remove all unmodified managed assets from the shared home, run once with
`CODEX_UNIVERSAL_WORKFLOW=uninstall`; this global operation can affect other
active containers, preserves user-modified assets, and is reversed by the next
enabled (`1`) launch.

The skill uses session-local `/tmp/codex-clojure.*` state for process ownership,
endpoint, log, client-session, and full evaluation records. An entrypoint-owned
service keeps the configured REPL alive across separate Codex tool-command
sandboxes. The service has its own Bubblewrap boundary: working-tree and cache
writes are allowed, while `.git` and `.codex` stay recursively read-only and a
private PID namespace with an otherwise empty `/proc` prevents outer-mount
bypasses. The sole compatibility entry, `/proc/self/exe`, points to the selected
image JVM so native runtimes such as oneMKL can locate their internal loaders;
no process tree, descriptors, environment, or root paths are exposed. An
inherited seccomp filter rejects nested user namespaces that could remount a
writable parent around those protected paths. The service never publishes an
nREPL port or uses a host JVM. Its network namespace contains only loopback;
the supervisor exposes nREPL to the helper through a private mode-`0600`
pathname Unix socket in the per-chat state directory. Run its helper as
`~/.codex/skills/clojure-development/scripts/clojure-development repl-start
<runtime>`, `repl-status`, `repl-eval '(+ 1 2)'`, and `repl-stop`. Evaluations
are serialized. A timeout means execution may continue and must not be
blindly retried.

Individual Codex tool sandboxes may have separate network namespaces without
affecting the persistent REPL. Status and evaluation connect through the shared
Unix socket; lifecycle ownership remains on the control FIFO. Status separates
owned-process liveness from Unix-endpoint reachability. State created by an old
TCP-only helper is rejected for evaluation and must be stopped and restarted;
the helper never silently falls back to direct TCP. Babashka one-off execution
does not use the persistent Unix transport.

One persistent runtime is supported per chat. Share it among agents working on
the same parent-coordinated experiment; serialize independent runtime tasks.
Project and eval-recipe guards prevent accidentally controlling a different
project or evaluating against changed configuration, but do not provide
same-project task isolation or security between agents sharing filesystem access.
The recipe guard compares argv, kind and workdir only; changes to dependency
aliases, Lein profiles, environment, loaded source or classpath still require
deliberate reload/restart decisions. Matching metadata does not prove freshness.

Add `.codex/clojure-development.edn` for a shared REPL, selected aliases or
profiles, and one-off Babashka commands. Commands are argv vectors, not shell
strings, and their EDN representation is bounded to 2048 UTF-8 bytes for the
atomic process-service transport. This compact example names a Clojure CLI
development profile and a one-off Babashka runtime:

```clojure
{:default-runtime :dev
 :runtimes {:dev {:kind :deps
                  :repl ["clojure" "-M:dev" "-m" "nrepl.cmdline"
                         "--bind" "127.0.0.1" "--port" "0"]}
            :bb {:kind :babashka :one-off ["bb" "-e"]}}
 :tests {:unit {:command ["clojure" "-M:test"] :fresh-process :when-required}
         :integration {:command ["clojure" "-M:integration-test"] :fresh-process :always}}
 :validation {:lint-command ["clj-kondo" "--lint"]
              :format-command ["cljfmt" "check"]
              :format-fix-command ["cljfmt" "fix"]}}
```

`deps` preserves its selected `-M`, `-X`, or legacy `-A` semantics; the helper
does not translate them. Leiningen preserves its selected profiles and
`repl-options`; a Leiningen recipe is valid only when those project settings
select loopback and an ephemeral port. The enclosing networkless namespace is
the runtime enforcement boundary. Babashka probes use the explicit
`one-off FORM [runtime]`
operation; output and overall runtime are bounded, and timeout or normal
leader exit cleans up the complete process group before termination is
reported as confirmed. Persistent nREPL is for retained state and is not
evidence for JVM-only behavior. A `bb` task can launch a JVM, so classify the
invoked runtime. Use configured `:always` tests
for integration suites and a fresh process after classpath, JVM-option, native
backend, generated-class, or global-state changes.

For a first Clojure project without this file, inspect documented commands and
configuration first, including `AGENTS.md`, README/developer documentation,
`deps.edn`, `project.clj`, `bb.edn`, and relevant tool configuration. Propose a
complete argv recipe that preserves the documented profile or alias, JVM
options, and entry point, then ask only about genuine choices between documented
profiles or an undocumented REPL dependency. Do not infer a recipe merely from
`deps.edn`, `project.clj`, or `bb.edn`; those files remain useful evidence for a
documented proposal. See the skill's [first-project setup](container/codex-workflow/skills/clojure-development/references/first-project.md).
Validating that recipe means running the helper's `config-validate` operation;
mapped tests, linters, and formatters remain separate, deliberately selected
checks.

Discovery of the bundled reader or successful Luna/low spawning does not verify
the persistent REPL or `clojure_probe`. Verify them with a successful start,
one probe that defines a harmless sentinel, a separate probe that consumes the
retained sentinel, and a status/stop sequence that confirms the same runtime
and termination. Project tests are a separate correctness gate, not a
prerequisite for exploratory REPL verification.

For a migration, a large project `AGENTS.md` can shrink to project invariants
plus: `Clojure runtime commands: see .codex/clojure-development.edn.` The
full schema and runtime references are bundled with the skill; the legacy
[copyable guidance](docs/clojure-agents.md) remains useful for installations
that intentionally disable the bundled workflow.

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
sudo apt install apparmor apparmor-utils jq sqlite3 socat util-linux
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
`run-codex` requires the installed `codex-universal` AppArmor profile and
rejects `unconfined`, `docker-default`, and arbitrary profile overrides.

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

The suite checks these prerequisites before executing its tests. It then checks shell syntax and security invariants, verifies launcher and build arguments without starting Docker, and exercises the snapshot push/pull state machine with temporary data. Host-side launcher and synchronization checks do not require Babashka.

If Docker is available, the suite also checks each generic or CUDA image that
is already present locally. Both checks verify the non-root user, required
commands, Codex policy components, and a real Bubblewrap namespace using the
installed AppArmor policy and repository seccomp policy. The Clojure helper,
process supervisor, Unix transport, bounded decoder, and one-off lifecycle
fixtures run here with the image's pinned Babashka rather than an arbitrary
host installation. The CUDA check additionally starts the
container with `--gpus all` and verifies `nvcc`, CUDA headers, and
`nvidia-smi`. It therefore requires the NVIDIA driver and Container Toolkit
described in [CUDA host setup](#cuda-host-setup).

For each local image, the host first runs a bounded `bb --version` preflight,
then uses that image's pinned Babashka to orchestrate the image-internal test
phases. The runner prints each phase before it starts, its timeout, periodic
elapsed-time heartbeats, its duration, and a final phase summary. Successful
command output is captured; a failed phase prints only bounded stdout and
stderr tails. The host also applies an outer deadline to the Docker run and
removes the specifically named test container on failure or interruption.

The default image-suite heartbeat is 10 seconds, the process kill grace period
is 5 seconds, and the outer per-image deadline is 660 seconds. Override these
positive integer values when diagnosing unusually slow hosts:

```bash
CODEX_TEST_IMAGE_HEARTBEAT_SECONDS=15 \
CODEX_TEST_IMAGE_KILL_AFTER_SECONDS=10 \
CODEX_TEST_IMAGE_TIMEOUT_SECONDS=900 \
  ./tests/host-smoke.sh
```

The suite uses `--pull=never --network none`; it never pulls or builds an
image. Select different local images with:

```bash
CODEX_TEST_GENERIC_IMAGE=myorg/codex-universal-generic:latest \
CODEX_TEST_CUDA_IMAGE=myorg/codex-universal-cuda:latest \
  ./tests/host-smoke.sh
```

Keep disposable integration fixtures and local validation records under
`.local-fixtures/` and `.local-checks/`. Both directories are excluded from
the Docker build context, so large caches and private probe evidence are not
sent to the daemon during an image rebuild.

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
=== ALL HOST SMOKE TESTS PASSED ===
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

This is a lightweight container/runtime check: it runs the image under a
numeric UID/GID different from its built-in identity, verifies the read-only
root and writable tmpfs boundaries, verifies identity lookup without inherited
NSS loader variables, confirms that NVIDIA's upstream entrypoint hands off the
requested command with that clean environment, and checks the CUDA compiler,
headers, and GPU visibility through `nvidia-smi`. In IDEA mode the NVIDIA
initialization banner is routed to stderr so ACP stdout remains protocol-only.
Project-level CUDA workloads remain the responsibility of the project using
the image.

Set `CODEX_TEST_SKIP_CUDA=1` to omit the CUDA image check on a host without an
NVIDIA runtime. Set `CODEX_TEST_SKIP_IMAGE=1` to omit all real-image checks,
including the Clojure-helper runtime fixtures.

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

`run-codex` adds `--gpus all` only for projects configured with the `cuda`
profile. The CUDA image wraps Bubblewrap with a fresh minimal `/dev`, then adds
back only the Docker-authorized NVIDIA device nodes needed inside Codex's
nested sandbox, so visibility/NVML-style tools such as `nvidia-smi` may work.
Full CUDA driver/runtime initialization can still fail in the inner sandbox,
commonly with CUDA error 304, because of PID/procfs isolation. GPU workloads
that require CUDA runtime initialization should be rerun with explicit
user-approved elevation.

When a sandboxed command exits non-zero and its output matches a known CUDA
driver/runtime initialization failure, the CUDA wrapper appends a best-effort
note suggesting retry with user-approved elevation. Set
`CODEX_CUDA_FAILURE_HINT=off` to disable the diagnostic, or `on` to force it;
`true`, `yes`, `1`, `false`, `no`, and `0` are accepted equivalents. Automatic
mode captures only non-interactive output when NVIDIA devices are present and
waits for bounded readers before scanning the final 64 KiB. This detection
does not replace the documented requirement to elevate real CUDA runtime
workloads.

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
install -m 644 bin/run-codex-doctor.bash ~/.local/bin/run-codex-doctor.bash
install -m 755 bin/setup-codex-idea ~/.local/bin/setup-codex-idea
install -m 700 bin/codex-push ~/.local/bin/codex-push
install -m 700 bin/codex-pull ~/.local/bin/codex-pull
install -m 700 bin/codex-collab ~/.local/bin/codex-collab
install -m 600 bin/codex-sync-lib ~/.local/bin/codex-sync-lib
```

Keep `run-codex-doctor.bash` beside `run-codex`; it is a sourced companion
module, not a standalone command. When `run-codex` is installed as a symbolic
link, it resolves the link target and loads the module from that directory.
Likewise, keep `codex-sync-lib` beside `codex-push` and `codex-pull`; both
snapshot commands source the shared validation module.

Alternatively, `~/bin` can be used if that is already the user's preferred executable directory.

## Project configuration

Project configuration is machine-local:

```text
~/.config/run-codex/projects/
~/.config/run-codex/lanes/
~/.config/run-codex/state/
```

Each project has a default-lane configuration file. Additional lanes are
stored below `lanes/<project>/<lane>`, and each newly registered lane receives
its own Codex home and Maven cache below `state/<project>/<lane>/`.

For example:

```text
~/.config/run-codex/projects/my-project
```

may contain:

```text
path=/home/leafclick/src/my-project
profile=cuda
clojure_mcp=auto
lane=default
state=isolated
agent=codex
```

Another project might contain:

```text
path=/home/leafclick/src/website
profile=generic
clojure_mcp=off
```

The host path may differ between machines. Old three-field and one-line
registrations remain valid as the `default` lane and continue to use the
legacy global `~/.codex` state. New registrations use isolated state; merely
launching an old registration does not migrate or rewrite it.
Registrations created by older launcher versions without a `clojure_mcp` field
are read as `auto`; merely launching them does not rewrite the file.

The project name plus lane is the runtime identity. An ordinary default
checkout is mounted at:

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
An ordinary non-default lane uses `/workspace/<project>--<lane>`. A linked Git
worktree instead keeps its exact host path inside the container, as explained
below, because its Git pointer metadata contains absolute paths. IDEA mode also
always keeps the exact host path so the user, agent, and IDE index agree.

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

Linked Git worktrees are supported as separate lanes. Checked-out submodules
remain unsupported because their superficially similar `.git` pointer denotes
a different repository rather than another worktree of the same repository.

### Add an isolated experiment or reviewer lane

Create a managed checkout from any commit available in the default lane's
repository:

```bash
run-codex my-project --lane review --create HEAD
run-codex my-project --lane review --onboard --from ~/src/my-project
run-codex my-project --lane review --check
```

The default checkout must be clean. The launcher resolves the requested
revision to a commit, creates branch `codex/PROJECT/LANE` and its linked
worktree under `$XDG_CONFIG_HOME/run-codex/worktrees/PROJECT/LANE`, registers
the isolated lane, and seeds only the default lane's login and user
configuration. The onboarding step is needed only when the project declares
checkout-local inputs.

To adopt a checkout at an exact user-selected path instead, create and
register it manually:

```bash
git -C ~/src/my-project worktree add \
  -b experiment/reviewer ~/src/my-project-review HEAD
run-codex --init --lane review my-project ~/src/my-project-review
```

The main and review lanes may now run concurrently:

```bash
run-codex my-project --new
run-codex my-project --lane review --new \
  --codex-option model=gpt-5.6-sol
```

They have different checkout mounts, Codex homes, Maven caches, session indexes,
container names, labels, and runtime locks. They still share the worktree repository's
common Git metadata. The review container receives that metadata as one
additional bind mount so Git works, but it does not receive the other working
tree. Git-metadata writes remain sandbox-protected and require human approval.
This is strong working-file and agent-state isolation, not separate Git
security principals: approved ref/config/object changes are visible to every
worktree. Give lanes distinct branches and coordinate approved Git operations.
Worktrees created through symlinked or lexically non-canonical checkout paths
are rejected because their absolute pointer/back-pointer paths would not exist
inside the exact-path container mount; recreate them using canonical paths.

After committing a managed lane's result, import its exact HEAD into a clean
default lane with an explicit full commit ID:

```bash
result_commit="$(git -C ~/.config/run-codex/worktrees/my-project/review rev-parse HEAD)"
run-codex my-project --lane review --import "$result_commit"
```

Import is deliberately local to linked worktrees that share Git metadata. It
locks both launcher lanes, verifies a clean source whose HEAD equals the
supplied commit, rechecks the default HEAD, and performs only a fast-forward of
the clean default branch. It never merges divergent histories or accepts an
abbreviated or moving source revision. Other trusted host or approved Git
operations still share authority over the common repository and must be
coordinated separately.

When the result is integrated, remove a launcher-managed checkout with:

```bash
run-codex my-project --lane review --remove
```

Removal refuses adopted paths, active lanes, dirty/untracked/ignored files,
declared local inputs, and commits not reachable from the default lane. It
removes the managed worktree and registration, and deletes the expected safe
branch when Git confirms it is integrated. Lane Codex state and synchronized
snapshot history are deliberately retained for separate archival or recovery.

Exchange a bounded, revision-specific message between two isolated lanes with
an explicit host-side delivery step:

```bash
commit="$(git -C ~/.config/run-codex/worktrees/my-project/review rev-parse HEAD)"
printf '%s\n' 'Please review the result at the attached revision.' > /tmp/review-message.txt
message_id="$(codex-collab send my-project --lane review --to default \
  --kind result-available --revision "$commit" --body-file /tmp/review-message.txt)"
codex-collab deliver my-project --lane review "$message_id"
codex-collab list my-project --lane default
codex-collab read my-project --lane default "$message_id"
codex-collab ack my-project --lane default "$message_id"
```

`send` writes only an immutable record in the selected source lane's host-side
outbox. `deliver` validates its project, lanes, full commit, body hash, and
recipient before atomically copying it to the declared inbox. Repeated delivery
and acknowledgment are idempotent; a reused ID with different content is
quarantined and reported as divergence. Message bodies are inert data, limited
to 64 KiB, and never authorize commands, approvals, wakeups, Git operations, or
merges. The controller supports `question`, `interface-proposal`,
`result-available`, `review-finding`, and `integration-result`; importing an
accepted result remains the separate explicit `run-codex --import` operation.

This first controller slice is local to one host's registered linked-worktree
lanes. It does not yet broker messages across machines or automatically wake an
agent. Run the command on the host, not inside an agent container; containers
do not receive the other lane's inbox or state directory.

To copy only login and user configuration into a new lane, opt in during
registration:

```bash
run-codex --init --lane review \
  --bootstrap-codex-home ~/.codex \
  my-project ~/src/my-project-review
```

The bootstrap copies regular top-level `auth.json`, `config.toml`,
`requirements.toml`, and `*.config.toml` files with mode `0600`. It does not
copy sessions, history, SQLite state, logs, memories, or caches, so the new
agent starts with an independent context. Symlinks and a non-empty destination
are rejected. Without bootstrapping, the lane performs its own first login.

An immutable initial review can be started against any commit available in the
reviewer's repository:

```bash
run-codex my-project --lane review --review owner-branch \
  --codex-option model=gpt-5.6-sol \
  --codex-option reasoning=high
```

If the explicitly named non-default lane is not registered, `--review` creates
a detached managed worktree for the resolved commit under
`$XDG_CONFIG_HOME/run-codex/worktrees/PROJECT/LANE` (or the corresponding
`~/.config` path), registers isolated lane state, and inherits the default
lane's profile and Clojure MCP setting. It also seeds missing `auth.json`,
`config.toml`, `requirements.toml`, and `*.config.toml` files from the default
lane's Codex home with private permissions. Sessions, history, databases, and
caches remain isolated. Existing lane registrations are never replaced, and a
conflicting managed path is rejected rather than overwritten.

The launcher refuses a default lane or a reviewer checkout with tracked
changes, starts a fresh context, and supplies a read-only review task for that
exact commit. `agent=codex` is the first trusted container adapter. The
registry and Docker labels keep the adapter identity separate from the lane
and reviewer role so a future hardened image can add a Claude adapter without
changing the handoff or human-approval boundary.

Lane state uses a separate snapshot namespace and local baseline. After
stopping the selected lane, publish or restore it independently:

```bash
run-codex my-project --lane review --push-state
run-codex my-project --lane review --list-state
run-codex my-project --lane review --pull-state
run-codex my-project --lane review --force-state 7
```

The synchronized root defaults to `~/Seafile/CodexSync` and can be changed with
`CODEX_SYNC_ROOT`. Data is stored below
`projects/<project>/lanes/<lane>`; local baselines and handoff locks are scoped
the same way. Register the same project and lane names on each machine even
when their absolute checkout paths differ. A running different lane does not block this operation, while a
running container for the selected lane does. These commands reuse the same
transactional archive, checksum, marker, database validation, divergence, and
rollback implementation as `codex-push` and `codex-pull`. Code commits and
checkout-local onboarding inputs remain separate from the Codex-state snapshot.

Lane-aware pushes require a clean checkout, completed onboarding, and a locally
available image. The snapshot marker records the exact required Git commit,
project/lane identity, image profile plus immutable OCI version/revision, and a
hash of the declared onboarding contract. Pull and forced recovery validate
those requirements before replacing live state. The destination checkout path
may differ, but it must be clean, checked out at the recorded commit, use the
recorded runtime, carry the same onboarding declarations, and pass its local
readiness checks. A mismatch is a resumable refusal: provision or rebind the
destination and run the same pull again. Forced recovery does not bypass these
code/runtime/onboarding requirements.

### Declare and provision checkout-local files

A lane may require ignored configuration before normal work can start. Put a
tracked manifest at `.codex-universal/onboarding.json`, or add machine-local
requirements at either
`~/.config/run-codex/onboarding/<project>.json` or
`~/.config/run-codex/onboarding/<project>/<lane>.json`. The manifests are
additive: a local overlay cannot remove a tracked requirement.

```json
{
  "version": 1,
  "files": [
    {
      "path": ".env",
      "template": ".env.example",
      "secret": true,
      "mode": "0600",
      "placeholders": ["CHANGE_ME"]
    },
    {
      "path": "config/local.edn",
      "secret": false,
      "mode": "0644"
    }
  ]
}
```

Check readiness, then provision missing files from another checkout or from
declared templates:

```bash
run-codex my-project --lane review --check
run-codex my-project --lane review --onboard --from ~/src/my-project
```

Provisioning never overwrites an existing file. Source files, templates,
destinations, and parent directories must be regular non-symlink paths inside
their declared checkout. Secret files may not grant group or other access.
Checks report missing files, unsafe file types, permissions, and unresolved
placeholder presence without printing file contents or placeholder values.
Normal sessions refuse an incomplete manifest; `--setup` deliberately opens
the same hardened lane so missing values can be completed. Setup commands are
not run on the host from the manifest.

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
PROJECT              LANE             PROFILE    CLOJURE-MCP  MODEL                    REASONING  STATUS     PATH
my-project            default          cuda       auto         gpt-5.6-sol              high       OK         /home/leafclick/src/my-project
website               default          generic    off          -                        -          OK         /home/leafclick/src/website
```

Model and reasoning columns show `-` when a lane has no persistent preset.

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
daemon, registered project, selected image, fixed non-root image identity,
host runtime identity, read-only root, managed policy,
AppArmor/seccomp/Bubblewrap sandbox, and image runtime checks pass. When the
terminal Clojure MCP integration is enabled, the runtime check performs a real
MCP initialize handshake and verifies that the selected image advertises every
allowlisted tool. It uses a disposable networkless container with no host
mounts; it never pulls, builds, installs, or changes the registered checkout or
live `~/.codex` state.

## Change a project's profile

Enable CUDA:

```bash
run-codex my-project --set profile cuda
```

Switch back to the generic image:

```bash
run-codex my-project --set profile generic
```

The project configuration stores a logical profile rather than a concrete Docker image name.

This keeps project configuration independent of image naming, tags, architectures, and future runtime variants.

## Change a project's Clojure MCP setting

Use automatic project detection, which is the default:

```bash
run-codex my-project --set clojure-mcp auto
```

Or force the container-local bridge on or off:

```bash
run-codex my-project --set clojure-mcp on
run-codex my-project --set clojure-mcp off
```

The setting affects both terminal and IDEA modes. IDEA always keeps its
integrated semantic MCP connection when enabled; a resolved `auto` or `on`
setting adds `clojure_lsp` as a second provider.

## Set persistent Codex model and reasoning presets

Store terminal-session defaults in a project's selected lane:

```bash
run-codex my-project --set model gpt-5.6-sol
run-codex my-project --set reasoning high
run-codex my-project --lane review --set model gpt-5.6-terra
run-codex my-project --lane review --set reasoning medium
```

The model uses the same identifier validation as `--codex-option model=...`.
Reasoning accepts `minimal`, `low`, `medium`, `high`, or `xhigh`. Presets are
lane-scoped: changing a review lane does not change the default lane. Registry
entries written by older launchers remain valid and behave as if neither
preset were configured.

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

List the active, non-archived sessions recorded for a project:

```bash
run-codex my-project --sessions
```

This is the terminal-mode session list. IDEA's AI Chat owns its separate ACP
chat list; see the
[IDEA conversation notes](docs/intellij.md#conversation-ownership-and-resume).
The terminal list contains only the session name, update time, and UUID; it
does not print prompts or transcript previews. Names assigned automatically by
Codex and names changed with `/rename` are both supported. Resume by full UUID
or by a case-insensitive substring of the session name:

```bash
run-codex my-project --resume gpu-tuning
```

A unique match starts `codex resume UUID` inside the normal hardened project
container. An ambiguous query prints only its matching sessions and exits
without launching Docker. A missing query fails with a hint to run
`--sessions`. Matching is restricted to non-archived sessions whose recorded
container working directory belongs to the selected project.

### Per-session Codex options

Terminal mode accepts a deliberately small set of Codex options through a
repeatable launcher option:

```bash
run-codex my-project --new \
  --codex-option model=gpt-5.6-sol \
  --codex-option reasoning=high \
  --codex-option no-alt-screen
```

Without a model or reasoning option, the selected lane's persistent preset is
used when present. A one-shot `model=...` or `reasoning=...` value takes
precedence over its corresponding persistent preset. Supported values are:

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
For a new registration, the launcher creates a private lane Codex home below
`~/.config/run-codex/state/<project>/<lane>/codex-home`, mounts it at
`~/.codex` inside the container, runs with the invoking user's numeric UID/GID,
and then starts Codex's interactive login. Legacy registrations continue to
mount host `~/.codex` until explicitly recreated or migrated.

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

JetBrains IDEs with AI Assistant can connect to the same hardened, Dockerized Codex through a custom ACP agent. The complete setup, relay design, security boundaries, troubleshooting, and operational guidance are in the dedicated [IntelliJ IDEA integration guide](docs/intellij.md).

The short path is: register each project normally, run `setup-codex-idea` once,
select **Dockerized Codex (codex-universal)** in AI Chat, and keep **Ask for
approval** selected. The single global entry routes each new ACP chat from its
IDEA working directory to the matching registered project, including its image
profile and launcher policy. IDEA's conversation list remains owned by
JetBrains AI Assistant.

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
per-container tmpfs -> container user's home and /tmp
```

Sharing `~/.m2` avoids repeatedly downloading large Maven/Clojure dependencies, particularly CUDA libraries.

The container runs using the host numeric UID/GID, regardless of the fixed
identity stored in the image. Its root filesystem is read-only. The project,
`~/.codex`, and `~/.m2` bind mounts remain writable, while ephemeral home/cache
files and `/tmp` live in tmpfs. Both tmpfs mounts permit execution because JVM
native loaders extract shared libraries into locations such as
`~/.javacpp/cache` and `/tmp`; both remain `nosuid` and `nodev`. A root-owned
glibc NSS module maps the process's non-root numeric identity to the stable
in-container name `codex`. It requires neither a writable passwd file nor an
`LD_PRELOAD` setting, so native JVM and CUDA libraries retain their normal
loader environment. The container never needs to start as root.

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
run-codex --init --lane same-lane --profile cuda same-project /another/path
```

This command only registers the checkout; it does not start Codex or hand off
its state. Use the same project and lane names on both machines. Before
switching ownership, commit and publish the lane's code, complete its onboarding
check, exit its Codex container on machine A, and publish the contextual state:

```bash
git -C /path/to/machine-a-checkout status --short
run-codex same-project --lane same-lane --check
run-codex same-project --lane same-lane --push-state
```

Wait for the snapshot provider to finish. On machine B, list the synchronized
generations; the `REQUIREMENTS` column shows the abbreviated required commit and
runtime. Fetch/check out that exact commit, install or select the same immutable
image version, complete destination onboarding, and explicitly adopt the newest
generation on first use:

```bash
run-codex same-project --lane same-lane --list-state
git -C /another/path switch SAME_LANE_BRANCH
git -C /another/path merge --ff-only REQUIRED_COMMIT
run-codex same-project --lane same-lane --onboard
run-codex same-project --lane same-lane --check
run-codex same-project --lane same-lane --force-state GENERATION
run-codex same-project --lane same-lane --new
```

For later forward handoffs, use `--pull-state` instead of `--force-state`.
Only one machine should actively modify a lane's state at a time. The snapshots
contain lane Codex state, not the project checkout, so transfer commits and any
uncommitted working-tree changes separately.

Protect the Seafile library with a strong, unique password. Snapshots can contain Codex authentication material and session history; keep the password separate from the repository and synchronized data.

See [Codex state synchronization](docs/codex-sync.md) for required host software, Debian/Ubuntu installation commands, initial setup, daily handoff, recovery, locking, and configuration.

## Security

Security is layered: Docker limits host exposure, mounts the image filesystem
read-only, and Codex applies its `workspace-write` sandbox to spawned commands.
The launcher also drops all Linux capabilities and enables Docker's
`no-new-privileges` control.

The container receives access to:

- the selected project checkout
- `~/.codex`
- `~/.m2`

Network access by spawned commands is disabled until approved. An approval to use the network or cross a filesystem boundary should be treated as intentionally widening that boundary for the requested action.

`~/.codex` can contain authentication material such as `auth.json`. It is readable inside the container because the Codex client needs it, although sandboxed commands cannot modify it. Use trusted repositories, review network approvals, and keep synchronized snapshots appropriately access-controlled and encrypted.

## Contributing and security reports

See [CONTRIBUTING.md](CONTRIBUTING.md) for development and testing expectations. Follow [SECURITY.md](SECURITY.md) for private vulnerability reporting and the project's security model.
