#!/usr/bin/env python3
"""Minimal dual-protocol proxy used to test ProxyDog's upstream chaining.

One listener speaks both protocols, picked by the first byte:
  * HTTP:   "CONNECT host:port" -> 200 + byte relay
  * SOCKS5: no-auth greeting + CONNECT -> success reply + byte relay

Every tunnel is appended to the --log file ("CONNECT host:port" or "SOCKS5 host:port")
so tests can assert that ProxyDog really used the upstream proxy.

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


def read_exactly(stream: socket.socket, count: int) -> bytes:
    data = b""
    while len(data) < count:
        chunk = stream.recv(count - len(data))
        if not chunk:
            raise OSError("connection closed")
        data += chunk
    return data


def relay_tunnel(client: socket.socket, upstream: socket.socket, request_leftover: bytes, log_path: str, log_line: str) -> None:
    with open(log_path, "a", encoding="utf-8") as log:
        log.write(log_line + "\n")
        log.flush()
    client.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n" if log_line.startswith("CONNECT") else b"")
    if request_leftover:
        upstream.sendall(request_leftover)
    threading.Thread(target=relay, args=(upstream, client), daemon=True).start()
    relay(client, upstream)
    upstream.close()


def handle_socks5(client: socket.socket, first_byte: bytes, log_path: str) -> None:
    greeting = first_byte + read_exactly(client, 1)
    version, methods_count = greeting[0], greeting[1]
    if version != 0x05:
        return
    methods = read_exactly(client, methods_count)
    if 0x00 not in methods:
        client.sendall(b"\x05\xff")
        return
    client.sendall(b"\x05\x00")

    head = read_exactly(client, 4)
    version, command, _reserved, address_type = head
    if version != 0x05:
        return
    if command != 0x01:  # only CONNECT
        client.sendall(b"\x05\x07\x00\x01\x00\x00\x00\x00\x00\x00")
        return

    if address_type == 0x01:      # IPv4
        host = socket.inet_ntoa(read_exactly(client, 4))
    elif address_type == 0x03:    # domain name
        length = read_exactly(client, 1)[0]
        host = read_exactly(client, length).decode("latin-1")
    elif address_type == 0x05:    # IPv6
        host = socket.inet_ntop(socket.AF_INET6, read_exactly(client, 16))
    else:
        client.sendall(b"\x05\x08\x00\x01\x00\x00\x00\x00\x00\x00")
        return
    port = int.from_bytes(read_exactly(client, 2), "big")

    try:
        upstream = socket.create_connection((host, port), timeout=15)
    except OSError:
        client.sendall(b"\x05\x05\x00\x01\x00\x00\x00\x00\x00\x00")
        return

    with open(log_path, "a", encoding="utf-8") as log:
        log.write(f"SOCKS5 {host}:{port}\n")
        log.flush()
    client.sendall(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
    threading.Thread(target=relay, args=(upstream, client), daemon=True).start()
    relay(client, upstream)
    upstream.close()


def handle(client: socket.socket, log_path: str) -> None:
    try:
        client.settimeout(20)
        first = read_exactly(client, 1)
        if first == b"\x05":
            handle_socks5(client, first, log_path)
            return

        buffer = first
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

        relay_tunnel(client, upstream, leftover, log_path, f"CONNECT {target}")
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
