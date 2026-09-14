#!/usr/bin/env python3
"""Exercise concurrent semantic queries through the installed MCP/LSP bridge."""

import json
import os
import select
import signal
import subprocess
import sys
import time
from pathlib import Path


MAX_RESPONSE_BYTES = 16 * 1024 * 1024


class ProbeFailure(RuntimeError):
    pass


class McpBridge:
    def __init__(self, project_root, stderr_path):
        self.project_root = Path(project_root).resolve()
        self.stderr_path = Path(stderr_path)
        self.stderr_file = self.stderr_path.open("wb")
        self.process = subprocess.Popen(
            ["codex-clojure-lsp-mcp", "clojure:clojure-lsp"],
            cwd=self.project_root,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self.stderr_file,
            start_new_session=True,
        )
        self.buffer = bytearray()

    def send(self, message):
        if self.process.poll() is not None:
            raise ProbeFailure(
                f"MCP bridge exited before request (status {self.process.returncode})"
            )
        payload = json.dumps(message, separators=(",", ":")).encode() + b"\n"
        self.process.stdin.write(payload)
        self.process.stdin.flush()

    def responses(self, expected_ids, timeout_seconds):
        pending = set(expected_ids)
        found = {}
        deadline = time.monotonic() + timeout_seconds
        while pending:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ProbeFailure(
                    f"timed out waiting for MCP response ids {sorted(pending)}"
                )
            readable, _, _ = select.select(
                [self.process.stdout.fileno()], [], [], min(remaining, 1.0)
            )
            if not readable:
                if self.process.poll() is not None:
                    raise ProbeFailure(
                        "MCP bridge exited while waiting for response ids "
                        f"{sorted(pending)} (status {self.process.returncode})"
                    )
                continue
            chunk = os.read(self.process.stdout.fileno(), 65536)
            if not chunk:
                self.process.wait(timeout=2)
                raise ProbeFailure(
                    "MCP bridge closed stdout while waiting for response ids "
                    f"{sorted(pending)} (status {self.process.returncode})"
                )
            self.buffer.extend(chunk)
            if len(self.buffer) > MAX_RESPONSE_BYTES:
                raise ProbeFailure("MCP response exceeded the 16 MiB safety limit")
            while b"\n" in self.buffer:
                raw_line, _, remainder = self.buffer.partition(b"\n")
                self.buffer = bytearray(remainder)
                if not raw_line.strip():
                    continue
                try:
                    message = json.loads(raw_line)
                except json.JSONDecodeError as error:
                    raise ProbeFailure(f"invalid MCP JSON response: {error}") from error
                response_id = message.get("id")
                if response_id in pending:
                    found[response_id] = message
                    pending.remove(response_id)
        return found

    def close(self):
        if self.process.stdin and not self.process.stdin.closed:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(self.process.pid, signal.SIGTERM)
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait(timeout=3)
        if self.process.stdout and not self.process.stdout.closed:
            self.process.stdout.close()
        self.stderr_file.close()


def require_tool_success(response, label, expected_text=None, require_text=False):
    if "error" in response:
        raise ProbeFailure(f"{label} returned an MCP error: {response['error']}")
    result = response.get("result") or {}
    text = "\n".join(
        item.get("text", "")
        for item in result.get("content", [])
        if item.get("type") == "text"
    )
    if result.get("isError"):
        raise ProbeFailure(f"{label} returned a tool error: {text or result}")
    if require_text and not text.strip():
        raise ProbeFailure(f"{label} returned no semantic content")
    if expected_text is not None and expected_text not in text:
        raise ProbeFailure(
            f"{label} omitted expected text {expected_text!r}: {text[:1000]}"
        )
    return text


def tool_call(request_id, name, arguments):
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "tools/call",
        "params": {"name": name, "arguments": arguments},
    }


def stderr_tail(path):
    try:
        data = Path(path).read_bytes()[-65536:]
    except FileNotFoundError:
        return ""
    return "\n".join(data.decode(errors="replace").splitlines()[-40:])


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: check-clojure-lsp-mcp.py PROJECT_ROOT STDERR_LOG")
    project_root = Path(sys.argv[1]).resolve()
    stderr_path = Path(sys.argv[2]).resolve()
    source_file = project_root / "src/lsp_fixture/core.clj"
    test_file = project_root / "test/lsp_fixture/core_test.clj"
    if not source_file.is_file() or not test_file.is_file():
        raise SystemExit(f"incomplete Clojure LSP fixture: {project_root}")

    bridge = McpBridge(project_root, stderr_path)
    try:
        bridge.send(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {},
                    "clientInfo": {"name": "host-smoke", "version": "1"},
                },
            }
        )
        initialized = bridge.responses({1}, 15)[1]
        if (initialized.get("result") or {}).get("serverInfo", {}).get("name") != "agent-lsp":
            raise ProbeFailure(f"unexpected MCP initialize response: {initialized}")
        bridge.send(
            {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}
        )

        bridge.send(
            tool_call(
                2,
                "start_lsp",
                {
                    "root_dir": str(project_root),
                    "language_id": "clojure",
                    "ready_timeout_seconds": 60,
                },
            )
        )
        require_tool_success(
            bridge.responses({2}, 90)[2],
            "start_lsp",
            "LSP server started successfully",
        )

        positions = [(4, 7), (7, 7), (10, 7)]
        first_line, first_column = positions[0]
        bridge.send(
            tool_call(
                3,
                "explore_symbol",
                {
                    "file_path": str(source_file),
                    "line": first_line,
                    "column": first_column,
                    "language_id": "clojure",
                },
            )
        )
        require_tool_success(
            bridge.responses({3}, 60)[3],
            "sequential explore_symbol",
            require_text=True,
        )

        delay_seconds = float(os.environ.get("CODEX_TEST_LSP_IDLE_SECONDS", "2"))
        if delay_seconds < 0 or delay_seconds > 30:
            raise ProbeFailure("CODEX_TEST_LSP_IDLE_SECONDS must be between 0 and 30")
        time.sleep(delay_seconds)

        concurrent_ids = {10, 11, 12}
        for request_id, (line, column) in zip(sorted(concurrent_ids), positions):
            bridge.send(
                tool_call(
                    request_id,
                    "explore_symbol",
                    {
                        "file_path": str(source_file),
                        "line": line,
                        "column": column,
                        "language_id": "clojure",
                    },
                )
            )
        concurrent = bridge.responses(concurrent_ids, 90)
        for request_id in sorted(concurrent_ids):
            require_tool_success(
                concurrent[request_id],
                f"concurrent explore_symbol id {request_id}",
                require_text=True,
            )

        bridge.send(
            tool_call(
                20,
                "find_references",
                {
                    "file_path": str(source_file),
                    "line": 7,
                    "column": 7,
                    "language_id": "clojure",
                    "include_declaration": True,
                },
            )
        )
        require_tool_success(
            bridge.responses({20}, 60)[20],
            "find_references",
            str(test_file),
        )
    except Exception:
        bridge.close()
        tail = stderr_tail(stderr_path)
        if tail:
            print("--- Clojure MCP/LSP stderr (last 40 lines, 64 KiB maximum) ---", file=sys.stderr)
            print(tail, file=sys.stderr)
        raise
    else:
        bridge.close()


if __name__ == "__main__":
    try:
        main()
    except ProbeFailure as error:
        print(f"host-smoke: {error}", file=sys.stderr)
        raise SystemExit(1)
