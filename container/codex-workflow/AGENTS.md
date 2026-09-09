# Codex-universal routing

Delegate substantial read-heavy exploration to `code_reader`, substantial
Clojure runtime experiments and noisy result reduction to `clojure_probe`, and
clearly specified repetitive edits or deterministic validation to
`mechanical_worker`. The reader owns semantic queries, bounded source reads,
and corroborating searches for its delegated question. Consume its evidence;
repeat only targeted verification needed to integrate or challenge a finding.
After delegating an investigation, consume the worker's result rather than
repeating its searches or source reads. Independent work may continue meanwhile.
Keep architecture, probe design, ambiguous behavior, debugging conclusions,
integration, and final review in the primary agent. Small targeted operations
may stay local. Delegate when it avoids context or uses useful specialization,
including when the primary model is Luna. Request worker summaries rather than
raw intermediate output.

Keep delegation observable. Before a worker starts a substantial or
long-running command, it sends the parent a compact `START` update containing
its role, a unique run ID, working directory, exact command, and the stdout and
stderr paths. The parent promptly relays that update to the user. Run
non-interactive fresh-process probes through
`$CODEX_HOME/scripts/codex-worker-observe run RUN_ID -- COMMAND ...`; do not
wrap persistent `clojure-development` REPL operations, which already preserve
their own evaluation records. For a running command, report its PID and status
when available. At completion, send `EXIT` with the exit code, elapsed time,
and a concise stdout/stderr summary. Never expose credentials or other secrets
in commands, logs, or updates.

Treat `agent status`, `show active probes`, `show probe RUN_ID`, and
`tail probe RUN_ID` as inspection requests. The primary uses
`codex-worker-observe list`, `show`, and `tail` and reports the result without
interrupting the worker. A PID that is invisible from another tool sandbox is
not proof of exit; preserve the helper's `not-visible-or-exited` distinction.
Do not rely on experimental Codex features for worker observability.

When an operation needs approval, make the approval question and any reusable
command prefix identify the substantive executable, action, and scope. Shell
setup such as `set -Eeuo pipefail`, environment assignments, or a generic shell
wrapper is not the operation being approved. Approval of such a prelude never
authorizes a later command, especially a destructive one; name the exact
destructive action and target in its own approval request.
