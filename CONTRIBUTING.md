# Contributing

Contributions should preserve the project's non-root runtime, explicit approval boundaries, and recoverable state handoff.

## Development setup

Use a Debian, Ubuntu, or comparable GNU/Linux host. Install the base requirements from the [README](README.md#host-requirements) and the synchronization dependencies from [docs/codex-sync.md](docs/codex-sync.md#install-required-software).

Install the host sandbox policy and commands, then build the relevant image as
described in the README. Run builds as the same non-root user who will run
Codex.

## Making changes

- Keep the generic and CUDA Dockerfiles aligned for shared packages and setup steps.
- Keep shell commands compatible with Bash and quote filesystem paths.
- Update user documentation when behavior, dependencies, environment variables, or defaults change.
- Do not weaken the Codex sandbox, approval policy, Docker capability restrictions, or state validation.
- Do not add secrets, live Codex state, generated snapshots, or local project registrations.

See [AGENTS.md](AGENTS.md) for the detailed repository invariants used by Codex and human reviewers.

## Testing

Run the host suite from the repository root:

```bash
./tests/host-smoke.sh
```

It does not require a host Codex installation or internet access. With the
documented synchronization tools installed, it exercises push/pull behavior
using temporary directories. When Docker and the default generic or CUDA
images are available, it validates each already-local image in a container
started with networking disabled. It does not pull or build images.

Stop all `codex-*` containers before running the complete suite. This is required because the synchronization commands refuse to operate while a Codex session is active. Use `CODEX_TEST_SKIP_SYNC=1` only for a reduced run that intentionally omits synchronization behavior.

If images use custom names:

```bash
CODEX_TEST_GENERIC_IMAGE=myorg/codex-universal-generic:latest \
CODEX_TEST_CUDA_IMAGE=myorg/codex-universal-cuda:latest \
  ./tests/host-smoke.sh
```

The CUDA image check uses `--gpus all` and requires the documented NVIDIA
driver and Container Toolkit. Set `CODEX_TEST_SKIP_CUDA=1` only when
intentionally running without that optional profile.

For focused shell changes, also run:

```bash
bash -n docker-build.sh bin/run-codex bin/setup-codex-host-security bin/setup-codex-idea bin/codex-push bin/codex-pull container/codex-acp-entrypoint tests/host-smoke.sh
git diff --check
git diff --cached --check
```

Dockerfile changes should be tested by building the affected profile. Changes shared by both Dockerfiles should be validated against both profiles when the necessary hardware is available.

## Submitting changes

Keep each change focused and explain its behavioral and security impact. Include the test commands run and identify anything that could not be tested locally. Before committing, inspect both `git diff` and `git diff --cached` so older staged content is not committed accidentally.

Security vulnerabilities should follow [SECURITY.md](SECURITY.md), not a public issue.
