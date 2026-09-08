#!/usr/bin/env python3
"""Small local-only nREPL fixture for host smoke tests."""

import argparse
import socket
import threading
import time


def read_exact(stream, length):
    value = stream.read(length)
    if len(value) != length:
        raise EOFError("short bencode value")
    return value


def decode(stream, first=None):
    token = first or read_exact(stream, 1)
    if token == b"i":
        digits = bytearray()
        while True:
            token = read_exact(stream, 1)
            if token == b"e":
                return int(digits)
            digits.extend(token)
    if token == b"l":
        values = []
        while True:
            token = read_exact(stream, 1)
            if token == b"e":
                return values
            values.append(decode(stream, token))
    if token == b"d":
        values = {}
        while True:
            token = read_exact(stream, 1)
            if token == b"e":
                return values
            key = decode(stream, token)
            values[key] = decode(stream)
    if b"0" <= token <= b"9":
        digits = bytearray(token)
        while True:
            token = read_exact(stream, 1)
            if token == b":":
                break
            digits.extend(token)
        return read_exact(stream, int(digits)).decode("utf-8")
    raise ValueError(f"invalid bencode token: {token!r}")


def encode(value):
    if isinstance(value, str):
        encoded = value.encode("utf-8")
        return str(len(encoded)).encode("ascii") + b":" + encoded
    if isinstance(value, int):
        return b"i" + str(value).encode("ascii") + b"e"
    if isinstance(value, list):
        return b"l" + b"".join(encode(item) for item in value) + b"e"
    if isinstance(value, dict):
        items = sorted(value.items())
        return b"d" + b"".join(encode(key) + encode(item) for key, item in items) + b"e"
    raise TypeError(type(value))


def send(stream, message):
    stream.write(encode(message))
    stream.flush()


def handle(connection):
    try:
        with connection, connection.makefile("rwb", buffering=0) as stream:
            while True:
                message = decode(stream)
                operation = message.get("op")
                request_id = message.get("id", "fixture")
                if operation == "clone":
                    send(stream, {"id": request_id, "new-session": "fixture-session"})
                    send(stream, {"id": request_id, "status": ["done"]})
                elif operation == "eval":
                    code = message.get("code")
                    if code == "multiple-values":
                        send(stream, {"id": request_id, "value": ""})
                        send(stream, {"id": request_id, "value": "one"})
                        send(stream, {"id": request_id, "value": ""})
                        send(stream, {"id": request_id, "value": "café"})
                        send(stream, {"id": request_id, "status": ["done"]})
                    elif code == "eval-error":
                        send(stream, {"id": request_id,
                                      "ex": "fixture.Exception",
                                      "root-ex": "fixture.Exception",
                                      "status": ["eval-error", "done"]})
                    elif code == "timeout":
                        send(stream, {"id": request_id,
                                      "out": "partial-before-timeout\n"})
                        time.sleep(2)
                        send(stream, {"id": request_id, "status": ["done"]})
                    elif code == "oversized":
                        send(stream, {"id": request_id, "out": "x" * 1048577})
                    else:
                        send(stream, {"id": request_id, "value": code})
                        send(stream, {"id": request_id, "status": ["done"]})
                else:
                    send(stream, {"id": request_id,
                                  "status": ["error", "done"]})
    except (BrokenPipeError, ConnectionError, EOFError, OSError):
        return


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    args = parser.parse_args()
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind((args.host, 0))
        server.listen()
        port = server.getsockname()[1]
        print(f"nREPL server started on port {port} on host {args.host}", flush=True)
        while True:
            connection, _ = server.accept()
            threading.Thread(target=handle, args=(connection,), daemon=True).start()


if __name__ == "__main__":
    main()
