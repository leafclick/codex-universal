# Codex Universal Plan

This file contains only unresolved work retained from `review.md` and the
subsequent runtime investigation. Completed and refuted findings are preserved
in `REVIEW-ARCHIVE.md`; current execution evidence and probe failures remain in
`STATUS.md`.

All remaining items are intentionally deferred. Snapshot push/pull work stays
lower priority than general runtime and security work.

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

## Deferred snapshot synchronization work

The current whole-state handoff remains usable when operators stop sessions
before synchronization. These items stay below general repository and
security-boundary work.

| ID | Type | Work item | Evidence | Status | Complexity | Reason |
|---:|---|---|---|---|---|---|
| 4 | Fix | Let `codex-pull --force` recover when the live SQLite state is corrupt. | DYNAMICALLY CONFIRMED | Deferred with snapshot synchronization work; live validation currently blocks recovery before extraction. | L | Forced restore should remain a recovery path. |
| 20 | Fix | Report failed rollback, retain useful recovery evidence, and clean restore temporary state deterministically. | SOURCE CONFIRMED | Deferred with snapshot synchronization work; rollback failure is currently suppressed. | M | A failed restore must not leave state ownership ambiguous. |
| 21 | Improvement | Add snapshot failure-path tests for locking, incomplete generations, corruption, divergence, and rollback. | SOURCE CONFIRMED | Deferred with snapshot synchronization work; the coverage gap remains. | M | Restore safety depends more on failure behavior than the happy path. |
| 37 | Improvement | Confirm Codex database suffix and WAL/SHM behavior, then extend integrity handling if necessary. | OPEN | Deferred with snapshot synchronization work; actual Codex database lifecycle is unverified. | M | Snapshot validity depends on capturing complete database state. |
| 44 | New feature | Add optional per-project or per-sync-group state isolation: each group gets its own complete `CODEX_DIR`, lock, baseline, and snapshot namespace. Do not filter rows or files from the current global state archive. | OPEN | Deferred with snapshot synchronization work; feasible only as isolated state roots, not a small filter on existing snapshots. | H | Enables different projects to run on different machines concurrently without sharing one live global state tree. |

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
