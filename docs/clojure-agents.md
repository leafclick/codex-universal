# Clojure development guidance for `AGENTS.md`

The section below is intended to be copied into a Clojure repository's
root-level `AGENTS.md` and adapted to that repository's aliases and test
commands. Keep only commands that actually work in the target repository.
Place more specialized overrides in a nearer `AGENTS.md` or
`AGENTS.override.md` when a subtree has a different toolchain.

Codex loads repository instructions before working and combines root and
nested instruction files by scope. See the official
[Codex `AGENTS.md` documentation](https://learn.chatgpt.com/docs/agent-configuration/agents-md).

## Copyable section

````markdown
## Clojure interactive development

This workflow is editor-independent. Its baseline is the shell, native
Clojure tools, Babashka, and an optional persistent nREPL; IDE integration is
only an additional source of semantic information.

Use the cheapest tool that answers the question while preserving semantic
accuracy. At the start of a task, inspect the repository's `bb.edn`,
`deps.edn`, `.cljfmt.edn`, `.clj-kondo/config.edn`, and `.lsp/config.edn` and
honor their tasks, aliases, paths, and options. Check which tools are available
once instead of repeatedly probing for them.

### Tool selection

- Use `bb` for lightweight Clojure expressions, repository scripts, EDN/JSON
  processing, and tasks declared in `bb.edn`. Do not start a JVM with
  `clojure -e` when Babashka supports the required namespaces and semantics.
- Use the native `clj-kondo`, `cljfmt`, and `clojure-lsp` executables for
  static analysis, formatting, and semantic operations when no persistent
  integration provides the operation. They do not require IDEA or a Clojure
  JVM startup.
- For definitions, references, symbol documentation, diagnostics, and call
  relationships, prefer a language-aware provider when one is available:
  - In a terminal session with the `clojure_lsp` MCP server, reuse its running
    language server instead of launching a new `clojure-lsp` process for every
    semantic query.
  - Without an MCP server, use the native `clojure-lsp` CLI for supported
    operations such as diagnostics, references, namespace cleanup, formatting,
    and analysis output.
  - In an IntelliJ/ACP session, IDEA's `mcp__idea__` search, symbol, and
    diagnostics tools are an optional alternative. Pass the exact project path
    reported by the session; do not translate it to a conventional
    `/workspace/...` path.
- Prefer read-only navigation and diagnostics while investigating. Formatting,
  rename, refactoring, and other write-capable tools may be used only when the
  requested task authorizes edits; inspect their resulting diff.
- Use `rg` or text search for literal strings, configuration, generated names,
  or as an explicitly reported fallback when semantic lookup is unavailable.
- Call-hierarchy support varies by IDE and language plugin. If call analysis
  does not recognize a Clojure var, report the operation as unsupported; do
  not conclude that the var has no callers. Fall back to LSP references or a
  clearly labelled textual search.
- Do not substitute Babashka for code that depends on JVM-only libraries,
  Java integration it does not implement, project classpath behavior, or
  runtime semantics that must be verified on the JVM.

### Fast linting and formatting

Prefer project tasks shown by `bb tasks` when they exist; they are the
repository's interface to its chosen paths and options. Common examples are
`bb lint`, `bb fmt`, or `bb fmt-check`. Do not assume those task names exist.

When no project task wraps them, use the native executables directly:

```bash
clj-kondo --lint path/to/changed.clj
cljfmt check path/to/changed.clj
```

Use `cljfmt fix` only on files in the requested change, then inspect the diff.
Do not reformat unrelated files. Run the repository's broader lint and format
checks before handoff when its validation rules require them.

The installed `cljfmt`, `clj-kondo`, and `clojure-lsp` commands are native
executables. Calling them directly does not pay Clojure/JVM startup cost;
using a `bb` task to orchestrate them is also appropriate.

### Runtime probes and iterative evaluation

Use a long-running nREPL for repeated probes that require real JVM Clojure
semantics. Prefer a committed project alias that already supplies nREPL. If
the repository has no such alias, adapt the following command to its actual
development aliases and approved nREPL version:

```bash
clojure -Sdeps '{:deps {nrepl/nrepl {:mvn/version "1.3.1"}}}' \
  -M:<dev-aliases> -m nrepl.cmdline --bind 127.0.0.1 --port 0
```

Bind only to loopback and use port `0`; never expose the development nREPL on
`0.0.0.0`. Keep the returned process session alive and record the selected
port. Do not start a new server for every evaluation.

Connect one persistent client in another process session:

```bash
clojure -Sdeps '{:deps {nrepl/nrepl {:mvn/version "1.3.1"}}}' \
  -M -m nrepl.cmdline --connect --host 127.0.0.1 --port <port>
```

Reuse loaded namespaces and reload only source that changed, for example:

```clojure
(require '[my.project.namespace :as subject] :reload)
```

Keep probes reproducible: record the forms evaluated, avoid mutating shared
development data unnecessarily, and do not treat state that exists only in
the REPL as an implementation change.

### Watchers

When the repository provides a test or lint watch command, start at most one
relevant watcher and reuse it. Retain its process/session identifier, poll its
existing output after edits, and stop it before handoff. For example, a
project-specific CPU test alias might be:

```bash
clojure -M:<cpu-test-alias> --watch
```

Do not invent `--watch` for a runner that does not support it. Use the exact
watch command documented by the repository.

### Final verification

Interactive results are fast feedback, not final proof. Before handoff:

1. Run focused native lint and format checks on the changed Clojure files.
2. Run the repository's required test commands in a fresh Clojure CLI process.
3. Ensure the result does not depend on namespaces or state retained by the
   development nREPL.
4. Stop nREPL servers and watchers started for the task.
5. Inspect the final diff and preserve unrelated user changes.
````

Replace `<dev-aliases>`, `<cpu-test-alias>`, the nREPL version, and the example
namespace with values that are valid for the target project. Committing a
shared nREPL alias in `deps.edn` is preferable when the workflow is used
regularly; it avoids repeating dependency coordinates in instructions and
keeps the development environment consistent for humans and agents.
