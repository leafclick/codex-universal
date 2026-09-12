# GraalVM Native Image in procfs-hidden sandboxes

## Recommendation

On Linux, prefer a JVM distribution of a tool over a glibc-based GraalVM
Native Image when the tool must run in a sandbox where `/proc/self/maps` is
absent or deliberately hidden. Use the native image only when the sandbox can
mount a correct private procfs, or when the exact binary has passed a startup
test under the production mount policy.

This is a compatibility recommendation, not a claim that JVM packaging is
generally better. Native images retain useful startup-time and memory
advantages outside this specific boundary.

## Why an empty `/proc` breaks native-image startup

GraalVM Native Image creates a main isolate before application code runs. Its
Linux runtime obtains the initial thread's stack boundaries with
`pthread_getattr_np()`. GraalVM's implementation explicitly notes that this
operation can fail when `/proc/self/maps` cannot be opened:

- GraalVM defines isolate error 32 as
  [`UNKNOWN_STACK_BOUNDARIES`](https://github.com/oracle/graal/blob/master/substratevm/src/com.oracle.svm.guest.staging/src/com/oracle/svm/guest/staging/c/function/CEntryPointErrors.java#L169-L173),
  described as "Could not determine the stack boundaries."
- Its
  [Linux stack lookup](https://github.com/oracle/graal/blob/master/substratevm/src/com.oracle.svm.core.posix/src/com/oracle/svm/core/posix/linux/LinuxStackOverflowSupport.java#L60-L69)
  calls `pthread_getattr_np()` and identifies an unreadable
  `/proc/self/maps` as one possible failure.
- The Linux
  [`pthread_getattr_np(3)` documentation](https://www.man7.org/linux/man-pages/man3/pthread_getattr_np.3.html)
  confirms that the main-thread lookup can fail when `/proc/self/maps` cannot
  be opened.

The resulting failure happens before the application's `main` function:

```text
empty or inaccessible /proc/self/maps
  -> pthread_getattr_np() cannot describe the initial thread stack
  -> GraalVM reports UNKNOWN_STACK_BOUNDARIES
  -> Failed to create the main Isolate. (code 32)
```

The message is easy to misread as an out-of-memory error. For code 32, adding
heap memory is not the relevant fix. Other isolate codes have different
meanings; for example, code 24 is a build-time versus run-time page-size
mismatch and should not be diagnosed as this procfs problem.

## Why the JVM distribution is a useful fallback

A JVM distribution runs the same application bytecode on HotSpot instead of
embedding it in a SubstrateVM native executable. It therefore avoids this
GraalVM isolate-creation path. This is particularly suitable for persistent
services, language servers, and MCP bridges: JVM startup is paid once, while
indexing and request handling dominate the process lifetime.

The JVM is not guaranteed to be completely independent of procfs. Java
launchers and libraries may use `/proc/self/exe`, container metrics, or other
procfs entries. Resolve the intended JDK before entering the sandbox, supply
its library paths explicitly when necessary, and run an exact startup probe
under the final mount and namespace policy.

## Alternatives and their tradeoffs

### Mount a private procfs

The best way to retain the native image is to mount a new procfs after entering
the sandbox's private PID namespace. It supplies correct live mappings while
showing only processes visible in that namespace.

This is not portable to every hardened host. Unprivileged user namespaces,
AppArmor, seccomp, or container runtime policy may reject the procfs mount.
Treat successful operation on one development machine as insufficient proof.

### Use a different native runtime or custom build

Different libc implementations or later GraalVM versions may obtain stack
metadata differently. A static or custom native build can therefore be tested,
but its behavior must be demonstrated inside the exact sandbox. Do not infer
compatibility merely from `--version` succeeding outside it.

Disabling stack checks or patching the Native Image runtime creates a custom
security and maintenance burden. It is usually a worse default than using the
upstream JVM artifact for a long-lived process.

### Expose host procfs selectively

Do not bind the host's `/proc` into a process-hiding sandbox. Binding or copying
the outer `/proc/self/maps` is also incorrect: it may describe the mounting
process instead of the executable that subsequently starts, and memory maps
change during execution.

## Validation guidance

Test the real artifact, not only its packaging metadata. The minimum useful
preflight runs the production executable inside the same user, PID, network,
mount, capability, and seccomp/AppArmor boundaries used in service operation.
It should have a short timeout and preserve stderr so an isolate code is
reported directly.

For an LSP or another framed protocol service, follow the startup preflight
with one complete protocol exchange. A successful `--version` proves runtime
initialization, but it does not prove subprocess discovery, project loading,
or clean shutdown.

## codex-universal application

The terminal Clojure bridge intentionally overlays `/proc` with an empty
tmpfs because mounting a new procfs is rejected on some supported hardened
hosts. The architecture-specific native `clojure-lsp` failed there with code
32, while the same pinned upstream release's Java-backed artifact completed
the sandboxed MCP/LSP workflow. The image therefore installs the JVM artifact
and retains native packaging for tools that pass their own sandboxed checks.

Revisit this choice if GraalVM removes the main-thread procfs dependency or the
supported host policy can guarantee a private procfs mount. Until then, the JVM
artifact is the more portable default for this long-lived service.
