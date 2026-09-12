# IntelliJ IDEA integration

IntelliJ IDEA and other JetBrains IDEs with AI Assistant can use the same
Dockerized Codex through a custom Agent Client Protocol (ACP) agent. This
provides IDE chat, editor context, streamed commands, approval prompts, and
file-change presentation without running JetBrains' separately installed
Codex executable on the host. See JetBrains'
[custom ACP agent instructions](https://www.jetbrains.com/help/ai-assistant/activate-agents.html#add-acp-agents)
and the upstream
[Codex ACP adapter](https://github.com/agentclientprotocol/codex-acp) for the
protocol components used here.

The ACP adapter is bundled in both default images; it is not a separate
container-side installation. Communication uses the ACP process's standard
input and output:

```text
IDEA AI Chat <-> run-codex --idea <-> docker run -i <-> codex-acp
```

IDEA starts the configured host command, and Docker carries the same stdin and
stdout streams into the container. No ACP TCP listener or published Docker
port is involved. IntelliJ's MCP server is separate: because it binds only to
host loopback, `run-codex --idea` relays its one TCP port through a private
per-chat Unix socket instead of giving the Codex container host networking.

JetBrains exposes registry agents and custom agents through different parts of
the UI:

- **Settings → Tools → AI Assistant → Agents** and **Install From ACP
  Registry** manage registry agents. The **Codex** entry whose description is
  **ACP adapter for OpenAI's coding assistant** is JetBrains-managed; an
  **Update** button updates that agent. The Dockerized Codex entry does not
  appear in this page or its search.
- **AI Chat → Add Custom Agent (Beta)** opens `~/.jetbrains/acp.json`. Agents
  defined there appear in the agent selector inside AI Chat. This is the path
  used by this project.

Selecting plain **Codex** runs the JetBrains-managed agent instead of this
project's container launcher.

Setup:

1. Install `jq`, `socat`, `util-linux`, and the current `run-codex` and
   `setup-codex-idea` commands as described in
   [Install](../README.md#install). Images built from the
   current Dockerfiles already contain `codex-acp` and the container side of
   the relay. Rebuild if the local image predates this integration.

2. Register the project and verify the terminal client first. Complete the
   Codex login, then exit the terminal client.

   ```bash
   cd ~/src/my-project
   run-codex --init
   run-codex
   ```

3. On the host, add the Dockerized Codex dispatcher to
   `~/.jetbrains/acp.json`:

   ```bash
   setup-codex-idea
   ```

   JetBrains reads this as a global agent list and has no per-project
   visibility condition. This command therefore installs one **Dockerized
   Codex (codex-universal)** entry and removes legacy per-project entries that
   it previously generated, while preserving unrelated custom agents. Run it
   once after installing or updating the host scripts, not once per project.
   For each new chat, the dispatcher matches IDEA's ACP session working
   directory to a registered `run-codex` checkout before starting Docker.

4. In IDEA, open **AI Chat**, use its upper-right menu, and select **Add Custom
   Agent (Beta)**. IDEA opens the `acp.json` file it reads. Confirm that it
   contains **Dockerized Codex (codex-universal)**, then save it. In **Settings →
   Tools → MCP Server**, also select **Enable MCP Server** if it is not already
   enabled. Leave **Project Clients Auto-Configuration**, **Clients
   Auto-Configuration**, and **Manual Client Configuration** unused for this
   agent; the launcher supplies its private Streamable HTTP connection.

5. Start a new agent chat and select **Dockerized Codex (my-project)** from
   the AI Chat agent selector. Custom entries normally appear immediately;
   restart the IDE only if the new entry is missing.

6. Keep **Ask for approval** selected. The adapter internally calls this mode
   `read-only`, but it maps to `workspace-write`, `on-request`, and human
   review. Do not select **Approve for me**: that mode requests Codex
   auto-review, which the image policy intentionally rejects. The image also
   rejects `never` and full-access modes.

7. In the new IDEA chat, use the
   [IntelliJ IDEA MCP prompt](../README.md#intellij-idea-mcp-prompt). If the client
   exposes MCP connection status, confirm that `idea` is connected first, but
   treat successful tool calls as the authoritative check. Neither the test's
   shell reads nor its IDEA calls should request approval. Perform the
   [manual approval-boundary check](../README.md#manual-approval-boundary-check) as a
   separate test if you also want to verify `.git` and network behavior through
   ACP.

The command preserves other agents and settings in the file, and records the
absolute path of the installed `run-codex`. The resulting entry is equivalent
to:

```json
{
  "agent_servers": {
    "Dockerized Codex (my-project)": {
      "command": "/home/alice/.local/bin/run-codex",
      "args": ["--idea", "my-project"],
      "use_idea_mcp": false,
      "use_custom_mcp": false
    }
  }
}
```

`use_idea_mcp` is intentionally disabled. IDEA's ACP integration otherwise
forwards a host-only STDIO launcher path, which does not exist inside the
container and fails with `No such file or directory`. Instead, IDEA mode
connects Codex to `http://127.0.0.1:64342/stream` inside the container. Two
`socat` processes carry that connection through a mode-0600 Unix socket to
IDEA's host-only `127.0.0.1:64342` listener:

```text
Codex -> container loopback -> private Unix socket -> host loopback -> IDEA
```

The container gets a read-only mount of only the per-chat relay directory. It
does not get host networking, a published port, or the IDEA or Snap
installation. The relay is stopped and its socket removed with the ACP
container. A parent-death guard also removes the exact container and relay if
IDEA kills the launcher without allowing its normal exit trap to run. Relay
processes do not inherit the project or snapshot locks. Separate IDEA chats
use separate sockets and isolated container loopback listeners.

IDEA mode mounts the checkout at the same absolute host path inside the
container, so `projectPath` values and file paths returned by IDE tools
identify the same files Codex reads and edits. This solves path identity
without creating a second project symlink.

The launcher's Codex MCP configuration uses `enabled_tools` to expose only
project analysis, inspection, symbol, search, navigation, and read tools. Host
terminal execution, run configurations, database/debugger control,
refactoring, formatting, patching, and other IDE-side writes are not exposed,
so IDE MCP cannot bypass the container's approval and filesystem boundaries.
Working-tree changes still go through Codex inside the hardened container.

`use_custom_mcp` also remains disabled. Together, these ACP flags prevent
arbitrary host-configured MCP launch commands, including host or Snap-specific
paths, from being forwarded into the container. Run `setup-codex-idea` again
to replace an older entry, then start a new chat. JetBrains
documents both flags in its
[ACP configuration reference](https://www.jetbrains.com/help/ai-assistant/acp.html).

The defaults use IDEA's Streamable HTTP endpoint. If IDEA displays a different
loopback port or Streamable HTTP path, ensure those environment variables are
visible to the IDEA process that launches the custom agent:

```bash
CODEX_IDEA_MCP_PORT=64342
CODEX_IDEA_MCP_PATH=/stream
```

The legacy `/sse` endpoint is not the default because current Codex clients
use Streamable HTTP. Set `CODEX_IDEA_MCP=0` only to start IDEA mode without the
IDE MCP connection.

To retry IDEA after updating the launcher or host policy, close the affected
agent chat, reinstall the host policy, and refresh the generated ACP entry:

```bash
bin/setup-codex-host-security
setup-codex-idea
docker ps --filter label=codex-universal.project=my-project
```

The final command shows any still-open terminal or IDEA sessions for that
project. Rebuilding the image is necessary only when it predates the bundled
ACP adapter or another Dockerfile change; launcher, AppArmor, seccomp, and
`acp.json` updates do not by themselves require an image rebuild.

Each IDEA chat gets a separate container with a unique name and the
`codex-universal.project` and `codex-universal.mode=idea` labels. Clicking
**New Chat** can therefore keep the previous chat open while starting another
ACP process. The launcher records the exact container ID for each process and
removes its own container when IDEA closes or terminates it.

A container orphaned by a launcher version from before this cleanup was added
must be removed once, after making sure no terminal or IDEA session is using
it:

```bash
docker rm -f codex-my-project
```

With **Ask for approval**, reads, working-tree edits, and commands that remain
inside the sandbox should run without confirmation. If a harmless command such
as `pwd` or `rg` still requests approval, inspect the reason shown in the
approval dialog or ACP logs. Do not work around it by selecting **Approve for
me**; that enables automatic approval review rather than fixing the underlying
sandbox failure.

If the entry is not available in AI Chat:

1. Do not search for it in **Settings → Tools → AI Assistant → Agents**; that
   page lists registry agents, not custom `acp.json` entries.
2. Verify the generated entry on the host:

   ```bash
   jq -e '.agent_servers["Dockerized Codex (my-project)"]' \
     ~/.jetbrains/acp.json
   ```

3. Check **Settings → Plugins → Installed → AI Assistant** and install any
   available update. IntelliJ IDEA 2026.2 had an
   [`acp.json` discovery regression](https://youtrack.jetbrains.com/issue/LLM-29700)
   that was fixed in an AI Assistant plugin update.
4. Restart IDEA. If the entry is still absent, inspect the host log:

   ```bash
   grep -Ei 'acp\.json|Dockerized Codex|agent_servers|custom agent' \
     ~/.cache/JetBrains/IntelliJIdea*/log/idea.log | tail -n 100
   ```

The [official IntelliJ IDEA Snap](https://www.jetbrains.com/help/idea/installation-guide.html#snap)
uses classic confinement, so it reads the normal `~/.jetbrains/acp.json`; do
not move this file under `~/.config/JetBrains/IntelliJIdea*/`. Run
`setup-codex-idea` outside the container as the same host user that runs IDEA.

Run `setup-codex-idea` once. Every IDEA session request includes an absolute
working directory; the dispatcher rejects unregistered directories and starts
the normal launcher backend for the matching project. That backend remains the
source of truth for the registered checkout, image profile, locks, mounts, and
managed security policy. IDEA's indexed MCP remains the default semantic
provider. When the project's `clojure-mcp` setting resolves to enabled, the
container-local Clojure LSP MCP is exposed as a second provider. Use it for
Clojure-specific gaps, or query both providers in parallel when an ambiguous
or high-risk result benefits from independent corroboration.

The image installs an enforced `/etc/codex/requirements.toml` for
`workspace-write`, `on-request`, and human review. OpenAI documents this
non-overridable policy layer under [managed Codex configuration](https://learn.chatgpt.com/docs/enterprise/managed-configuration).

IDEA supplies its host project path in ACP requests, so IDEA mode mounts only
the registered checkout at the same absolute path inside the container. This
keeps file references clickable in the IDE. Terminal mode retains the stable
`/workspace/<project>` path. Codex resume selection is working-directory
scoped, and the ACP adapter filters IDEA sessions by their exact working
directory, so the two path forms create separate resumable session histories.
They share authentication and persisted Codex state, but a conversation should
not be moved between terminal and IDEA modes.

## Conversation ownership and resume

`run-codex my-project --sessions` is terminal-only. IDEA's conversation list
is owned by JetBrains AI Assistant; this integration neither replaces nor
merges it with the terminal session list.

Multiple IDEA chats may run for the same project, each in its own container.
Terminal mode remains mutually exclusive with all IDEA chats for that project,
so close its IDEA agent processes before starting `run-codex my-project` in a
terminal, or exit the terminal session before opening an IDEA agent. Check all
active containers for a project with:

```bash
docker ps --filter label=codex-universal.project=my-project
```

The ACP process opens no host network port. Its diagnostics go to stderr so
stdout remains a clean ACP protocol stream. IDEA integration is optional: if
it is not configured, the bundled adapter remains inactive and the image
continues to work as the terminal environment.
