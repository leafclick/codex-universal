# Host sandbox profiles

Codex uses Bubblewrap for its Linux command sandbox. Docker's default seccomp
and AppArmor policies intentionally block the namespace and mount operations
Bubblewrap needs, so `run-codex` uses the profiles in this directory.

`apparmor/codex-universal` is derived from Moby's `docker-default` profile at
commit `61eaf32614c7c71b60bd8927d3e6a4ffc8ff1f31`. It keeps the outer
restrictions and additionally permits unprivileged user namespaces and their
mount operations. Docker still drops every capability and enables
`no-new-privileges`. The image root filesystem is read-only; only the selected
project, persistent Codex/Maven state, and narrowly scoped runtime tmpfs mounts
are writable. Consequently, mount capabilities are unavailable in the
container's initial namespace; Bubblewrap can use them only inside the user
namespace it creates. Bubblewrap drops those namespaced capabilities before
executing a sandboxed command.

A transition from the outer profile into a more permissive Bubblewrap profile
is intentionally not used. AppArmor rejects that transition after Docker sets
`no-new-privileges`, because the target adds namespace and mount permissions.

`seccomp/codex-bwrap.json` is derived from Moby's default seccomp profile at
commit `61eaf32614c7c71b60bd8927d3e6a4ffc8ff1f31` under the Apache-2.0 license.
It adds only the `clone` form and namespace/mount syscalls needed during
Bubblewrap setup. The empty container capability set prevents those syscalls
from operating on the initial container namespace.

The repository is MIT-licensed by default, but the derived AppArmor and seccomp
profiles and local modifications remain Apache-2.0. Their concrete copyright,
source, and modification attribution is in
[`apparmor/NOTICE`](apparmor/NOTICE) and [`seccomp/NOTICE`](seccomp/NOTICE).
[`seccomp/LICENSE`](seccomp/LICENSE) is the unmodified canonical Apache-2.0
text governing both derivatives. The bracketed line in that license is part of
the license's explanatory appendix, not an attribution placeholder for this
repository.

Install and load the host policy with `bin/setup-codex-host-security`. Do not
replace these profiles with `--privileged`, added capabilities, or unconfined
seccomp/AppArmor modes.

At runtime there are two distinct network layers. Docker gives the outer
container its normal bridge network, while Codex starts unapproved commands in
a Bubblewrap network namespace with no external route. Approving a network
command reruns it outside Bubblewrap but still inside the restricted outer
container. Therefore a route table or resolver check launched by Codex shows
the intentionally isolated inner namespace; inspect the outer layer from the
host with `docker inspect` or `docker exec`.

The README's [manual approval-boundary
check](../README.md#manual-approval-boundary-check) verifies ordinary project
writes, canceled Git-metadata escalation, and approved network access through
either the terminal client or the IntelliJ ACP client.
