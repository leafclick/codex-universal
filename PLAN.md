# Codex Universal Plan

This file contains only unresolved work retained from `review.md` and the
subsequent runtime investigation. Completed and refuted findings are preserved
in `REVIEW-ARCHIVE.md`; current execution evidence and probe failures remain in
`STATUS.md`.

Issue 23 remains deferred. Issue 44 now has a first source implementation and
remains in progress for live/multi-machine acceptance and the collaboration
broker. See the
[project isolation and cooperation plan](docs/project-isolation-plan.md) for
scope, tradeoffs, migration, implementation phases, and acceptance gates.
Checkout onboarding (including ignored configuration, completed templates, and
machine-specific inputs) is required in the initial lane implementation.

Evidence labels:

- `OPEN`: more evidence or a product decision is required.
- `DYNAMICALLY CONFIRMED`: reproduced with a runtime or disposable fixture.
- `SOURCE CONFIRMED`: established directly from the current source or docs.

Complexity is relative: `T` trivial, `L` contained, `M` multi-file or
test-heavy, and `H` architectural or integration-heavy.

## Deferred general maintenance

| ID | Type | Work item | Evidence | Status | Complexity | Reason |
|---:|---|---|---|---|---|---|
| 23 | Improvement | Optionally revisit generic/CUDA Dockerfile deduplication and package pruning if the files grow substantially or actual profile drift appears. | SOURCE CONFIRMED | Deferred by product decision. The common blocks currently match, and speculative package pruning is not valuable enough to pursue now. | H for refactor; M for package audit | Avoid architecture and compatibility work until growth or demonstrated drift justifies it. |

## Project isolation design work

The current whole-state handoff remains usable when operators stop sessions
before synchronization. Per-group isolation is optional future architecture,
not a current handoff correctness defect.

| ID | Type | Work item | Evidence | Status | Complexity | Reason |
|---:|---|---|---|---|---|---|
| 44 | New feature | Add project/lane isolation, independent state handoff, and cooperation between isolated agents. | SOURCE IMPLEMENTED (partial) | Local lanes now have distinct checkout/state/cache/container/lock identities, linked-worktree support, onboarding gates, contextual handoff markers that enforce commit/runtime/onboarding requirements before restore, and fixed-revision Codex review with independent model/context. Live second-machine acceptance, durable peer messaging, result import, and a future Claude adapter remain. See `docs/project-isolation-plan.md`. | H, phased | Preserve the user's IDEA checkout while enabling independent experiments and cross-machine work. |

### Selective synchronization design gate

The existing archive cannot safely be filtered by project. It hashes and
replaces the complete Codex state directory, including opaque/global SQLite
state, credentials, configuration, session history, and possible WAL/SHM
files. Filtering files or database rows without a supported Codex export/import
contract risks broken references and partial state.

The minimum safe design for Issue 44 is isolation rather than filtering:

1. Assign a project or named sync group to a complete state root.
2. Give that root its own handoff lock, baseline file, backup lifecycle, and
   remote snapshot namespace.
3. Launch the registered project with the matching state mounts.
4. Define migration and authentication/configuration duplication explicitly.
5. Test simultaneous use of different state groups on different machines.

This is doable without rewriting snapshot internals, but it requires broad
launcher, configuration, migration, documentation, and integration-test work.
True selective export/import from one shared Codex state remains a separate,
very-high-complexity design dependent on supported Codex schema semantics.
