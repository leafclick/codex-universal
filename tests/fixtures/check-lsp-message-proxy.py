#!/usr/bin/env python3
"""Behavioral check for initialization-error forwarding."""

import json
import subprocess
import sys


def frame(message):
    body = json.dumps(message, separators=(",", ":")).encode()
    return f"Content-Length: {len(body)}\r\n\r\n".encode() + body


def frames(data):
    messages = []
    while data:
        header, data = data.split(b"\r\n\r\n", 1)
        length = int(header.split(b":", 1)[1].strip())
        body, data = data[:length], data[length:]
        messages.append(json.loads(body))
    return messages


proxy, fixture = sys.argv[1:]
result = subprocess.run(
    [proxy, sys.executable, fixture],
    input=frame({"jsonrpc": "2.0", "id": 7, "method": "initialize", "params": {}}),
    stdout=subprocess.PIPE,
    check=True,
    timeout=5,
)
messages = frames(result.stdout)
assert messages[0]["method"] == "window/logMessage"
assert "fixture indexing failed\nno classpath" == messages[0]["params"]["message"]
assert messages[1]["method"] == "window/showMessage"
assert messages[2]["id"] == 7
assert messages[2]["error"]["code"] == -32002
assert "initialization failure" in messages[2]["error"]["message"]
