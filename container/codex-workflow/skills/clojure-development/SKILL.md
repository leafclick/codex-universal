---
name: clojure-development
description: Develop and verify Clojure, Leiningen, or Babashka projects with configured runtimes, focused probes, and native tooling.
---

Use this skill for Clojure interactive development, runtime discovery, focused
REPL probes, linting, formatting, and tests. Read only the runtime reference
that applies. The project may provide `.codex/clojure-development.edn`; read
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

Use `scripts/clojure-development` for `repl-start [runtime]`, `repl-status`,
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
environment.

Prefer active semantic MCP tooling for semantic questions, using `rg` for
literals, configuration, generated identifiers, or a documented fallback.
Use native `cljfmt`, `clj-kondo`, and `clojure-lsp` when appropriate. Develop
with focused probes; add durable tests only after behavior is stable. Use a
fresh process for classpath/JVM-option/native-state changes and always use a
configured integration command fresh. Stop REPLs and watchers started for the
task before handoff.

Verify a persistent REPL and `clojure_probe` across commands: start the named
runtime, define a harmless unique sentinel in one probe, consume that retained
value in a separate probe, check that status reports the same running runtime,
then stop it and require confirmed termination. A configured project test is a
separate application-correctness check and is not required for this workflow
verification.

- For Clojure CLI, read [deps.md](references/deps.md).
- For Leiningen, read [leiningen.md](references/leiningen.md).
- For Babashka, read [babashka.md](references/babashka.md).
