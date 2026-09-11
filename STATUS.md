# Codex Universal Work Status

Last updated: 2026-09-11

`PLAN.md` is the source of scope, ordering, complexity, and rationale. This file
tracks execution. Update an item's state when work starts or finishes, link its
validation evidence, and append a short entry to the work log.

Allowed states are `NOT STARTED`, `IN PROGRESS`, `DEFERRED`, `BLOCKED`, `DONE`,
and `DISMISSED`. Mark an item `DONE` only after the relevant focused checks pass;
security and image-boundary changes also require the applicable real-image or
runtime validation.

## Summary

| Tier | Items | Done | In progress | Remaining | Reason |
|---|---:|---:|---:|---:|---|
| Tier 1 | 10 | 5 | 0 | 5 | Issues 2, 12, 16, 27, and 43 are done; Issues 7, 10, and 42 await image/host validation; Issues 1 and 22 are deferred. |
| Tier 2 | 8 | 0 | 0 | 8 | Issue 8 is implemented but awaits rebuilt-image validation; the remaining hardening stays queued. |
| Tier 3 | 24 | 2 | 0 | 22 | Issues 9 and 40 are complete; lower-priority sync, feature, docs, and maintenance work remains queued. |
| Tier 4 | 2 | 0 | 0 | 0 | Two original claims were dismissed after targeted refutation. |

Evidence baseline: 17 dynamically confirmed, 21 source confirmed, 4 open, and
2 refuted items. There are 42 active planned items and 2 dismissed claims.

## Item tracker

| ID | Tier | State | Evidence | Next action | Reason |
|---:|---:|---|---|---|---|
| 1 | 1 | DEFERRED | Cortex REPL connected to `1.1.1.1:443`; raw nREPL record retained under `/tmp/codex-clojure.I33snR/`. Architecture review found that container-wide `--network none` would also remove approved network access. | Implement Unix-socket nREPL plumbing or an equivalent private loopback-only namespace in a dedicated pass. | Confirmed approval-boundary bypass requires a cross-component transport change. |
| 2 | 1 | DONE | Launcher now requires `codex-universal`; focused disposable probes reject `unconfined`, `docker-default`, and arbitrary overrides. | Recheck in the rebuilt image-backed host suite. | Confirmed sandbox-profile substitution is closed at argument construction. |
| 7 | 1 | BLOCKED | CUDA wrapper now preserves fresh `/dev` and adds only existing `/dev/nvidia*` character devices/directories; focused argv probe passes. | Rebuild CUDA image and run real GPU/device checks. | Image behavior cannot be claimed without a CUDA host run. |
| 10 | 1 | BLOCKED | Fake-Docker security PASS assertion was removed; real-image `CapEff`, `NoNewPrivs`, and AppArmor checks were added. | Rebuild images and run the real-image smoke path. | Kernel properties require a real container. |
| 12 | 1 | DONE | Final session argv now contains `--pull=never`; focused probe passes. | Recheck in the rebuilt host suite. | Prevent unintended registry access. |
| 16 | 1 | DONE | Git URL userinfo is removed before `IMAGE_SOURCE`; dummy-credential probe passes. | Recheck build fixture after rebuild if desired. | Prevent credential persistence. |
| 22 | 1 | DEFERRED | Floating versions found in build/install inputs; safe concrete pins are not available in local evidence. | Choose pins and an update workflow in a later pass without using gated resources. | Reduce supply-chain drift without guessing dependency versions. |
| 27 | 1 | DONE | Proxy now bounds headers/bodies and handles malformed, missing, non-ASCII, and oversized frames without traceback; focused probes pass. | Recheck in the rebuilt image. | Prevent protocol-input crashes. |
| 42 | 1 | BLOCKED | Installer now requires `codex-universal (enforce)` and the source assertion passes. | Run host security setup and inspect the host AppArmor profile after rebuild. | Host enforcement cannot be proven inside this container. |
| 43 | 1 | DONE | Dirty Git-derived builds no longer add the `latest` alias; focused build probe passes. | Recheck the build fixture after rebuild. | Protect the default image tag. |
| 8 | 2 | BLOCKED | Both Dockerfiles mark bundled workflow scripts executable and the smoke suite now asserts the source and image modes. | Rebuild generic and CUDA images and run real-image checks. | Image file mode requires rebuilt-image evidence. |
| 11 | 2 | NOT STARTED | Launcher uses `GROUPS[0]`. | Replace with `id -g` and test group selection. | Match primary group ownership. |
| 17 | 2 | NOT STARTED | Explicit-version build failed outside Git. | Fix behavior or docs and add a fixture. | Honor documented configuration. |
| 24 | 2 | NOT STARTED | Explicit workflow override installed supplied content. | Decide production override policy. | Narrow managed-content trust. |
| 25 | 2 | NOT STARTED | CUDA wrapper process/output paths inspected. | Add deterministic failure-capture tests, then GPU validation. | Make diagnostics reliable. |
| 26 | 2 | NOT STARTED | `setns` is absent from the inner seccomp filter. | Establish threat model and add a focused namespace test. | Make namespace policy explicit. |
| 28 | 2 | NOT STARTED | Tool allowlist inspected; provider semantics unknown. | Confirm required methods before reducing access. | Preserve least privilege without breaking workflows. |
| 41 | 2 | NOT STARTED | Fixed `sleep 0.05` startup check inspected. | Replace with readiness detection and delayed-failure test. | Close relay startup race. |
| 4 | 3 | NOT STARTED | Forced restore failed on corrupt live SQLite. | Skip or warn on live DB checks in force mode. | Restore the recovery hatch. |
| 5 | 3 | NOT STARTED | Older force restore failed behind incomplete head. | Validate only the requested generation in force mode. | Allow recovery during partial synchronization. |
| 9 | 3 | DONE | `AGENTS.md` now describes portable fixed-identity images and runtime UID/GID replacement consistently with README. | None. | Keep contributor guidance accurate. |
| 13 | 3 | NOT STARTED | Launcher timed out silently on an exclusive handoff lock. | Choose nonblocking error or waiting message. | Improve operator diagnosis. |
| 14 | 3 | NOT STARTED | Session listing succeeded under an exclusive handoff lock. | Move lock acquisition before session DB access. | Avoid state-replacement race. |
| 15 | 3 | NOT STARTED | IDEA accepted a project below `/tmp`; impact unproven. | Define exact unsafe overlap cases before changing validation. | Avoid speculative path restrictions. |
| 18 | 3 | NOT STARTED | `codex-push --help` published generation 1. | Add argument parser and mutation tests. | Prevent accidental snapshots. |
| 19 | 3 | NOT STARTED | Push/pull validators differ. | Extract shared validation logic with fixtures. | Prevent validation drift. |
| 20 | 3 | NOT STARTED | Rollback failure is suppressed in source. | Design failure recovery and retained evidence. | Avoid ambiguous live state. |
| 21 | 3 | NOT STARTED | Failure scenarios are absent from the sync suite. | Add focused local-only cases. | Verify restore failure safety. |
| 23 | 3 | NOT STARTED | Dockerfile duplication visible; package claim open. | Measure normalized diff and inspect a real image. | Scope refactor with evidence. |
| 29 | 3 | NOT STARTED | Probe config and skill guidance differ. | Align documentation. | Make worker behavior consistent. |
| 30 | 3 | NOT STARTED | Alternate recipe warning is absent. | Add warning near the example. | Clarify lost managed isolation. |
| 31 | 3 | NOT STARTED | Validation claims differ across docs. | Establish one canonical validation matrix. | Prevent false assurance. |
| 32 | 3 | NOT STARTED | Large duplicated modules identified. | Refactor only after boundary changes settle. | Avoid churn during security work. |
| 33 | 3 | NOT STARTED | `.git` pointer files are explicitly rejected. | Document workaround or design safe support. | Support common worktree usage. |
| 34 | 3 | NOT STARTED | Stale command name found in comment. | Correct wording. | Remove minor confusion. |
| 35 | 3 | NOT STARTED | Seafile-specific success output reproduced. | Use provider-neutral wording. | Match supported sync providers. |
| 36 | 3 | NOT STARTED | `--list` returns before lock acquisition. | Document or lock list reads. | Explain transient invalid results. |
| 37 | 3 | NOT STARTED | Codex DB suffix/WAL behavior remains unknown. | Confirm actual runtime database lifecycle. | Avoid incomplete database snapshots. |
| 38 | 3 | NOT STARTED | Help omits honored variables. | Complete or link the environment list. | Improve configuration discoverability. |
| 39 | 3 | NOT STARTED | `nullglob` is left enabled. | Restore shell state locally. | Reduce hidden coupling. |
| 40 | 3 | DONE | `.local-fixtures/` is now ignored by the tracked repository rules; the intentional `.env.example` exception remains available for a future example file. | None. | Prevent accidental local-artifact commits. |
| 44 | 3 | NOT STARTED | Architecture audit found global opaque state cannot be safely filtered. | Design isolated per-project/sync-group state roots and migration. | Enable safe cross-machine project concurrency. |
| 3 | 4 | DISMISSED | GNU tar and `codex-pull` rejected tested traversal and symlink escapes. | Optionally add regression fixtures only. | Original vulnerability was not reproduced. |
| 6 | 4 | DISMISSED | Lock path spellings resolved to the same inode; relative paths are rejected. | Optionally split out `lsof` error handling. | Original split-lock claim was not reproduced. |

## Work log

| Date | Change | Validation | Reason |
|---|---|---|---|
| 2026-09-11 | Finished the current tranche: implemented Issues 2, 7, 8, 10, 12, 16, 27, 42, and 43; completed Issues 9 and 40; deferred Issues 1 and 22. | Focused disposable security probes pass for Issues 2, 7, 12, 16, 27, and 43; syntax/static/whitespace checks pass. The host suite passed 18 Python tests, then stopped at the known current-container nREPL/Bubblewrap namespace failure before image checks. Issues 7, 8, 10, and 42 await image or host validation. | Pause at a clean handoff point for image rebuild and a new container. |
| 2026-09-11 | Completed Issue 40 by adding `.local-fixtures/` to `.gitignore`. | `git check-ignore .local-fixtures/probe` passes. | Prevent disposable fixtures from appearing as commit candidates on every checkout. |
| 2026-09-11 | Deferred Issue 22 without changing dependency versions. | No network or gated-resource lookup was performed. | Concrete pins are safer than guessed versions; follow the user's no-fetch direction. |
| 2026-09-11 | Completed Issue 9 by correcting the image/runtime identity description in `AGENTS.md`. | Wording checked against the existing README identity description. | Remove a misleading contributor instruction without waiting on code changes. |
| 2026-09-11 | Started Issue 8 by aligning executable workflow-script modes in both Dockerfiles. | Source assertions pass; rebuilt-image mode validation remains pending. | Take a contained disjoint fix while Tier 1 test ownership is active elsewhere. |
| 2026-09-11 | Deferred Issue 1 after architecture review. A container-wide `--network none` change was rejected because it would disable approved network operations; safe isolation requires Unix-socket nREPL plumbing or an equivalent private namespace. | Cortex exploit probe remains valid; no Issue 1 source change was made. | Follow the user's direction to skip work that would stall the remaining contained fixes. |
| 2026-09-11 | Started Tier 1 implementation for Issues 1, 2, 7, 10, 12, 16, 27, 42, and 43. Issue 22 remains queued behind the contained fixes because pin selection needs an explicit dependency-update policy. | Work boundaries assigned; validation pending. | Close confirmed security bypasses before lower-priority sync and maintenance work. |
| 2026-09-11 | Established plan and status baseline from `review.md`, source audit, disposable host fixtures, and the Cortex persistent-REPL probe. No runtime fixes applied yet. | Targeted probe run completed; Cortex REPL was stopped with confirmed termination; full host suite was incomplete because the local nREPL supervisor failed before image checks. | Preserve a verified starting point before implementation. |
