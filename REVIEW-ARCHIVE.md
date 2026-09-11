# Codex Universal Review Archive

This is the historical ledger for findings from `review.md` that have been
completed or refuted. See `PLAN.md` for the remaining deferred backlog,
`STATUS.md` for execution evidence and probe failures, and `CHANGELOG.md` for
the concise user-facing change history.

Evidence labels:

- `OPEN`: the item was completed by product decision or bounded local evidence,
  but its original broader evidence question was not fully resolved.
- `DYNAMICALLY CONFIRMED`: reproduced with a runtime or disposable fixture.
- `SOURCE CONFIRMED`: established directly from the current source or docs.
- `REFUTED`: the reviewed claim did not hold under targeted testing.

Complexity is relative: `T` trivial, `L` contained, `M` multi-file or
test-heavy, and `H` architectural or integration-heavy.

## Completed Tier 1 items

| ID | Type | Work item | Evidence | Resolution | Complexity | Reason |
|---:|---|---|---|---|---|---|
| 1 | Security issue | Isolate the persistent Clojure REPL from external networking while preserving approved local nREPL access through a private pathname Unix socket. | DYNAMICALLY CONFIRMED | Completed; the rebuilt image runs the service with `--unshare-net`, keeps TCP nREPL on private loopback, and exposes a mode-`0600` socket with bounded NIO transport and confirmed cleanup. Both the host fixture and Cortex JVM expose only `lo`; cross-command evaluation and retained state pass. | H | REPL evaluation must not bypass Codex network approval. |
| 2 | Security issue | Require `CODEX_APPARMOR_PROFILE=codex-universal`; reject `unconfined`, `docker-default`, and arbitrary overrides. | DYNAMICALLY CONFIRMED | Implemented and focused-probe validated. | L | A caller could otherwise replace the intended host sandbox with a weaker profile. |
| 16 | Security issue | Strip or reject URL userinfo before placing a Git remote in `IMAGE_SOURCE`. | DYNAMICALLY CONFIRMED | Implemented and focused-probe validated. | L | Credentials can be persisted in image metadata. |
| 7 | Security issue | Preserve a fresh Bubblewrap `/dev` and bind only required NVIDIA device nodes in CUDA images. | DYNAMICALLY CONFIRMED | Completed; the rebuilt CUDA command sandbox exposes only its minimal standard devices and the required NVIDIA character devices, with no host `/dev/dri`. | M-H | Binding all container devices weakens device isolation. |
| 22 | Security issue | Pin ACP, agent-lsp, and installer inputs and document the update process. | DYNAMICALLY CONFIRMED | Completed; the rebuilt CUDA image reports Leiningen `2.13.0`, its installed launcher metadata and JAR manifest agree, and the JAR retains its pinned checksum. All other configured tool versions, npm pins, installed workflow files, repository fingerprints, and `signed-by` paths were already verified. The approved-boundary local-only suite passes 25 named checks plus 13 embedded tests; Docker-host image-backed smoke remains optional corroboration. | H | Moving dependencies weaken reproducibility and supply-chain review. |
| 43 | Improvement | Make dirty-image publication explicit without removing the convenient `latest` alias. | DYNAMICALLY CONFIRMED | Completed by retaining identifiable `-dirty` tags, warning when dirty inputs update `latest`, supporting `TAG_LATEST=0`, and adding exact runner selection in Issue 46. | L | Operators should see the dirty-build risk while retaining the requested default alias workflow. |
| 10 | Fix | Separate fake-Docker argv tests from genuine sandbox execution and report real-image checks accurately. | DYNAMICALLY CONFIRMED | Completed; test claims were corrected and direct container `/proc` checks confirmed zero capabilities, `NoNewPrivs`, and enforcing AppArmor. | M | A green suite must not overstate security coverage. |
| 42 | Security issue | Require the installed AppArmor profile to be in enforce mode. | SOURCE CONFIRMED | Completed; the installer check is implemented and the resumed container reports `codex-universal (enforce)`. | L | A loaded complain-mode profile must not satisfy installation checks. |
| 27 | Security issue | Bound LSP frame sizes and handle missing, malformed, and non-ASCII headers without uncaught exceptions. | DYNAMICALLY CONFIRMED | Implemented and focused malformed-frame probes pass. | L | Untrusted protocol input can crash or stall the proxy. |
| 12 | Fix | Add `--pull=never` to the final interactive Docker session invocation. | DYNAMICALLY CONFIRMED | Implemented and focused-probe validated. | T | A local-only launch should never race into a registry pull. |

## Completed Tier 2 items

| ID | Type | Work item | Evidence | Resolution | Complexity | Reason |
|---:|---|---|---|---|---|---|
| 11 | Fix | Use `id -g` instead of `GROUPS[0]` for the runtime primary group. | SOURCE CONFIRMED | Completed with a focused source regression assertion. | T | Container ownership should follow the actual primary group. |
| 8 | Fix | Make the image copy of `scripts/codex-worker-observe` executable and test its mode in real images. | DYNAMICALLY CONFIRMED | Completed; the rebuilt CUDA image packages the observer at mode `0755`, and the installed file matches the working-tree source byte-for-byte. | L | Image-local worker inspection otherwise fails at its documented path. |
| 17 | Fix | Allow an explicit image slug/version outside a Git checkout, or correct the documented contract. | DYNAMICALLY CONFIRMED | Completed by documenting and testing the mandatory Git-provenance contract. | L | Explicit configuration must not imply that immutable provenance is optional. |
| 41 | Fix | Replace the fixed ACP relay startup sleep with readiness or failure detection. | DYNAMICALLY CONFIRMED | Completed; production-path probes confirm delayed failure stops ACP, the positive Unix-to-loopback relay exchanges data, and parent-death signaling terminates `socat`. | L | Delayed bind failures must stop ACP startup and the relay must not outlive ACP. |
| 47 | Fix | Correct the CUDA wrapper smoke assertion so per-device `/dev/nvidia*` binds are not mistaken for exposing the complete `/dev`. | DYNAMICALLY CONFIRMED | Completed; the assertion now matches only the exact whole-`/dev` bind pair, and a test-only no-device mode is narrowly gated to an overridden Bubblewrap executable. The approved-boundary no-image suite passes inside the container; Docker-host image checks remain separate. | T | The canonical suite must accept the hardened CUDA device layout it is intended to require. |
| 48 | Fix | Make the ACP delayed-failure fixture use the entrypoint's required relay socket root. | DYNAMICALLY CONFIRMED | Completed; Bubblewrap mounts the disposable fixture at `/run/codex-idea-mcp`, so the delayed-failure path is exercised without adding a production override. | L | The regression fixture must reach the behavior it claims to validate. |
| 26 | Security issue | Decide and test whether the nested-userns filter must deny `setns`; keep the outer sandbox assumptions explicit. | DYNAMICALLY CONFIRMED | Completed; the rebuilt filter returns `EPERM` from `setns`, while ordinary execution and thread creation remain allowed. | M | Namespace re-entry is unnecessary for the filtered Clojure/LSP children. |
| 24 | Improvement | Constrain or remove the workflow-source override in production images. | DYNAMICALLY CONFIRMED | Completed; production uses the immutable image path, while overrides require an explicit test flag and canonical `/tmp` source and target paths. | M | Managed workflow replacement should have a narrow trust boundary. |
| 25 | Fix | Correct CUDA diagnostic process handling, accepted modes, and output capture. | DYNAMICALLY CONFIRMED | Completed; the rebuilt wrapper reproduced the sandboxed CUDA-304 failure, preserved exit 5, and appended the explicit user-approved-elevation retry note after the complete test output. | M | Diagnostics must not race, leak helpers, or obscure command results. |
| 28 | Security issue | Review the ACP/LSP tool allowlist and justify mutating and command-execution methods. | OPEN | Completed from local evidence: broad `execute_command` and ambiguous `suggest_fixes` were removed; scoped edit tools remain behind user review. | M | Expose only the capabilities needed by the intended workflow. |
| 45 | Improvement | Replace the separate leading setters with project-first, Git-config-style `run-codex PROJECT --set KEY VALUE`. | SOURCE CONFIRMED | Completed for `profile` and `clojure-mcp`, with explicit unknown-key and arity errors; the obsolete leading forms were removed because there are no external callers. | M | Project placement and setting syntax should follow one predictable CLI convention. |
| 46 | Improvement | Add a one-session `--image-version VERSION` launcher option while retaining `latest` as the default. | SOURCE CONFIRMED | Implemented with Docker-tag validation, duplicate rejection, session-list conflict handling, and help/documentation coverage. | L | Operators need an explicit immutable-image escape hatch without changing the project profile or environment. |

## Completed Tier 3 items

| ID | Type | Work item | Evidence | Resolution | Complexity | Reason |
|---:|---|---|---|---|---|---|
| 9 | Improvement | Correct portable UID/GID wording in `AGENTS.md`. | SOURCE CONFIRMED | Completed. | T | Contributor guidance should match the runtime identity design. |
| 34 | Fix | Correct the stale `run-codex.sh` comment. | SOURCE CONFIRMED | Completed; the lock-coordination comment now names `run-codex`. | T | Accurate names reduce maintenance confusion. |
| 38 | Improvement | Complete the launcher environment-variable help or link to the canonical list. | SOURCE CONFIRMED | Completed; all supported user-facing launcher environment variables are listed and covered by the help test. | L | Discoverable configuration reduces unsafe guesswork. |
| 39 | Improvement | Restore `nullglob` after local use. | SOURCE CONFIRMED | Completed in the launcher and both snapshot commands with paired source assertions. | T | Avoid leaking shell option state into later code. |
| 40 | Improvement | Add `.local-fixtures/` to tracked ignore rules and reconcile the unused `.env.example` exception. | SOURCE CONFIRMED | Completed; tracked ignore rule added while retaining the intentional example exception. | T | Disposable evidence should not be accidentally committed. |
| 29 | Improvement | Align `clojure_probe.toml` guidance with managed transport, reuse, and unknown-state rules in the skill. | SOURCE CONFIRMED | Completed; the probe now requires the exact helper, private Unix transport, existing-service reuse, and no reconstructed sandbox or duplicate nREPL. | L | Probe behavior should be consistent across entry points. |
| 30 | Improvement | Warn that alternate nREPL recipes bypass the managed workflow. | SOURCE CONFIRMED | Completed; the alternate recipe is explicitly limited to environments without the bundled skill and lists the protections it omits. | L | Users should understand the isolation they give up. |
| 31 | Improvement | Align AGENTS, CONTRIBUTING, and smoke-test claims about syntax and real-image coverage. | SOURCE CONFIRMED | Completed; both contributor documents name the host suite as canonical and distinguish no-image checks from real-image coverage. | L-M | Validation claims must identify what was actually exercised. |
| 33 | New feature | Support `.git` pointer worktrees/submodules or document the supported workaround. | SOURCE CONFIRMED | Completed as documentation plus a rejection regression test; standalone full clones are the supported workaround because pointer metadata lies outside the project-only mount. | L docs; M-H support | Worktrees are common, but mounting parent Git metadata would widen the project boundary. |
| 32 | Improvement | Split oversized launcher, test suite, and README after boundary fixes stabilize. | SOURCE CONFIRMED | Completed with a sourced launcher doctor module, a standalone focused snapshot smoke suite, and a dedicated IntelliJ integration guide; each public entry point and behavior is preserved. | H | Smaller modules reduce future review and regression cost. |
| 5 | Fix | Let an explicit older forced restore proceed while the newest generation is incomplete. | DYNAMICALLY CONFIRMED | Completed; force mode validates only the requested generation, while a normal pull still rejects the incomplete head and recovery preserves the remote-head baseline. | L | A half-synced head should not remove the recovery hatch. |
| 18 | Fix | Parse `codex-push` arguments and reject unknown options. | DYNAMICALLY CONFIRMED | Completed; help and unknown options are handled before dependency checks, path creation, locking, or snapshot publication, with a non-mutation fixture. | L | A mistyped option must not mutate synchronized state. |
| 13 | Improvement | Make launcher lock waiting explicit or fail immediately with a useful message. | DYNAMICALLY CONFIRMED | Completed; a nonblocking probe reports the exact contended handoff lock before preserving the existing blocking behavior. | L | Operators need to distinguish lock contention from a hung launch. |
| 14 | Fix | Acquire the handoff lock before reading the session index. | DYNAMICALLY CONFIRMED | Completed; the shared lock is acquired after project resolution and before any session database read. | M | Pull can otherwise replace state during session resolution. |
| 19 | Improvement | Share strict snapshot metadata validation between push and pull. | DYNAMICALLY CONFIRMED | Completed with `codex-sync-lib`; both commands now share format, generation, content-hash, archive-name binding, archive presence, and checksum validation, and reject the same malformed marker fixture. | M | Both directions should reject the same malformed state. |
| 35 | Improvement | Replace Seafile-specific success text with generic sync-directory wording. | DYNAMICALLY CONFIRMED | Completed; success and handoff output now refer to synchronized generations and the configured sync provider. | T | The scripts support more than one file-sync provider. |
| 36 | Improvement | Document that snapshot listing is lock-free or take a consistent read lock. | SOURCE CONFIRMED | Completed; recovery documentation now explains transient `INVALID` results while a provider is still transferring snapshot files. | L | Users should understand transient `INVALID` list results. |

## Refuted review claims

These claims should not be scheduled as defects. The rows retain any optional
defense-in-depth work identified during verification.

| ID | Type | Work item | Evidence | Resolution | Complexity | Reason |
|---:|---|---|---|---|---|---|
| 3 | Improvement | Optionally add malicious-archive regression fixtures; do not treat the reported `../` escape as reproduced. | REFUTED | GNU tar 1.35 and `codex-pull` rejected the tested traversal and symlink vectors without changing live or outside state. | L for tests | A regression test can preserve current safe extraction behavior. |
| 15 | Improvement | Optionally reject exactly `/tmp` as an IDEA project root; do not treat arbitrary projects below `/tmp` as unsafe. | REFUTED | `/run` is already rejected; a `/tmp/PROJECT` bind targets only that child path, and no relay or tmpfs escape was demonstrated. Only the exact `/tmp` destination plausibly collides with the intended tmpfs. The ignored `.local-fixtures/cortex` checkout is not tracked by this repository and is unrelated to the mount claim. | T | Preserve a narrow defense-in-depth option without restricting ordinary disposable local checkouts. |
| 6 | Improvement | Drop the claimed split-lock vulnerability; optionally retain a smaller task for consistent validation and unexpected `lsof` failures. | REFUTED | Canonical, `..`, and symlink spellings resolved to the same inode; relative lock paths are rejected by push/pull. | T-L | Avoid spending security effort on a path divergence that was not present. |
