# Change Log

All notable changes to this project will be documented in this file.

This change log follows the conventions of
[keepachangelog.com](https://keepachangelog.com/).

## [Unreleased]

### Breaking

- Replaced the leading project-setting commands with
  `run-codex PROJECT --set KEY VALUE`.
- Host installations must keep `run-codex-doctor.bash` beside `run-codex` and
  `codex-sync-lib` beside `codex-push` and `codex-pull`.

### Added

- Added `run-codex PROJECT --image-version VERSION` for selecting an immutable
  image version while retaining `latest` as the default.
- Added project-scoped session listing and resume selection.
- Added focused snapshot recovery tests and dedicated IntelliJ integration
  documentation.

### Changed

- Dirty image inputs now receive identifiable `-dirty` versions and visibly
  warn when updating the convenient `latest` alias.
- Split launcher diagnostics, snapshot tests, and IntelliJ documentation into
  focused modules.

### Fixed

- Hardened runtime boundaries around AppArmor enforcement, image pulling,
  NVIDIA devices, nested namespace entry, workflow replacement, OCI source
  metadata, and LSP message parsing.
- Made CUDA sandbox failures preserve command output and status while providing
  actionable elevation guidance.
- Fixed snapshot argument handling, older forced recovery behind incomplete
  heads, and validation drift between push and pull.
- Fixed ACP relay readiness and lifecycle handling and synchronized session
  database reads with state handoffs.

## [0.5.5] - 2026-09-10

### Changed

- Updated the Codex CLI to 0.154.0.

## [0.5.4] - 2026-09-09

### Fixed

- Restored oneMKL native loading in persistent Clojure REPL sessions.

## [0.5.3] - 2026-09-09

### Changed

- Improved delegated-worker routing, evidence ownership, and resource use.
- Derived image versions from the nearest Git release tag.

### Fixed

- Made Clojure workflow locking SCI-compatible and corrected its smoke
  assertions.

## [0.5.2] - 2026-09-09

### Added

- Made worker inspection commands self-discovering.
- Improved selection and resumption of external Codex sessions.

## [0.5.1] - 2026-09-09

### Added

- Added durable, inspectable records for delegated worker commands.

## [0.5.0] - 2026-09-08

### Added

- Added the delegated Clojure development workflow and specialized agent
  roles.
- Added supervised persistent Clojure REPL lifecycle management.

## [0.4.2] - 2026-09-07

### Fixed

- Preserved Docker-authorized NVIDIA devices inside the nested CUDA sandbox
  and explained common CUDA initialization failures.

## [0.4.1] - 2026-09-06

### Changed

- Replaced inherited NSS loader state with a root-owned NSS module and added
  the runtime tools needed for interactive Clojure and IDEA cleanup.

### Fixed

- Corrected executable tmpfs and native-loader behavior for JVM and CUDA
  workloads running under arbitrary host identities.

## [0.4.0] - 2026-09-06

### Changed

- Made images portable across machines by storing a fixed non-root identity
  and applying the host UID/GID only when the container starts.

### Added

- Documented Codex-state handoff to a new machine.

## [0.3.0] - 2026-09-06

### Added

- Added the local-only `run-codex --doctor` environment diagnostic.
- Added automatic or explicit per-project Clojure MCP selection.
- Added validated forwarding for supported Codex launch options.

## [0.2.2] - 2026-09-06

### Fixed

- Fixed Clojure MCP startup inside the nested sandbox.

## [0.2.1] - 2026-09-06

### Changed

- Reordered image metadata layers to preserve expensive build cache across
  source revisions.
- Reorganized installation verification and semantic-tooling documentation.

## [0.2.0] - 2026-09-06

### Added

- Added native Clojure development tools and an editor-independent workflow
  guide.
- Added the private Unix-socket relay for hardened IntelliJ MCP access.

## [0.1.0] - 2026-09-05

### Added

- Added the initial generic and CUDA non-root Codex images, host launcher,
  AppArmor and seccomp policies, IntelliJ setup, transactional state handoff,
  and host smoke suite.
