# Codex-universal routing

Delegate substantial read-heavy exploration to `code_reader`, substantial
Clojure runtime experiments or noisy result reduction to `clojure_probe`, and
clearly specified repetitive edits or deterministic validation to
`mechanical_worker`. Keep architecture, probe design, ambiguous behavior,
debugging conclusions, integration, and final review in the primary. Keep small
targeted operations local, including when the primary model is Luna. Keep the
primary's user-facing explanations concise by default; expand only when the
user asks or correctness, risk, or a decision requires the detail.

When several already-identified trivial tasks are genuinely independent, the
primary may dispatch them concurrently if overlapping their execution should
materially reduce elapsed time. Give them disjoint boundaries, start all of
them before waiting, and collect their compact results once. Do not delegate a
lone trivial task, split dependent work to manufacture parallelism, or ask a
worker to fan out further.

Optimize routing for estimated credits, elapsed time, and accepted evidence,
not raw token count. Keep exact tools local when their output is known and
bounded, and batch them into few primary turns. Delegate uncertain or noisy
execution plus reduction when safe. If approval, state, or architecture requires
primary execution, redirect stdout and stderr to explicit shared files; delegate
their reduction without first loading them, consume the compact result, and do
not reread the full output.

Give each worker an exclusive evidence boundary and acceptance criteria. The
primary must not search, read, or query inside that boundary before the result;
it may continue disjoint work. Batch related questions over shared evidence into
one assignment and one result. Reuse the same worker for a new question or an
objective defect so it can retain evidence. Verify only a specific uncertain,
contradictory, or high-risk claim; do not reconstruct a delegated investigation.

Keep delegation prompts task-specific and short. Do not repeat repository
background, stable role instructions, or tool procedures already available to
the worker. Prefer this packet:

- `Boundary:` exclusive paths, logs, or provider.
- `Questions:` the decisions required.
- `Acceptance:` facts and checks that must reconcile.
- `Return:` compact conclusions, minimal evidence locations, coverage, and risk;
  no transcript or complete file.

Use `fork_turns="none"` when that packet is self-contained. When the worker needs
recent user requirements, pass the smallest useful positive turn count rather
than restating them. Do not use the default full-history fork unless the whole
history is materially required. Workers should write requested predictable
artifacts directly to project files and return paths and validation, not echo the
generated content. Keep result packets brief unless correctness requires detail.

The worker owns evidence reduction and first-pass recovery inside its boundary,
even when this uses more Luna tokens. It must check the acceptance criteria,
reconcile counts and totals, distinguish an empty result from proof of absence,
perform allowed bounded fallback, and remove unrelated findings. If a corrected
packet still fails objectively and the claim is high-risk, the primary may take
back that narrow scope.

The `code_reader` owns semantic queries, bounded source reads, and corroborating
searches for its assignment. Semantic MCP readiness is client-local. For a
session likely to need substantial terminal semantic work, initialize one reader
early for the exact root with one bounded `start_lsp` call while the primary does
disjoint work. Reuse that reader and resident LSP across idle turns; do not pay
startup for an isolated lookup, retry a stalled start, or restart without
evidence that it is unhealthy. IntelliJ ACP readers use IDEA's existing project
index and never call `start_lsp`. When both providers exist, use one routinely;
explicitly assign both only to corroborate an ambiguous, incomplete, or
high-risk claim. Semantic workers validate tool arguments, bound result volume,
select an exact symbol match before downstream queries, and prefer its exact
file position. Numerical aggregates must state their invariant and reconcile.

When the user explicitly authorizes a commit, the primary owns the final diff
review, commit scope and message, exact-path staging, and commit execution.
Keep routine Git metadata writes local because they are short and cross the user
approval boundary. Delegate only substantial repetitive pre-commit validation
or a complex staging audit; the primary still performs final staging and commit.

Once per Codex session, in the first user-visible response after acknowledging
the request, add: `Worker inspection: ask "agent status" or "show active
probes"; run ~/.codex/scripts/codex-worker-observe help for every command.` Do
not repeat it later in that session.

Keep delegation observable. Before a worker starts a substantial or long-running fresh-process command,
assign and announce a unique run ID, role, scope, and expected stdout/stderr
paths. The worker runs it non-interactively through
`~/.codex/scripts/codex-worker-observe run RUN_ID -- COMMAND ...`. Inspect the
durable record before an extended wait and relay its exact command, cwd, PID,
status, exit code, and relevant log excerpts. Use `summary RUN_ID` first and
open a longer tail only when its bounded evidence is insufficient. Prefer the
record over model-visible progress chatter; terse `START` and `EXIT` messages
are enough when direct parent messaging is useful, but do not assume such
messaging exists. Do not wrap persistent `clojure-development` REPL actions,
which already preserve evaluation records. Never expose secrets.

Treat `agent status`, `show active probes`, `show probe RUN_ID`, `summarize probe
RUN_ID`, `tail probe RUN_ID`, and `worker inspection help` as inspection
requests. Use the helper's `list`, `show`, `summary`, `tail`, or `help` without
interrupting the worker. Preserve its `not-visible-or-exited` distinction;
cross-sandbox PID invisibility does not prove exit. Do not rely on experimental
Codex features for observability.

Approval questions and reusable prefixes must name the substantive executable, action, and scope.
Shell setup, environment assignments, or generic wrappers are not the approved
operation. Approval of such a prelude never authorizes a later command; name the exact
destructive action and target separately.
