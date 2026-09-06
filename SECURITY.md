# Security policy

## Supported versions

Security fixes target the current `master` branch and the latest tagged
release. Older pre-1.0 releases are not supported.

## Reporting a vulnerability

Do not disclose suspected vulnerabilities, credentials, session contents, or exploitable details in a public issue.

Use the repository's private **Report a vulnerability** option under the GitHub Security tab when it is available. If private reporting is unavailable, contact the `leafclick` organization privately through a published organization contact and include only enough information to establish a secure follow-up channel.

Include:

- the affected file and behavior;
- the expected security boundary;
- reproduction steps or a minimal proof of concept;
- potential impact;
- any known workaround.

## Security model

The project uses layered controls:

- Docker limits host filesystem and process exposure.
- Containers run with the invoking user's numeric UID/GID, all Linux capabilities dropped, and `no-new-privileges` enabled.
- Project-owned AppArmor and Docker-default-derived seccomp policies permit
  Bubblewrap namespace construction while Docker keeps the initial container
  capability set empty; the launcher verifies the real sandbox before each
  session.
- Codex uses `workspace-write`, disables command network access by default, and sends elevation requests to the human user.
- The image-level `/etc/codex/requirements.toml` prevents terminal and ACP clients from selecting automatic review, `never`, or `danger-full-access`.
- Git metadata and Codex configuration/state paths are protected from sandboxed command writes.
- State synchronization uses locking, immutable generations, checksums, content hashes, SQLite integrity checks, and recoverable replacement.

These controls do not make untrusted repositories or approved elevated commands harmless. Review approval requests carefully. Snapshot storage can contain credentials and session history and must be access-controlled and encrypted.
