#!/usr/bin/env python3
"""Minimal HTTP CONNECT proxy used to test ProxyDog's upstream chaining.

Listens on 127.0.0.1, answers "CONNECT host:port" with 200 and relays bytes in both
directions. Every CONNECT is appended to the --log file so tests can assert that
ProxyDog actually used the upstream proxy.

Usage:
    python3 scripts/test_upstream_proxy.py --port 18990 --log /tmp/upstream.log
"""
import argparse
import socket
import sys
import threading


def relay(source: socket.socket, destination: socket.socket) -> None:
    try:
        while True:
            data = source.recv(65536)
            if not data:
                break
            destination.sendall(data)
    except OSError:
        pass
    finally:
        try:
            destination.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def handle(client: socket.socket, log_path: str) -> None:
    try:
        client.settimeout(20)
        buffer = b""
        while b"\r\n\r\n" not in buffer:
            chunk = client.recv(65536)
            if not chunk:
                return
            buffer += chunk
            if len(buffer) > 65536:
                return

        head, _, leftover = buffer.partition(b"\r\n\r\n")
        request_line = head.decode("latin-1").split("\r\n", 1)[0]
        parts = request_line.split(" ")
        if len(parts) != 3 or parts[0].upper() != "CONNECT":
            client.sendall(b"HTTP/1.1 501 Not Implemented\r\nContent-Length: 0\r\n\r\n")
            return

        target = parts[1]
        host, _, port_text = target.rpartition(":")
        try:
            port = int(port_text)
        except ValueError:
            client.sendall(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
            return

        try:
            upstream = socket.create_connection((host, port), timeout=15)
        except OSError:
            client.sendall(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
            return

        with open(log_path, "a", encoding="utf-8") as log:
            log.write(f"CONNECT {target}\n")
            log.flush()

        client.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
        if leftover:
            upstream.sendall(leftover)

        threading.Thread(target=relay, args=(upstream, client), daemon=True).start()
        relay(client, upstream)
        upstream.close()
    except OSError:
        pass
    finally:
        try:
            client.close()
        except OSError:
            pass


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18990)
    parser.add_argument("--log", default="/tmp/upstream.log")
    args = parser.parse_args()

    open(args.log, "a", encoding="utf-8").close()

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", args.port))
    server.listen(64)
    setbuf = getattr(sys.stdout, "reconfigure", None)
    if setbuf:
        sys.stdout.reconfigure(line_buffering=True)
    print(f'{{"type":"ready","port":{args.port}}}', flush=True)

    try:
        while True:
            client, _ = server.accept()
            threading.Thread(target=handle, args=(client, args.log), daemon=True).start()
    except KeyboardInterrupt:
        pass
    finally:
        server.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
