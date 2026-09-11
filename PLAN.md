# Codex Universal Plan

This plan converts the findings in `review.md` and the subsequent runtime
probes into an ordered implementation backlog. Critical security-boundary work
comes first. Snapshot push/pull work is intentionally lower priority.

Evidence labels:

- `OPEN`: more evidence or a product decision is required.
- `DYNAMICALLY CONFIRMED`: reproduced with a runtime or disposable fixture.
- `SOURCE CONFIRMED`: established directly from the current source or docs.
- `REFUTED`: the reviewed claim did not hold under targeted testing.

Complexity is relative: `T` trivial, `L` contained, `M` multi-file or
test-heavy, and `H` architectural or integration-heavy.

## Tier 1 - Critical security and trust-boundary fixes

Work these items first. Within the tier, prefer contained fixes that close an
active bypass while the larger REPL and CUDA designs are developed.

| ID | Type | Work item | Evidence | Status | Complexity | Reason |
|---:|---|---|---|---|---|---|
| 1 | Security issue | Isolate the persistent Clojure REPL from external networking while preserving approved loopback nREPL access, preferably with a Unix socket or dedicated loopback-only namespace. | DYNAMICALLY CONFIRMED | Deferred; Cortex proved the bypass, but the safe fix requires cross-component nREPL transport work. | H | REPL evaluation currently bypasses Codex network approval. |
| 2 | Security issue | Require `CODEX_APPARMOR_PROFILE=codex-universal`; reject `unconfined`, `docker-default`, and arbitrary overrides. | DYNAMICALLY CONFIRMED | Implemented and focused-probe validated. | L | A caller could otherwise replace the intended host sandbox with a weaker profile. |
| 16 | Security issue | Strip or reject URL userinfo before placing a Git remote in `IMAGE_SOURCE`. | DYNAMICALLY CONFIRMED | Implemented and focused-probe validated. | L | Credentials can be persisted in image metadata. |
| 7 | Security issue | Preserve a fresh Bubblewrap `/dev` and bind only required NVIDIA device nodes in CUDA images. | DYNAMICALLY CONFIRMED | Implemented and argv-validated; blocked on rebuilt CUDA-image validation. | M-H | Binding all container devices weakens device isolation. |
| 22 | Security issue | Pin ACP, agent-lsp, and installer inputs and document the update process. | SOURCE CONFIRMED | Deferred; safe pins are unavailable in local evidence and no fetch will be attempted. | H | Moving dependencies weaken reproducibility and supply-chain review. |
| 43 | Security issue | Prevent dirty builds from updating the `latest` image alias. | DYNAMICALLY CONFIRMED | Implemented and focused-probe validated. | L | Unreviewed local changes can become the default runtime image. |
| 10 | Fix | Separate fake-Docker argv tests from genuine sandbox execution and report real-image checks accurately. | DYNAMICALLY CONFIRMED | Test claims corrected and real-image assertions added; blocked on rebuilt-image validation. | M | A green suite currently overstates security coverage. |
| 42 | Security issue | Require the installed AppArmor profile to be in enforce mode. | SOURCE CONFIRMED | Implemented and statically validated; blocked on host-policy installation validation. | L | A loaded complain-mode profile must not satisfy installation checks. |
| 27 | Security issue | Bound LSP frame sizes and handle missing, malformed, and non-ASCII headers without uncaught exceptions. | DYNAMICALLY CONFIRMED | Implemented and focused malformed-frame probes pass. | L | Untrusted protocol input can crash or stall the proxy. |
| 12 | Fix | Add `--pull=never` to the final interactive Docker session invocation. | DYNAMICALLY CONFIRMED | Implemented and focused-probe validated. | T | A local-only launch should never race into a registry pull. |

## Tier 2 - Near-term hardening and contained fixes

These changes improve current behavior but do not outrank the confirmed Tier 1
boundaries.

| ID | Type | Work item | Evidence | Status | Complexity | Reason |
|---:|---|---|---|---|---|---|
| 11 | Fix | Use `id -g` instead of `GROUPS[0]` for the runtime primary group. | SOURCE CONFIRMED | Unfixed; the single-group probe environment cannot expose the mismatch. | T | Container ownership should follow the actual primary group. |
| 8 | Fix | Make the image copy of `scripts/codex-worker-observe` executable and test its mode in real images. | SOURCE CONFIRMED | Implemented in both Dockerfiles with static and real-image assertions; blocked on rebuilt-image validation. | L | Image-local worker inspection otherwise fails at its documented path. |
| 17 | Fix | Allow an explicit image slug/version outside a Git checkout, or correct the documented contract. | DYNAMICALLY CONFIRMED | Unfixed; explicit values still failed outside Git. | L | Explicit configuration should behave as documented. |
| 41 | Fix | Replace the fixed ACP relay startup sleep with readiness or failure detection. | SOURCE CONFIRMED | Unfixed; full reproduction needs the container relay layout. | L | Delayed bind failures can be missed during startup. |
| 26 | Security issue | Decide and test whether the nested-userns filter must deny `setns`; keep the outer sandbox assumptions explicit. | SOURCE CONFIRMED | `setns` is not filtered; exploitability is not yet established. | M | Namespace re-entry deserves an explicit least-privilege decision. |
| 24 | Improvement | Constrain or remove the workflow-source override in production images. | DYNAMICALLY CONFIRMED | The override installs supplied content, but no checkout-controlled setter path was found. | M | Managed workflow replacement should have a narrow trust boundary. |
| 25 | Fix | Correct CUDA diagnostic process handling, accepted modes, and output capture. | SOURCE CONFIRMED | Unfixed; GPU-specific consequences remain untested. | M | Diagnostics must not race, leak helpers, or obscure command results. |
| 28 | Security issue | Review the ACP/LSP tool allowlist and justify mutating and command-execution methods. | OPEN | Required provider semantics remain undetermined. | M | Expose only the capabilities needed by the intended workflow. |

## Tier 3 - Backlog

Snapshot push/pull work is deliberately placed here. The current whole-state
handoff remains usable when operators stop sessions before synchronization;
security-boundary fixes above have priority.

| ID | Type | Work item | Evidence | Status | Complexity | Reason |
|---:|---|---|---|---|---|---|
| 4 | Fix | Let `codex-pull --force` recover when the live SQLite state is corrupt. | DYNAMICALLY CONFIRMED | Unfixed; live validation blocks recovery before extraction. | L | Forced restore should remain a recovery path. |
| 5 | Fix | Let an explicit older forced restore proceed while the newest generation is incomplete. | DYNAMICALLY CONFIRMED | Unfixed; `--force 1` was blocked by incomplete generation 2. | L | A half-synced head should not remove the recovery hatch. |
| 18 | Fix | Parse `codex-push` arguments and reject unknown options. | DYNAMICALLY CONFIRMED | Unfixed; `codex-push --help` published a snapshot. | L | A mistyped option must not mutate synchronized state. |
| 13 | Improvement | Make launcher lock waiting explicit or fail immediately with a useful message. | DYNAMICALLY CONFIRMED | Unfixed; the launcher blocked silently. | L | Operators need to distinguish lock contention from a hung launch. |
| 14 | Fix | Acquire the handoff lock before reading the session index. | DYNAMICALLY CONFIRMED | Unfixed; session SQLite was read while an exclusive lock was held. | M | Pull can otherwise replace state during session resolution. |
| 19 | Improvement | Share strict snapshot metadata validation between push and pull. | SOURCE CONFIRMED | Unfixed; validation logic can drift. | M | Both directions should reject the same malformed state. |
| 20 | Fix | Report failed rollback, retain useful recovery evidence, and clean restore temporary state deterministically. | SOURCE CONFIRMED | Unfixed; rollback failure is currently suppressed. | M | A failed restore must not leave state ownership ambiguous. |
| 21 | Improvement | Add snapshot failure-path tests for locking, incomplete generations, corruption, divergence, and rollback. | SOURCE CONFIRMED | Coverage gap remains. | M | Restore safety depends more on failure behavior than the happy path. |
| 35 | Improvement | Replace Seafile-specific success text with generic sync-directory wording. | DYNAMICALLY CONFIRMED | Unfixed wording mismatch. | T | The scripts support more than one file-sync provider. |
| 36 | Improvement | Document that snapshot listing is lock-free or take a consistent read lock. | SOURCE CONFIRMED | Lock-free behavior remains undocumented. | L | Users should understand transient `INVALID` list results. |
| 37 | Improvement | Confirm Codex database suffix and WAL/SHM behavior, then extend integrity handling if necessary. | OPEN | Actual Codex database lifecycle is unverified. | M | Snapshot validity depends on capturing complete database state. |
| 44 | New feature | Add optional per-project or per-sync-group state isolation: each group gets its own complete `CODEX_DIR`, lock, baseline, and snapshot namespace. Do not filter rows or files from the current global state archive. | OPEN | Feasible only as isolated state roots; not a small filter on existing snapshots. | H | Enables different projects to run on different machines concurrently without sharing one live global state tree. |
| 9 | Improvement | Correct portable UID/GID wording in `AGENTS.md`. | SOURCE CONFIRMED | Completed. | T | Contributor guidance should match the runtime identity design. |
| 34 | Fix | Correct the stale `run-codex.sh` comment. | SOURCE CONFIRMED | Unfixed typo. | T | Accurate names reduce maintenance confusion. |
| 38 | Improvement | Complete the launcher environment-variable help or link to the canonical list. | SOURCE CONFIRMED | Help omits supported variables. | L | Discoverable configuration reduces unsafe guesswork. |
| 39 | Improvement | Restore `nullglob` after local use. | SOURCE CONFIRMED | Unfixed; low practical impact. | T | Avoid leaking shell option state into later code. |
| 40 | Improvement | Add `.local-fixtures/` to tracked ignore rules and reconcile the unused `.env.example` exception. | SOURCE CONFIRMED | Completed; tracked ignore rule added while retaining the intentional example exception. | T | Disposable evidence should not be accidentally committed. |
| 29 | Improvement | Align `clojure_probe.toml` guidance with elevation, reuse, and unknown-state rules in the skill. | SOURCE CONFIRMED | Documentation gap remains. | L | Probe behavior should be consistent across entry points. |
| 30 | Improvement | Warn that alternate nREPL recipes bypass the managed workflow. | SOURCE CONFIRMED | Documentation gap remains. | L | Users should understand the isolation they give up. |
| 31 | Improvement | Align AGENTS, CONTRIBUTING, and smoke-test claims about syntax and real-image coverage. | SOURCE CONFIRMED | No-image limitations remain under-documented. | L-M | Validation claims must identify what was actually exercised. |
| 15 | Improvement | Decide whether IDEA-mode projects under `/tmp` need narrower reserved-path checks. | DYNAMICALLY CONFIRMED | The mount is accepted; no concrete exploit was demonstrated. | L | Avoid collisions only where a real runtime-path risk exists. |
| 33 | New feature | Support `.git` pointer worktrees/submodules or document the supported workaround. | SOURCE CONFIRMED | Unsupported today. | L docs; M-H support | Worktrees are a common development layout. |
| 23 | Improvement | Reduce generic/CUDA Dockerfile duplication and separately audit installed packages. | OPEN | Duplication exists; unused-package claims need image inspection. | H | Shared layers reduce profile drift and image maintenance cost. |
| 32 | Improvement | Split oversized launcher, test suite, and README after boundary fixes stabilize. | SOURCE CONFIRMED | Optional refactor. | H | Smaller modules reduce future review and regression cost. |

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

## Tier 4 - Explicitly refuted

Do not schedule the original claims as defects. Small defense-in-depth work may
be retained where stated.

| ID | Type | Work item | Evidence | Status | Complexity | Reason |
|---:|---|---|---|---|---|---|
| 3 | Improvement | Optionally add malicious-archive regression fixtures; do not treat the reported `../` escape as reproduced. | REFUTED | GNU tar 1.35 and `codex-pull` rejected the tested traversal and symlink vectors without changing live or outside state. | L for tests | A regression test can preserve current safe extraction behavior. |
| 6 | Improvement | Drop the claimed split-lock vulnerability; optionally retain a smaller task for consistent validation and unexpected `lsof` failures. | REFUTED | Canonical, `..`, and symlink spellings resolved to the same inode; relative lock paths are rejected by push/pull. | T-L | Avoid spending security effort on a path divergence that was not present. |
