# Leiningen

Preserve the project's selected profiles and `:repl-options`. A configured
Leiningen runtime may use `repl :headless` when its project supplies the nREPL
dependency and `:repl-options` select host `127.0.0.1` and port `0`. The helper
verifies the actual listener is loopback-only, but the project recipe must also
document the intended ephemeral bind. Do not manufacture profiles or replace a
project's `project.clj` semantics with Clojure CLI flags.
