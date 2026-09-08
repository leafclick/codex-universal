# Babashka

Run independent Babashka probes one-off by default; startup is cheap. Start a
persistent Babashka nREPL only when retained state is material. Do not use
Babashka as evidence for JVM semantics or JVM-only libraries. A `bb` task may
launch a JVM, so classify the actual invoked runtime rather than `bb.edn`
alone. Invoke the configured `one-off FORM [runtime]` operation so `:workdir`,
the overall deadline, bounded stdout/stderr, and explicit non-default runtime
selection are preserved. Confirmation covers the complete process group on
both timeout and normal leader exit; surviving descendants are cleaned up
before termination is reported as confirmed.
