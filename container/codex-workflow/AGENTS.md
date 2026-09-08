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

When an operation needs approval, make the approval question and any reusable
command prefix identify the substantive executable, action, and scope. Shell
setup such as `set -Eeuo pipefail`, environment assignments, or a generic shell
wrapper is not the operation being approved. Approval of such a prelude never
authorizes a later command, especially a destructive one; name the exact
destructive action and target in its own approval request.
