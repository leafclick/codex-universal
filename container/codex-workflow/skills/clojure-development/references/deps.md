# Clojure CLI

Keep the project's aliases, paths, dependencies, JVM options, and selected
entry point intact. `-M`, `-X`, and legacy `-A` have different invocation
semantics and are not interchangeable. Use the configured `:repl` argv when
available. For an unconfigured project, only use a conventional command when
there is one clear development alias; otherwise request configuration.

Use a fresh Clojure process when a changed classpath, JVM option, generated
class, protocol implementation, or native backend state could contaminate the
persistent JVM.
