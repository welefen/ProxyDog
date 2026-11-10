#!/usr/bin/env python3
"""WebSocket traffic generator used by scripts/test_websocket.sh.

Modes
  server <port>                        plain WebSocket echo server
  server-tls <port> <cert> <key>       TLS WebSocket echo server (self-signed is fine)
  plain <proxy-port> <host> <port>     ws:// client through ProxyDog's HTTP proxy
  wss <proxy-port> <host> <port>       wss:// client through ProxyDog (CONNECT + MITM)

The server greets every connection with one *fragmented* text message
("server-fragmented-hello"), then echoes every data frame back verbatim.

The client sends: text "hello-from-client", a 1 MB binary frame, then a close frame.
A JSON summary is printed so the shell test can assert capture contents.
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
import socket
import ssl
import struct
import sys
import threading
import time

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
FRAGMENTED_GREETING = b"server-fragmented-hello"


# ----------------------------------------------------------------------------- server


def read_until(sock: socket.socket, marker: bytes) -> bytes:
    data = b""
    while marker not in data:
        chunk = sock.recv(4096)
        if not chunk:
            break
        data += chunk
    return data


def build_frame(opcode: int, payload: bytes, fin: bool = True) -> bytes:
    first = (0x80 if fin else 0x00) | opcode
    length = len(payload)
    if length < 126:
        header = bytes([first, length])
    elif length < 65536:
        header = bytes([first, 126]) + struct.pack(">H", length)
    else:
        header = bytes([first, 127]) + struct.pack(">Q", length)
    return header + payload


def read_frame(sock: socket.socket) -> tuple:
    header = sock.recv(2)
    if len(header) < 2:
        raise OSError("closed")
    b1, b2 = header[0], header[1]
    fin = bool(b1 & 0x80)
    opcode = b1 & 0x0F
    masked = bool(b2 & 0x80)
    length = b2 & 0x7F
    if length == 126:
        length = struct.unpack(">H", sock.recv(2))[0]
    elif length == 127:
        length = struct.unpack(">Q", sock.recv(8))[0]
    mask = sock.recv(4) if masked else b""
    payload = b""
    while len(payload) < length:
        chunk = sock.recv(length - len(payload))
        if not chunk:
            raise OSError("closed")
        payload += chunk
    if masked:
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    return fin, opcode, payload


def ws_server(port: int, cert: str | None, key: str | None) -> None:
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", port))
    listener.listen(8)
    context = None
    if cert and key:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
    print(json.dumps({"type": "ready", "port": port, "tls": bool(context)}), flush=True)

    def handle(conn: socket.socket) -> None:
        try:
            request = read_until(conn, b"\r\n\r\n")
            key_header = ""
            for line in request.decode("latin-1").split("\r\n"):
                if line.lower().startswith("sec-websocket-key:"):
                    key_header = line.split(":", 1)[1].strip()
            accept = base64.b64encode(hashlib.sha1((key_header + GUID).encode()).digest()).decode()
            conn.sendall(
                (
                    "HTTP/1.1 101 Switching Protocols\r\n"
                    "Upgrade: websocket\r\n"
                    "Connection: Upgrade\r\n"
                    f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
                ).encode()
            )
            # One fragmented message: text frame (FIN=0) + continuation frame (FIN=1).
            half = len(FRAGMENTED_GREETING) // 2
            conn.sendall(build_frame(0x1, FRAGMENTED_GREETING[:half], fin=False))
            conn.sendall(build_frame(0x0, FRAGMENTED_GREETING[half:], fin=True))
            # Echo everything back with the same opcode.
            while True:
                _fin, opcode, payload = read_frame(conn)
                if opcode == 0x8:  # close
                    conn.sendall(build_frame(0x8, payload))
                    return
                if opcode in (0x1, 0x2, 0x0):
                    conn.sendall(build_frame(0x1 if opcode == 0x1 else 0x2, payload))
        except OSError:
            pass
        finally:
            try:
                conn.close()
            except OSError:
                pass

    def loop() -> None:
        while True:
            conn, _ = listener.accept()
            if context is not None:
                try:
                    conn = context.wrap_socket(conn, server_side=True)
                except OSError:
                    conn.close()
                    continue
            threading.Thread(target=handle, args=(conn,), daemon=True).start()

    threading.Thread(target=loop, daemon=True).start()


# ----------------------------------------------------------------------------- client


def masked_frame(opcode: int, payload: bytes) -> bytes:
    mask = os.urandom(4)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    length = len(payload)
    if length < 126:
        header = bytes([0x80 | opcode, 0x80 | length])
    elif length < 65536:
        header = bytes([0x80 | opcode, 0x80 | 126]) + struct.pack(">H", length)
    else:
        header = bytes([0x80 | opcode, 0x80 | 127]) + struct.pack(">Q", length)
    return header + mask + masked


def read_message(sock: socket.socket) -> tuple:
    """Reads frames until one logical message is complete; returns (opcode, payload)."""
    opcode = 0
    payload = b""
    while True:
        fin, frame_opcode, frame_payload = read_frame(sock)
        if frame_opcode in (0x8, 0x9, 0xA):
            return frame_opcode, frame_payload
        if frame_opcode in (0x1, 0x2):
            opcode = frame_opcode
            payload = frame_payload
        elif frame_opcode == 0x0:
            payload += frame_payload
        if fin:
            return opcode, payload


def handshake(sock: socket.socket, host: str, port: int, path: str) -> str:
    key = base64.b64encode(b"proxydog-ws-test").decode()
    sock.sendall(
        (
            f"GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\n"
            "Upgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
            "User-Agent: ProxyDog-WS-Test\r\n\r\n"
        ).encode()
    )
    response = read_until(sock, b"\r\n\r\n")
    return response.split(b"\r\n")[0].decode()


def run_client(proxy_port: int, host: str, port: int, use_tls: bool) -> dict:
    raw = socket.create_connection(("127.0.0.1", proxy_port), timeout=15)
    if use_tls:
        raw.sendall(f"CONNECT {host}:{port} HTTP/1.1\r\nHost: {host}:{port}\r\n\r\n".encode())
        head = read_until(raw, b"\r\n\r\n")
        if b"200" not in head.split(b"\r\n")[0]:
            raise RuntimeError(f"CONNECT failed: {head[:80]!r}")
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        sock = context.wrap_socket(raw, server_hostname=host)
        status = handshake(sock, host, port, "/chat")
    else:
        sock = raw
        key = base64.b64encode(b"proxydog-ws-test").decode()
        sock.sendall(
            (
                f"GET http://{host}:{port}/chat HTTP/1.1\r\nHost: {host}:{port}\r\n"
                "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
                "User-Agent: ProxyDog-WS-Test\r\n\r\n"
            ).encode()
        )
        response = read_until(sock, b"\r\n\r\n")
        status = response.split(b"\r\n")[0].decode()

    if "101" not in status:
        raise RuntimeError(f"upgrade failed: {status}")

    # 1) the server's fragmented greeting must arrive as one reassembled message
    greeting_opcode, greeting = read_message(sock)

    # 2) a normal text exchange
    sock.sendall(masked_frame(0x1, b"hello-from-client"))
    echo_opcode, echo = read_message(sock)

    # 3) a 1 MB binary frame (capture is expected to truncate at 512 KB)
    big = b"\xab" * (1024 * 1024)
    sock.sendall(masked_frame(0x2, big))
    big_echo_opcode, big_echo = read_message(sock)

    # 4) close handshake
    sock.sendall(masked_frame(0x8, struct.pack(">H", 1000)))
    try:
        read_message(sock)
    except OSError:
        pass
    sock.close()

    return {
        "status": status,
        "greeting": greeting.decode("utf-8", "replace"),
        "echo": echo.decode("utf-8", "replace"),
        "big_echo_bytes": len(big_echo),
        "greeting_opcode": greeting_opcode,
        "echo_opcode": echo_opcode,
    }


def main() -> int:
    mode = sys.argv[1]
    if mode == "server":
        ws_server(int(sys.argv[2]), None, None)
        time.sleep(300)
    elif mode == "server-tls":
        ws_server(int(sys.argv[2]), sys.argv[3], sys.argv[4])
        time.sleep(300)
    elif mode in ("plain", "wss"):
        summary = run_client(int(sys.argv[2]), sys.argv[3], int(sys.argv[4]), use_tls=(mode == "wss"))
        print(json.dumps(summary), flush=True)
    else:
        print(f"unknown mode {mode}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
