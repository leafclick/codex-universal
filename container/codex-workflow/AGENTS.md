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
raw intermediate output. When the user explicitly authorizes a commit, the
primary owns the final diff review, commit scope, and message, then delegates
routine status, staging, and commit execution to `mechanical_worker`.

Optimize routing for estimated credits, elapsed time, and correct accepted
evidence rather than raw token count. Before spawning, give the worker an
exclusive evidence boundary and acceptance criteria. Until its result arrives,
the primary must not search, read, or query inside that boundary; continue only
with disjoint work. Consume the summary first and verify only a specific
uncertain, contradictory, or high-risk claim. If the result is inadequate,
reuse the same worker with a correction that relies on retained evidence before
starting a fresh investigation or taking the scope back locally. Batch related
questions known at dispatch time into one worker assignment with one compact
final summary; reserve follow-ups for genuinely new information or a specific
acceptance failure. Batch primary-side reads and checks into as few tool/model
turns as practical, bound tool output, and prefer one worker with related
questions over several overlapping workers. Semantic workers must validate
arguments against the exposed tool schema, set a small result limit for symbol
search, select the exact match before downstream queries, and prefer an exact
file position after discovery. Treat semantic MCP readiness as client-local.
When a session is likely to need substantial semantic work, initialize one
reader for the exact project root early with one bounded `start_lsp` call while
the primary continues disjoint work. Reuse that reader and its resident LSP across later
assignments, including after the reader becomes idle; do not restart it between
tasks. Do not pay this startup cost for an isolated lookup, and do not retry a
stalled start in that client. Restart only after concrete evidence that the
resident LSP is unhealthy. When reporting numerical aggregates, state the
formula or invariant and require components to reconcile with the reported
total.

Match semantic-provider lifecycle to the client. Terminal sessions use the
container-local Clojure LSP lifecycle above. IntelliJ ACP sessions reuse IDEA's
already-running project index and must not call `start_lsp`. If both read-only
providers are actually exposed, routine questions still use one provider; for
an ambiguous, incomplete, or high-risk claim, Luna readers may query both under
explicit provider-specific evidence boundaries and return a compact agreement
or discrepancy report. Treat this as deliberate corroboration, not permission
for the primary to repeat either investigation.

Once per Codex session, in the first user-visible response after acknowledging
the request, add this concise notice: `Worker inspection: ask "agent status" or
"show active probes"; run ~/.codex/scripts/codex-worker-observe help for every
command.` Do not repeat the notice later in the same session.

Keep delegation observable. Before spawning a worker expected to run a
substantial or long-running command, the primary assigns a unique run ID and
promptly announces the role, scope, run ID, and expected stdout/stderr paths to
the user. The worker uses that ID to run non-interactive fresh-process probes
through `~/.codex/scripts/codex-worker-observe run RUN_ID -- COMMAND ...`.
If direct parent messaging is available, the worker sends `START`, running
status, and `EXIT` updates; do not assume such messaging exists. The primary
uses the durable record to inspect and relay the exact command, cwd, PID,
status, exit code, and relevant stdout/stderr while the worker runs. Do not
wrap persistent `clojure-development` REPL operations, which already preserve
their own evaluation records. Never expose credentials or other secrets in
commands, logs, or updates.

Treat `agent status`, `show active probes`, `show probe RUN_ID`, `tail probe
RUN_ID`, and `worker inspection help` as inspection requests. The primary uses
the helper's `list`, `show`, `tail`, and `help` commands and reports the result
without interrupting the worker. After starting a long-running worker, inspect
its assigned record before entering an extended wait so its exact command and
status become visible even without child-to-parent messaging. A PID that is
invisible from another tool sandbox is not proof of exit; preserve the
helper's `not-visible-or-exited` distinction. Do not rely on experimental Codex
features for worker observability.

When an operation needs approval, make the approval question and any reusable
command prefix identify the substantive executable, action, and scope. Shell
setup such as `set -Eeuo pipefail`, environment assignments, or a generic shell
wrapper is not the operation being approved. Approval of such a prelude never
authorizes a later command, especially a destructive one; name the exact
destructive action and target in its own approval request.
