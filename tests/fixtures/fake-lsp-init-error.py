#!/usr/bin/env python3
"""Emit an initialization-time LSP error for message-proxy tests."""

import json
import sys


def read_frame():
    length = None
    while True:
        line = sys.stdin.buffer.readline()
        if line in (b"\r\n", b"\n"):
            break
        if not line:
            raise EOFError
        name, value = line.decode("ascii").split(":", 1)
        if name.lower() == "content-length":
            length = int(value.strip())
    return json.loads(sys.stdin.buffer.read(length))


def write_frame(message):
    body = json.dumps(message, separators=(",", ":")).encode()
    sys.stdout.buffer.write(f"Content-Length: {len(body)}\r\n\r\n".encode())
    sys.stdout.buffer.write(body)
    sys.stdout.buffer.flush()


request = read_frame()
write_frame({
    "jsonrpc": "2.0",
    "method": "window/showMessage",
    "params": {"type": 1, "message": "fixture indexing failed", "extra": "no classpath"},
})
write_frame({
    "jsonrpc": "2.0",
    "id": request["id"],
    "result": {"capabilities": {}},
})
