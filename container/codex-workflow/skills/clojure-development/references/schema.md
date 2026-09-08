# `.codex/clojure-development.edn`

The file is optional EDN. Keywords name entries; every executable command is
an argv vector of non-empty strings, never a shell string. Unknown keys are
rejected so a misspelled runtime cannot silently select a different profile.

```clojure
{:default-runtime :dev
 :runtimes
 {:dev {:kind :deps
        :workdir "."
        :repl ["clojure" "-M:dev" "-m" "nrepl.cmdline"
               "--bind" "127.0.0.1" "--port" "0"]
        :repl-test-helper my.project/run-focused-tests}
  :bb {:kind :babashka
       :one-off ["bb" "-e"]}}
 :repl-test-helpers {:focused my.project/run-focused-tests}
 :tests {:unit {:command ["clojure" "-M:test"]
                :fresh-process :when-required}
         :integration {:command ["clojure" "-M:integration-test"]
                       :fresh-process :always}}
 :validation {:lint-command ["clj-kondo" "--lint"]
              :format-command ["cljfmt" "check"]
              :format-fix-command ["cljfmt" "fix"]}}
```

`kind` is one of `:deps`, `:lein`, or `:babashka`. A JVM runtime requires a
`:repl` argv vector. A `:deps` nREPL recipe must pass `--bind 127.0.0.1` and
`--port 0` exactly once as option/value pairs; duplicate or conflicting values
are rejected. Leiningen uses its own selected profiles and `:repl-options`;
provide that exact project recipe, configured for host `127.0.0.1` and port
`0`, rather than translating Clojure CLI options. For every persistent kind,
startup verifies the observed listener addresses are loopback-only and records
process ownership before waiting for readiness. The entrypoint-owned service
retains that process across helper commands inside a nested sandbox that keeps
`.git` and `.codex` read-only.
`:workdir` is optional and relative to the project root. `:one-off` is only for
Babashka and is an argv prefix to which a form is appended. Select a non-default
Babashka runtime explicitly with `one-off FORM runtime`; it runs in `:workdir`
with bounded output and an overall deadline. `:repl-test-helper` and values in
`:repl-test-helpers` are symbols, not strings. Test freshness is `:always` or
`:when-required`. `:default-runtime` may be omitted when exactly one runtime is
configured; with multiple runtimes, omission requires an explicit runtime name.
One-off completion covers the whole process group: surviving descendants are
terminated before the helper reports termination as confirmed.

The helper validates this shape before launch. It rejects shell-string
commands, unknown runtime references, non-loopback REPLs, and malformed
entries. To keep each atomic process-service request within the FIFO transport,
the EDN representation of an argv vector may not exceed 2048 UTF-8 bytes.
Project examples must remain project-local; no bundled project
configuration is assumed by this skill.

The active-recipe guard compares only the selected argv, runtime kind and
workdir. It does not establish freshness of dependency aliases, Lein profiles,
environment, loaded source or classpath. Restart explicitly when those inputs
change; matching recipe metadata is not proof that a live JVM has current code.

Copy or hash only named regular raw-record, log and state files, never an
unfiltered live session-directory glob: reading `service-control.fifo` consumes
control requests, not a state snapshot. Preserve command exit/running-session
metadata; yielding a running session is not command completion or a timeout.

Persistent evaluations retain newline boundaries between separate nREPL
values. Evaluation-error statuses are distinct from `:done`. A deadline or
connection loss after sending `eval` records `:evaluation {:status :unknown}`,
keeps partial display evidence and a flushed raw record, and blocks further
evaluation until a confirmed stop/restart resolves the server state.

Before creating this file for a first project, follow
[first-project setup](first-project.md). The helper executes only `:repl` and
Babashka `:one-off` recipes; test, helper, lint, and format mappings remain
instructions for an agent to invoke deliberately.
