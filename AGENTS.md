# Repository guidance

These instructions apply to the entire repository.

## Project purpose

This repository builds non-root Docker environments for OpenAI Codex and provides host-side launch and state-synchronization commands:

- `Dockerfile.generic` and `Dockerfile.cuda` build the runtime images.
- `docker-build.sh` builds portable fixed-identity non-root images;
  `run-codex` replaces that identity with the invoking user's numeric UID/GID
  when a container starts.
- `bin/run-codex` manages project registration and starts Codex containers.
- `bin/setup-codex-host-security` installs the host AppArmor and seccomp policy.
- `bin/setup-codex-idea` adds registered projects to JetBrains ACP configuration.
- `bin/codex-push` and `bin/codex-pull` exchange immutable Codex-state snapshots.
- `tests/host-smoke.sh` is the host-native regression suite.

## Invariants

- Keep image builds and runtime containers non-root. Never silently substitute UID or GID 0.
- Give every image a Git-derived immutable version tag and OCI version, revision, and source labels; keep `latest` only as a convenience alias.
- Keep Codex in `workspace-write` with `on-request` approval and the reviewer set to `user`.
- Do not introduce `danger-full-access`, `approval_policy = "never"`, `--yolo`, `--privileged`, `CODEX_UNSAFE_ALLOW_NO_SANDBOX`, or equivalent bypasses.
- Preserve the approval boundary around Git metadata, network access, and writes outside configured writable roots.
- Preserve Docker hardening with all capabilities dropped and `no-new-privileges` enabled.
- Keep live `~/.codex` state separate from synchronized snapshots.
- Snapshot publication is forward-only and transactional: archive first, checksum second, `.state` marker last.
- Pull must validate the archive, restored state hash, and SQLite databases before replacing live state, and must retain the prior live directory as a backup.
- `run-codex`, `codex-push`, and `codex-pull` must continue to coordinate through the same lock file.

## Working practices

- Preserve unrelated user changes and inspect both staged and unstaged diffs before editing.
- Do not stage, commit, push, or rewrite Git history unless the user explicitly requests it.
- Prefer available language-aware MCP tools over `rg`, `grep`, or `sed` for
  definitions, references, symbol documentation, diagnostics, and call
  relationships. In terminal Clojure sessions use the `clojure_lsp` tools; in
  IntelliJ ACP sessions use the read-only `mcp__idea__` tools and pass the
  session's exact `pwd` as `projectPath` without rewriting it to `/workspace`.
- Use `rg` for literal text, filenames, configuration, generated identifiers,
  or when semantic tooling is unavailable. Use `sed` only to display a known
  file range, not as a substitute for symbol navigation. If a semantic
  operation is unsupported, say so before falling back; do not infer that a
  symbol has no references or callers.
- During investigation, prefer read-only MCP operations. Use formatting,
  rename, refactoring, or other write-capable semantic tools only when the
  requested task authorizes working-tree changes, and inspect their diff.
- Use Bash with `set -Eeuo pipefail`, quote path expansions, and use `--` before user-controlled path operands where supported.
- Treat paths derived from environment variables as untrusted configuration. Reject filesystem-root and unsafe overlapping paths before destructive operations.
- Keep generic and CUDA Dockerfiles behaviorally aligned unless a difference is CUDA-specific.
- Update README or focused documentation whenever commands, dependencies, defaults, or security behavior change.
- Never put credentials, Codex state, snapshots, local project registries, or `.env` files into the repository or Docker build context.
- Keep the host smoke suite local-only: it may inspect an existing Docker image, but it must not pull, build, or access the network.

## Validation

The canonical validation command is the host smoke suite. Run it from the
repository root during development and before handoff:

```bash
./tests/host-smoke.sh
```

The suite always performs syntax, whitespace, launcher-argument, and static
profile checks. Without a locally available Docker image and daemon, those
checks do not exercise image contents, the Clojure-helper runtime, or runtime
hardening. Clojure-helper lifecycle checks use the pinned Babashka inside each
tested image rather than a host installation; real-image coverage is limited
to the profiles that are already local. Set
`CODEX_TEST_SKIP_IMAGE=1` to make that no-image boundary explicit.

When changing a Dockerfile, build the affected image on a Docker host and rerun the suite so its real-image checks execute. When changing shared image behavior, validate both profiles when practical.

## Code review rules

- Report security-boundary regressions, destructive restore risks, state-loss paths, and staged/unstaged discrepancies before style concerns.
- Verify failure behavior as well as success behavior, especially locking, divergence, incomplete snapshots, checksum failures, and missing dependencies.
- Do not describe a Docker or sandbox property as tested if only its command-line arguments were inspected.
