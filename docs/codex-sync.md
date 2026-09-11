# Codex state synchronization

`codex-push` and `codex-pull` safely hand off Codex state between development machines through a file-synchronized directory. They are host commands: run them outside the Codex container.

## Why snapshots are necessary

Do not synchronize the live `~/.codex` directory with Seafile, Dropbox, Syncthing, or similar software. Codex state can contain SQLite databases and WAL files. A synchronization client copying those files while Codex is running can produce an inconsistent state on another machine.

The scripts instead exchange immutable snapshots:

```text
live ~/.codex
      |
      | codex-push
      v
compressed snapshot + checksum + state marker
      |
      | file synchronization service
      v
codex-pull
      |
      v
live ~/.codex on another machine
```

Only one machine should actively modify the shared Codex state at a time.

## Install required software

The synchronization commands require Bash and standard GNU/Linux utilities.
The complete host tool set below also includes `jq` and `sqlite3`, which are
used by `run-codex` session listing and selection. `jq` is also used by the
optional `setup-codex-idea` command. On Debian, Ubuntu, and related
distributions, install them with:

```bash
sudo apt-get update
sudo apt-get install \
  bash \
  coreutils \
  findutils \
  gawk \
  grep \
  hostname \
  jq \
  lsof \
  sqlite3 \
  tar \
  util-linux \
  zstd
```

Important package-to-command mappings include:

| Package | Commands used |
| --- | --- |
| `coreutils` | `sha256sum`, `realpath`, `basename`, `date`, `mktemp`, `sync` |
| `findutils` | `find` |
| `gawk` | `awk` |
| `jq` | `jq` for `run-codex` session selection and `setup-codex-idea` |
| `lsof` | `lsof` |
| `sqlite3` | `sqlite3` for Codex session selection and snapshot validation |
| `tar` | GNU `tar` |
| `util-linux` | `flock` |
| `zstd` | `zstd` |

Docker is optional for the synchronization scripts themselves. When Docker is installed, the scripts also check for running containers whose names begin with `codex-`.

Install the commands into the user executable path if this has not already been done:

```bash
mkdir -p ~/.local/bin
install -m 700 bin/codex-push ~/.local/bin/codex-push
install -m 700 bin/codex-pull ~/.local/bin/codex-pull
install -m 600 bin/codex-sync-lib ~/.local/bin/codex-sync-lib
```

Keep `codex-sync-lib` beside both commands. It is their shared validation
module, not a standalone command.

## Configure the snapshot directory

The default snapshot directory is:

```text
~/Seafile/CodexSync
```

When using Seafile, put this directory in an encrypted Seafile library protected by a strong, unique password. Keep that password outside this repository and separate from the synchronized snapshots.

Create it inside the locally synchronized folder for the chosen file synchronization service. Override the default when necessary:

```bash
export CODEX_SYNC_DIR="$HOME/path/to/synchronized/CodexSync"
```

Use the same logical synchronized directory on every machine. Its absolute local path may differ.

Supported environment variables are:

| Variable | Default | Purpose |
| --- | --- | --- |
| `CODEX_DIR` | `~/.codex` | Live Codex state directory |
| `CODEX_SYNC_DIR` | `~/Seafile/CodexSync` | Directory containing immutable snapshots |
| `CODEX_LOCK_FILE` | `~/.cache/codex-handoff.lock` | Lock shared with `run-codex` |
| `XDG_STATE_HOME` | `~/.local/state` | Parent of the local `codex-handoff/base.state` baseline |

Put persistent overrides in the appropriate shell startup file on each machine.
All configured paths must be absolute. The live state, snapshot directory,
local baseline directory, and lock file must be separate and must not overlap;
the commands reject unsafe layouts before creating or replacing files.

## Initial publication

On the machine whose current Codex state should become authoritative:

1. Exit every Codex session and container.
2. Publish the first snapshot:

   ```bash
   codex-push
   ```

3. Wait until the file synchronization service reports that all snapshot files have reached the other machine.

The first snapshot is generation 1. Each later push containing changes creates the next generation.

## Adopt state on another machine

On a machine with no local synchronization baseline, inspect the available snapshots:

```bash
mkdir -p ~/.codex
codex-pull --list
```

If the newest generation is 1 and it should replace the local `~/.codex`, adopt it explicitly:

```bash
codex-pull --force 1
```

The forced pull preserves the existing directory under a sibling name such as:

```text
~/.codex.backup-20260905T113621Z-39cd1569
```

After this initial adoption, use normal forward pulls.

## Routine handoff

On machine A:

```bash
# Exit all Codex sessions and containers first.
codex-push
```

Wait for the synchronization service to finish. Then, on machine B:

```bash
codex-pull
run-codex PROJECT
```

Before switching back, exit Codex on machine B, push there, wait for synchronization, and pull on machine A.

Repeated pushes and pulls are no-ops when nothing changed. Normal operation is forward-only. If the remote generation advanced while local state also changed, the scripts report divergence instead of choosing a side or overwriting data.

## Recovery

List recovery points and their archive status:

```bash
codex-pull --list
```

Snapshot listing is intentionally lock-free and does not wait for a local push
or pull. While a sync provider is still transferring an archive, checksum, or
state marker, an in-flight generation can therefore appear temporarily as
`INVALID`. Wait for synchronization to finish and run `codex-pull --list`
again before treating that result as corruption or selecting a recovery point.

Restore a known-good generation:

```bash
codex-pull --force 37
```

The command verifies the compressed archive checksum, extracts into a temporary sibling directory, verifies the restored state hash and SQLite databases, and only then replaces `~/.codex`. The previous live directory is retained as a timestamped backup.

After restoring an older generation, publish the recovered contents:

```bash
codex-push
```

They become a new generation after the current remote head. For example, restoring generation 37 when the remote head is 42 produces generation 43 on the next push. History never moves backwards.

## Locking and consistency

`run-codex` holds a shared lock at:

```text
~/.cache/codex-handoff.lock
```

This permits several `run-codex` projects to run concurrently. Push and pull acquire the same lock exclusively, so they refuse to proceed while a launcher holds it or another synchronization operation is active.

The scripts also refuse to proceed when they detect open files below
`~/.codex` or running Docker containers named `codex-*`. When containers are
the blocker, each offending container name is printed before the command
exits. The exclusive lock remains authoritative and also catches a Codex
session that is starting or a concurrent push/pull. Always exit Codex cleanly
before a handoff.

Each snapshot consists of three files:

```text
codex-gNNNNNNNN-....tar.zst
codex-gNNNNNNNN-....tar.zst.sha256
codex-gNNNNNNNN-....tar.zst.state
```

The `.state` file is published last and acts as the generation commit marker. Do not edit snapshot files manually.

## Security

Codex state can include session history and authentication material such as `auth.json`. Store snapshots only in an appropriately access-controlled and encrypted location. For Seafile, use an encrypted library protected by a strong, unique password. Anyone who can read the snapshot archive may be able to recover those credentials and transcripts.
