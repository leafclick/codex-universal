# Project isolation and cooperating agents

Design and implementation record, 2026-09-12. The first local-lane slice is
implemented in `run-codex`; later synchronization and collaboration-broker
phases remain planned. Issue 23 remains deferred.

## Outcomes and boundaries

The user and the foreground IDEA agent continue to see and edit the exact
checkout open in IDEA. A CLI experiment runs in another directory and container.
Independent projects, and independent experiments within a project, can move
between machines separately. Two agents can contribute to one feature through
explicit messages and reviewed commits.

Preserve non-root Docker execution, dropped capabilities, no-new-privileges,
read-only image roots, Bubblewrap, workspace-write, and user-reviewed escalation.
Cooperation does not give either agent access to the Docker socket, a host shell,
the other agent's writable directory, or its credentials.

The isolation claim is bounded: protect lanes from unintended file, Git, and
runtime interference by containerized agents. The host user and IDEA remain
trusted and can edit the foreground checkout. Agents with the same account can
also consume shared service quotas; a lane is not a separate security principal
at an external service.

## Identity model

| Entity | Meaning | Lifetime |
|---|---|---|
| Project | Logical repository, with stable ID and optional remote URLs | Across machines and checkout moves |
| Lane | An independently evolving line of work belonging to a project | Across launches and machine handoffs |
| Binding | Machine-local mapping of lane ID to canonical checkout path | Local registration |
| Session | One running agent, model selection, and frontend | One launch/resume |
| Collaboration | Shared objective, participants, base revision, and acceptance criteria | One feature or investigation |

Names such as `cortex/main` and `cortex/gpu-experiment` are user-facing aliases.
Opaque IDs prevent accidental namespace collisions. A path or Git common
directory identifies a local binding, not the portable project identity.
Remote URLs are hints, not unique identifiers: forks and multiple remotes exist.
The first implementation uses validated project/lane names as its snapshot
namespace and therefore requires the same names on each machine. Portable
opaque IDs remain a prerequisite for automatic discovery or federation across
uncoordinated machines.

Each lane owns a complete Codex state root, snapshot namespace, local baseline,
handoff lock, container identity, runtime directories, and checkout binding.
Store state outside both the checkout and the existing global Codex state tree:

```text
local application state/projects/PROJECT_ID/lanes/LANE_ID/
    codex-home/
    handoff/
snapshot root/projects/PROJECT_ID/lanes/LANE_ID/
```

Use one shared registry resolver for launcher, sync, and IDEA dispatch. Reject
overlapping roots, duplicate writable checkout bindings, ambiguous paths, and
unsafe IDs before mutation. Start with one independent agent session per lane;
its own subprocesses and delegated agents remain part of that lane's trust scope.

## Checkout and Git design

Keep the existing IDEA checkout in place as the foreground lane. The first
implementation adopts a linked worktree as a background lane and mounts it at
its exact host path. This keeps the user, agent, Git pointer files, and an
optional second IDEA window looking at the same checkout. Do not copy dirty or
ignored files implicitly. Use declared onboarding for local files and an
explicit checkpoint or reviewed patch for uncommitted tracked work.

Each lane receives a unique branch. Background agents publish commits or Git
bundles; authorized import uses a fixed operation with validated repository,
revision, and destination. No live filesystem synchronization of `.git` or
working trees. Checkout onboarding, including local configuration and ignored
inputs, is a required part of creation and machine handoff as specified below.

Linked worktrees share refs, configuration, objects, and administrative state.
The implementation therefore describes them as a weaker shared-Git trust mode,
not as separate Git security principals. It mounts only the selected checkout
plus its common Git metadata, gives every lane a distinct branch, container,
state root, and runtime lock, and retains human approval for Git writes. An
advisory launcher lock cannot constrain IDEA or arbitrary approved commands,
so owners still coordinate those writes.

A future stricter backend may use a standalone repository, read-only metadata
plus a Git broker, or immutable archive/patch exchange. Any such backend must
be evaluated for hooks, configuration, object creation, refs, approval, and the
requirement that the user and IDE see the agent's exact working directory.

## Checkout onboarding: required from the first usable release

A checkout is not ready merely because Git has restored its tracked files.
Projects routinely require ignored configuration, completed templates, local
credentials, datasets, and generated files. Every new checkout and destination
machine must support this setup before agent work or acceptance tests begin.
Existing foreground checkouts can be adopted and validated in place.

Define a versioned project onboarding manifest containing paths, setup actions,
and readiness checks, with an optional machine-local overlay for projects that
do not carry a tracked manifest. Tracked manifests contain instructions and
template references, never filled-in secrets. Machine-local values and source
paths live outside Git and outside Codex history. A local overlay cannot silently
relax mandatory project readiness checks.

| Input kind | Initial provisioning | New lane / other machine |
|---|---|---|
| Tracked template, local completed file | Create missing file from template; support manual completion or a declared generator | Reuse selected portable values or complete again; validate required fields |
| Existing ignored configuration | Explicitly select exact files from a working checkout or local configuration store | Copy privately into the new checkout; do not link writable files between lanes |
| Credentials and secrets | Manual local entry/file selection or an explicitly configured secret provider | Provision separately by default; never assume a tracked template includes credentials |
| Machine-specific paths and settings | Resolve through a local overlay or manual completion | Rebind and validate on the destination; do not copy absolute paths blindly |
| Lane-specific resources | Allocate ports, database names, output directories, and similar values | Generate distinct values; copying configuration must not reconnect experiments to the same writable service |
| Datasets and other large inputs | Select a local source, approved download, or read-only mount | Verify availability/version; avoid duplicating or synchronizing implicitly |
| Generated dependencies and artifacts | Run declared setup steps in the lane container | Regenerate for the machine/runtime; reuse only explicitly compatible caches |

The normal user experience is: choose or register a checkout, see what setup is
missing, copy or generate declared inputs, complete any local templates, then
run readiness checks. Both manual and automated onboarding are first-class.
Provide a resumable `onboard` operation and a read-only `check` operation; their
final command spelling is to be settled with the lane CLI.

Track `needs-setup`, `needs-input`, `checking`, and `ready` on the local binding.
These are local setup states, not portable promises. Incomplete setup permits
opening IDEA and an explicit setup session so the user or agent can complete
configuration; normal feature sessions must report unmet requirements instead
of launching into a broken environment. An agent cannot invent missing secrets
or treat unresolved template placeholders as usable configuration.

Provisioning must preserve existing local files by default. Template updates
produce a reviewable update proposal, not replacement of a completed file.
Allow an explicitly selected source checkout to seed a lane through the host
provisioning operation; the receiving container still receives only its own
files. Validate destination paths and symlinks, make copies private, and reject
traversal or writes outside the declared lane resources. Setup commands run in
the lane's hardened container and use the existing approval policy for network
access or other escalation. A repository manifest is not permission to execute
arbitrary host commands.

Check required files, permissions, unresolved placeholders, and project-specific
configuration validity without printing sensitive values. Store only minimal
setup provenance such as manifest version and completed steps, not secret
contents or low-entropy secret hashes. Readiness must be rechecked when required
inputs, the manifest, or runtime change; failures are reported without deleting
partially completed work. Avoid logging template answers in agent transcripts.

Local checkout inputs are separate from Git and Codex-state snapshots. The
handoff manifest records required input names and provisioning instructions.
Portable nonsecret files may use an explicit allowlist-based transfer artifact;
secret-bearing configuration requires a deliberately selected secure transfer
or reprovisioning. Do not silently sweep ignored files into snapshots. Required
local files must also be accounted for before lane cleanup, including files
that have never been published as commits.

This onboarding contract is part of the initial lane implementation, even if
the first implementation uses manual completion and local file copying. Secret
manager integrations and sophisticated template merging can follow later.

## State, configuration, and machine handoff

Launch both CLI and ACP with the lane's complete Codex state mounted at the
expected container location. Resolve session listing and resume inside that same
state. Never silently fall back to the global state when a lane is missing.

Seed new state from a versioned configuration/skills template. Do not share
writable config through symlinks. Authentication bootstrap and token refresh
need a focused compatibility probe: support explicit per-lane login initially
if copying credentials is unreliable. Keep credentials out of Git and message
payloads. Document that whole-state snapshots may contain credentials.

Preserve the existing immutable archive/checksum/marker publication and validated
restore with backup, applying each independently to a lane. Container and open
file checks must target the selected lane; another project's running container
must not block its handoff. A global administrative lock may protect registry
updates briefly but must not span agent execution or snapshot transfer.

Handoff sequence: stop that lane, preserve code as commits or an explicit WIP
artifact, publish code, publish state with a manifest recording the required
commit, relevant runtime version, and onboarding requirements, wait for
synchronization, then verify code/state and complete destination onboarding
before normal launch. Do not claim cross-system atomic publication;
an incomplete manifest dependency must produce a resumable refusal.

Local paths differ across machines. Probe resume and tool routing under path
changes before promising portable session continuity. Prefer supported path
rebinding; do not rewrite opaque Codex databases. If necessary, require matching
paths for resumed lanes and document that limitation.

One lane has one active machine owner by workflow convention. Local flock and
eventually consistent files do not implement distributed exclusion. Conflicting
offline use preserves both copies and reports divergence; it never automatically
chooses a winning Codex state. Reliable automatic leases would require an online
authority and fencing, outside the initial scope. Parallel work uses different
lanes, whose code can subsequently be consolidated.

## IDEA and runtime isolation

ACP dispatch uses the canonical checkout path to select a lane. Project basename
or repository identity alone is insufficient. Bind an IDEA relay to its exact
project path and prevent requests selecting another open project. Until that
restriction is demonstrated, background CLI lanes use their own language server
and receive no foreground IDEA relay. Existing per-chat socket lifecycle and
network restrictions remain in place.

Mount only the selected checkout, state, and required resources. Give each lane
private build output, test databases, temporary files, REPL/LSP control paths,
and writable dependency caches. Shared read-only caches are optional after tool
compatibility is demonstrated. Do not share a writable Maven local repository
when claiming strict lane isolation; locally installed artifacts can affect
another experiment even without file corruption.

Internal container ports can repeat. Host-published ports and external services
require explicit allocation. CPU/memory limits and GPU workload coordination
prevent resource starvation; separate containers do not partition GPU memory by
themselves. Match existing CUDA and approved-execution behavior in validation.

## Cooperation protocol for two independent models

“Reviewer” is a collaboration role, not a Codex approval reviewer or a product
name. A trusted container adapter maps an agent kind to its image, executable,
state root, authentication bootstrap, model/options, prompt transport, and IDE
capabilities. Adapter selection is data in the lane record and Docker labels;
it is never a shell command supplied by a repository. The first adapter is
`codex`, using a lane-specific `CODEX_HOME` and the supported `--model` flag.
A future `claude` adapter must ship as a reviewed container entrypoint and meet
the same non-root, Docker, Bubblewrap, network, mount, and human-approval
requirements before it is accepted. The revision/message protocol below does
not depend on either adapter.

Start with the foreground agent as feature owner and a background agent as
independent reviewer/test author. This needs only two sessions. When a feature
has separable components, both can implement against an agreed interface.

1. Record the objective, base commit, interface contract, acceptance tests, and
   each participant's responsibility. File ownership reduces overlap but is not
   a security mechanism or proof that changes are compatible.
2. Start each agent in its lane with independent model selection and context.
   Record model, image/runtime version, lane ID, and base revision in results.
3. Exchange bounded messages: question, interface proposal, result available,
   review finding, or integration result. Include sender identity, message ID,
   and the revision being discussed. Recipients acknowledge durable messages;
   retries must not duplicate actions.
4. Publish immutable commits/bundles with a brief result and test evidence.
   Import the requested revision into the recipient's own checkout for testing.
   Never review a moving branch name as though it were a fixed result.
5. The feature owner integrates accepted commits sequentially and runs combined
   acceptance tests. Failed integration returns a concrete finding to its owner.
   Changes to the shared interface require explicit renegotiation.

Messages are peer-provided data, not authorization to run commands, approve
escalation, or expand a task. Use a small controller that routes structured
messages and artifacts through per-session inboxes/outboxes. Each agent can
write only its own outbox. Avoid a shared writable task file or general host
execution endpoint. Runtime container creation remains a host launcher action.

For the first release, manual send/receive and result import are sufficient;
automatic wakeup can follow after delivery, cancellation, and crash recovery
are reliable. Bound message size, rounds, elapsed time, and model spend. Show
both agents' status and pending approvals together. Do not automatically merge
to the foreground checkout while the user is editing it: check the expected
revision and dirty state and require an explicit integration action.

## Implementation sequence and acceptance gates

| Phase | Deliverable | Acceptance gate | Status | Size |
|---|---|---|---|---|
| 0 | Disposable compatibility probes and finalized schemas, including onboarding | Separate state through CLI/ACP; resume/path behaviour; authentication lifecycle; exact IDEA routing; a representative project works with completed local templates and ignored inputs | Partial: static and fake-Docker coverage implemented; live image acceptance remains | M |
| 1 | Stable project/lane registry and backward-compatible default lane | Existing launch behaviour passes; canonical paths and IDs validated; registration survives restart | Implemented locally | M |
| 2 | Per-lane state, runtime locks, scoped safety checks, and minimal checkout onboarding | Two projects run concurrently; local configuration can be adopted/copied/completed; existing files preserved; missing inputs block normal launch but permit setup | Implemented locally | M-H |
| 3 | Per-lane snapshots and explicit machine handoff | Independent generations; incomplete transfer refusal; destination configuration reprovisioned/rebound; divergence preserves both copies; rollback tested | Partial: snapshots now bind a clean required commit, immutable runtime labels, and onboarding contract/readiness to each lane; local two-root refusal/restore fixtures pass, while live second-machine acceptance remains | M-H |
| 4 | Background checkout creation, onboarding, and Git result exchange | Shared-Git authority bounded; independent branches; usable local configuration; source checkout unchanged; cleanup protects unpublished code and local inputs | Partial: managed creation, local exact-commit fast-forward import, and guarded cleanup pass host fixtures; live-image acceptance remains | M-H |
| 5 | Two-agent cooperation and revision-specific review | Distinct containers/models; durable messages; cross-lane writes denied; result import and combined tests demonstrated | Partial: revision-specific Codex review and guarded local result import exist; durable messaging/broker remains | M-H |
| 6 | Stricter checkout backend | Private Git authority or broker is proven without breaking exact-checkout IDE use | Not started; optional | H; optional |

Phases 2 and 3 together deliver independent project handoff. The implemented
part of Phase 4 delivers managed independent worktrees alongside IDEA, guarded
fast-forward result import, and conservative cleanup under an explicit
shared-Git trust model. Phase 5 currently provides a fixed-revision reviewer;
durable peer messaging still needs the controller described above.

## Migration, verification, and operational costs

Keep the existing global state as a legacy lane. Begin new isolated lanes with
fresh state and selected configuration. Offer whole-state copying only from a
stopped source, explaining that it copies all old history and is not selective
project extraction. Preserve the original state and a reversible registry
migration. Do not delete lanes until their commits, artifacts, and state backup
are accounted for; live lanes cannot be removed.

Run the canonical host smoke suite throughout implementation. Add focused
fixtures for template completion, ignored-file provisioning, interrupted setup,
existing-file preservation, secret-free diagnostics, destination rebinding,
distinct lane resources, lane resolution, scoped locks, snapshot namespaces, crash recovery,
wrong-project IDEA requests, stale messages, and dirty integration refusal.
Use two real containers for boundary acceptance: attempt sibling checkout/state
access, shared Git modification, socket misuse, and unapproved network access.
Repeat relevant tests after approved execution because it is part of the trust
model. Host argument checks alone are not evidence of effective isolation.
Validate generic and CUDA profiles when shared image behaviour changes.

Costs include duplicated dependencies and indexes, additional model context and
review effort, credential management, interrupted handoffs, and extra disk/GPU
usage. Parallel implementation is useful only when decomposition and integration
cost less than the time saved. Prefer independent review when work is tightly
coupled; competing implementations are alternatives, not automatically mergeable.

## Evidence informing the proposal

- [Git worktree documentation](https://git-scm.com/docs/git-worktree): shared
  refs/configuration and per-worktree administrative state explain why worktree
  file separation is not a complete Git security boundary.
- [incident.io, June 27, 2025](https://incident.io/blog/shipping-faster-with-claude-code-and-git-worktrees):
  practical parallel feature development with worktrees and dedicated environments.
- [Anthropic, February 5, 2026](https://www.anthropic.com/engineering/building-c-compiler):
  separate container clones, strong verification, and the failure of parallelism
  when agents all tackle the same bottleneck. Its permission-bypassing harness
  is not adopted here.
- [Cursor, February 5, 2026](https://cursor.com/blog/self-driving-codebases):
  coordination lock failures and integration bottlenecks. The reported scale is
  far larger than two agents; our feature owner is a deliberate bounded choice.

These reports inform the design; our implementation must supply its own evidence.
