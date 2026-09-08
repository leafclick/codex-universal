# First-project setup

When `.codex/clojure-development.edn` is absent, establish a proposed recipe
before starting a persistent REPL.

1. Read the project's `AGENTS.md`, README and developer documentation,
   `deps.edn`, `project.clj`, `bb.edn`, and relevant tool configuration. Use a
   documented command as runtime evidence; do not evaluate project forms or
   infer a runtime merely from a filename.
2. Preserve the documented command exactly: Clojure CLI `-M`, `-X`, and `-A`
   have different meanings; retain its aliases, JVM options, and entry point.
   Retain Leiningen profiles and `:repl-options`. A Babashka task can launch a
   JVM, so classify the command it invokes rather than the file that named it.
3. Present a complete proposed EDN argv recipe, including the named runtime,
   fresh-process test command, REPL helper symbols, and native lint or format
   commands only when the project documents them.
4. List only unresolved choices. Examples: two documented development
   profiles, a documented development alias that does not establish an nREPL
   dependency, or competing documented test commands. Do not create or run a
   persistent recipe until those choices are resolved.

An explicit one-off Babashka recipe may be used for an isolated probe when its
documented command is unambiguous. It does not verify a JVM runtime or a
persistent REPL. Persistent REPL and probe-worker verification require a
configured project recipe, a successful start, and two separate probes proving
that harmless sentinel state is retained across commands. Confirm the runtime
with `repl-status` and require confirmed termination from `repl-stop`. Project
tests remain separate correctness evidence and are not required to verify this
exploratory workflow.
