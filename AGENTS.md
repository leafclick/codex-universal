# Repository guidance

These instructions apply to the entire repository.

## Project purpose

This repository builds non-root Docker environments for OpenAI Codex and provides host-side launch and state-synchronization commands:

- `Dockerfile.generic` and `Dockerfile.cuda` build the runtime images.
- `docker-build.sh` builds images with the invoking user's numeric UID/GID.
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
- Use Bash with `set -Eeuo pipefail`, quote path expansions, and use `--` before user-controlled path operands where supported.
- Treat paths derived from environment variables as untrusted configuration. Reject filesystem-root and unsafe overlapping paths before destructive operations.
- Keep generic and CUDA Dockerfiles behaviorally aligned unless a difference is CUDA-specific.
- Update README or focused documentation whenever commands, dependencies, defaults, or security behavior change.
- Never put credentials, Codex state, snapshots, local project registries, or `.env` files into the repository or Docker build context.
- Keep the host smoke suite local-only: it may inspect an existing Docker image, but it must not pull, build, or access the network.

## Validation

Run the smallest relevant checks during development and the full host suite before handoff:

```bash
bash -n docker-build.sh bin/run-codex bin/setup-codex-host-security bin/setup-codex-idea bin/codex-push bin/codex-pull container/codex-acp-entrypoint tests/host-smoke.sh
git diff --check
git diff --cached --check
./tests/host-smoke.sh
```

When changing a Dockerfile, build the affected image on a Docker host and rerun the suite so its real-image checks execute. When changing shared image behavior, validate both profiles when practical.

## Code review rules

- Report security-boundary regressions, destructive restore risks, state-loss paths, and staged/unstaged discrepancies before style concerns.
- Verify failure behavior as well as success behavior, especially locking, divergence, incomplete snapshots, checksum failures, and missing dependencies.
- Do not describe a Docker or sandbox property as tested if only its command-line arguments were inspected.
