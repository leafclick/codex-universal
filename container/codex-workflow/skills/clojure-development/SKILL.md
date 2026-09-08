---
name: clojure-development
description: Develop and verify Clojure, Leiningen, or Babashka projects with configured runtimes, focused probes, and native tooling.
---

Use this skill for Clojure interactive development, runtime discovery, focused
REPL probes, linting, formatting, and tests. Read only the runtime reference
that applies; once the configured runtime kind is known, do not load references
for other runtime kinds. The project may provide `.codex/clojure-development.edn`; read
[the schema](references/schema.md) before using it. It is authoritative when
present. A persistent REPL requires an explicit recipe: aliases, profiles, and
JVM options cannot be selected safely from file presence or textual searches.
For a one-off Babashka probe, an explicit `:one-off` recipe is likewise the
reliable project interface.

When the file is absent, inspect root `AGENTS.md`, project README and developer
documents, `deps.edn`, `project.clj`, `bb.edn`, and relevant tool configuration
before asking for it. Read them to establish documented commands and profiles;
do not evaluate project forms merely to discover a runtime. Propose a concrete
argv recipe from an explicitly documented command, preserving aliases, JVM
options, and entry point. Identify only unresolved choices—such as two valid
development profiles or an undocumented nREPL dependency—and do not silently
select among them. Read [first-project setup](references/first-project.md) for
the proposal format.

Resolve `scripts/clojure-development` from this skill's installed directory,
independently of the project working directory. Use it for `repl-start [runtime]`, `repl-status`,
`repl-eval FORM`, `repl-stop`, and the explicit `one-off FORM [runtime]`
operation. It stores session data outside the checkout, verifies the actual
nREPL listener is loopback-only, serializes lifecycle and evaluations, bounds
display output, and reports a timeout as unknown execution state while
preserving partial and raw evidence. Stop and restart after unknown execution
state; never retry it blindly. A REPL is executable state, not a read-only
action.
The container entrypoint supplies the inherited private state directory and a
session-owned process service so the REPL survives separate tool-command
sandboxes. That service runs inside a nested Bubblewrap boundary with writable
working tree and caches, read-only `.git` and `.codex`, and no view of outer
container processes. Its inherited filter also denies nested user namespaces.
Do not invent a shared fallback or launch an unsandboxed owner outside that
environment. If the helper reports `:requires-elevation`, request execution of
the same absolute helper command in the container shell, preserving the
project workdir and inherited `CODEX_CLOJURE_STATE_DIR`. Name the helper action,
project, and container-loopback purpose in the approval request. This reuses
the session service; do not reconstruct entrypoint/Bubblewrap commands or
create another service. If your agent context cannot request approval, return
the exact command, workdir, inherited-state requirement and approval purpose
to the parent; the parent may request it and return its result. A rejection is
not authorization to try another path. If neither context can obtain approval,
retain the concrete failure and stop the affected runtime task.
`repl-status` reports process ownership separately from endpoint reachability;
an unchecked endpoint is not a dead runtime. `repl-stop` uses the control FIFO.
One-off Babashka does not use this TCP preflight. A rejected request was not
submitted; it says nothing about earlier in-flight or unknown evaluation state.

There is one active persistent runtime per chat. Share it only within one
parent-coordinated experiment; use task-specific Clojure namespaces for probes.
Serialize independent runtime tasks, and never stop or change another task's
runtime. Helpers reject another project's runtime or a changed eval recipe;
these guards do not isolate agents with shared filesystem access or distinguish
independent tasks in the same project. Do not create additional supervisors to
work around the one-runtime limit.

Semantic MCP is optional best-effort tooling; prefer it when healthy. Check the exposed
tool catalog and supported deferred discovery, if available, before concluding
that tools are absent; an MCP wire-harness result is not agent-tool discovery.
On `Transport closed`, stop retrying that MCP connection in the current client.
Retain obtained results and report incomplete semantic coverage to the primary.
Never automatically replay the interrupted request, including state-changing
requests. Use an available IDEA MCP provider with its exact project path;
otherwise use bounded `rg` and numbered source context, labeling text evidence
separately from semantic results. A fresh or resumed Codex process may establish
a new connection; neither that nor longer timeouts guarantees mid-session
recovery. This transport limitation alone does not invalidate working REPL or
runtime evidence. Use `rg` for literals, configuration and generated identifiers.
Use native `cljfmt`, `clj-kondo`, and `clojure-lsp` when appropriate. Before
interpreting probes, load the intended source into the correct namespace;
targeted evaluation suits straightforward function edits. Suspect stale state
for multimethod, protocol/type/record, generated Java/proxy or class-identity
changes; do not repeatedly patch around them live. Use documented lifecycle
procedures (including Integrant halt/reset/start), never invented commands or
an assumption that reset clears namespace, classloader or external state.
When uncertain, preserve useful forms/inputs, confirm cleanup, restart with the
same configured profile, reconstruct required application state and rerun the
smallest reproducer against the actual source. Mark earlier observations as
possibly stale; do not automatically replay side effects. Restart does not
undo external effects; report cleanup failures. If the problem persists fresh,
investigate implementation, dependencies or classloaders. Add durable tests
after behavior is confirmed against the intended implementation. Use a fresh
process for classpath/JVM-option/native-state changes and configured integration
commands. Stop task-owned REPLs and watchers before handoff.

Verify a persistent REPL and `clojure_probe` across commands: start the named
runtime, define a harmless unique sentinel in one probe, consume that retained
value in a separate probe, check that status reports the same running runtime,
then stop it and require confirmed termination. A configured project test is a
separate application-correctness check and is not required for this workflow
verification.

- For Clojure CLI, read [deps.md](references/deps.md).
- For Leiningen, read [leiningen.md](references/leiningen.md).
- For Babashka, read [babashka.md](references/babashka.md).
