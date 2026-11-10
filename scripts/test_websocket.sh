#!/usr/bin/env bash
# Tests WebSocket capture through ProxyDog: handshake, MITM decryption and message decoding.
#
#   ./scripts/test_websocket.sh
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/env.sh"

PORT="${PORT:-18977}"
WS_PORT="${WS_PORT:-18996}"
WSS_PORT="${WSS_PORT:-18997}"
WORK="$ROOT/.build-cache/test-websocket"
BIN="$ROOT/.build/debug/ProxyDog"
PROXY_PID=""
WS_PID=""
WSS_PID=""

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

cleanup() {
  for pid in "$PROXY_PID" "$WS_PID" "$WSS_PID"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}
trap cleanup EXIT

wait_for_pattern() { # file pattern timeout
  local file="$1" pattern="$2" timeout="${3:-20}"
  local deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ -f "$file" ] && grep -q "$pattern" "$file" 2>/dev/null; then return 0; fi
    sleep 0.2
  done
  return 1
}

rm -rf "$WORK"; mkdir -p "$WORK"

echo "== Building =="
if ! "$ROOT/scripts/build.sh" >"$WORK/build.log" 2>&1; then
  "$ROOT/scripts/build.sh" 2>&1 | tail -20
  exit 1
fi

echo "== Generating a self-signed certificate for the wss echo server =="
openssl req -x509 -newkey rsa:2048 -sha256 -days 2 -nodes \
  -keyout "$WORK/ws.key" -out "$WORK/ws.crt" -subj "/CN=127.0.0.1" >/dev/null 2>&1

echo "== Starting WebSocket echo servers =="
python3 "$ROOT/scripts/ws_test.py" server "$WS_PORT" >"$WORK/ws-server.log" 2>&1 &
WS_PID=$!
python3 "$ROOT/scripts/ws_test.py" server-tls "$WSS_PORT" "$WORK/ws.crt" "$WORK/ws.key" >"$WORK/wss-server.log" 2>&1 &
WSS_PID=$!
if wait_for_pattern "$WORK/ws-server.log" '"type": "ready"' 10 && wait_for_pattern "$WORK/wss-server.log" '"type": "ready"' 10; then
  pass "ws and wss echo servers are listening"
else
  fail "could not start the WebSocket echo servers"
  cat "$WORK/ws-server.log" "$WORK/wss-server.log" 2>/dev/null
  exit 1
fi

echo "== Starting ProxyDog =="
"$BIN" --headless --port "$PORT" --out "$WORK/captures.jsonl" >"$WORK/proxy.log" 2>&1 &
PROXY_PID=$!
if wait_for_pattern "$WORK/proxy.log" '"type":"ready"' 20; then
  pass "ProxyDog reported ready"
else
  fail "ProxyDog did not become ready"; cat "$WORK/proxy.log"; exit 1
fi

echo "== Case: ws:// through the HTTP proxy =="
PLAIN_SUMMARY="$(python3 "$ROOT/scripts/ws_test.py" plain "$PORT" 127.0.0.1 "$WS_PORT" 2>"$WORK/plain-err.log")"
if echo "$PLAIN_SUMMARY" | grep -q '"status": "HTTP/1.1 101'; then
  pass "ws handshake upgraded (101) and frames echoed"
else
  fail "ws handshake/frames failed: $PLAIN_SUMMARY $(head -c 200 "$WORK/plain-err.log")"
fi

echo "== Case: wss:// through the MITM proxy =="
WSS_SUMMARY="$(python3 "$ROOT/scripts/ws_test.py" wss "$PORT" 127.0.0.1 "$WSS_PORT" 2>"$WORK/wss-err.log")"
if echo "$WSS_SUMMARY" | grep -q '"status": "HTTP/1.1 101'; then
  pass "wss handshake upgraded (101) through TLS interception"
else
  fail "wss handshake/frames failed: $WSS_SUMMARY $(head -c 200 "$WORK/wss-err.log")"
fi

echo "== Case: captures contain both exchanges =="
sleep 0.8
WS_PORT="$WS_PORT" WSS_PORT="$WSS_PORT" python3 - "$WORK/captures.jsonl" <<'PY'
import json
import os
import sys

ws_port = os.environ.get("WS_PORT", "18996")
wss_port = os.environ.get("WSS_PORT", "18997")

captures = {}
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        continue
    if event.get("type") == "capture":
        captures[event["id"]] = event

problems = []
ws = [c for c in captures.values() if c.get("url", "").startswith(f"http://127.0.0.1:{ws_port}/chat")]
wss = [c for c in captures.values() if c.get("url", "").startswith(f"https://127.0.0.1:{wss_port}/chat")]
if not ws:
    problems.append("no capture for the plain ws exchange")
elif not any(c.get("status") == 101 for c in ws):
    problems.append("plain ws exchange did not capture status 101")
if not wss:
    problems.append("no capture for the wss exchange")
else:
    if not any(c.get("status") == 101 for c in wss):
        problems.append("wss exchange did not capture status 101")
    if not any(c.get("intercepted") is True for c in wss):
        problems.append("wss exchange was not decrypted")

if problems:
    print("  FAIL  capture assertions")
    for problem in problems:
        print("        -", problem)
    for record in captures.values():
        print("        ", record.get("method"), record.get("url"), record.get("status"), record.get("intercepted"))
    sys.exit(1)
print("  PASS  capture assertions (101 for ws and decrypted wss)")
PY
if [ $? -eq 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

echo "== Case: WebSocket messages were decoded =="
WS_PORT="$WS_PORT" WSS_PORT="$WSS_PORT" python3 - "$WORK/captures.jsonl" <<'PY'
import json
import os
import sys

ws_port = os.environ.get("WS_PORT", "18996")
wss_port = os.environ.get("WSS_PORT", "18997")

messages = []
captures = {}
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        continue
    if event.get("type") == "ws_message":
        messages.append(event)
    elif event.get("type") == "capture":
        captures[event["id"]] = event

sent = [m for m in messages if m.get("direction") == "sent"]
received = [m for m in messages if m.get("direction") == "received"]
texts = [m.get("text", "") for m in messages]

problems = []
if not messages:
    problems.append("no ws_message events at all (frame decoding not wired up?)")
if not any("hello-from-client" in text for text in texts):
    problems.append("client text message was not captured")
if not any(m.get("direction") == "received" and "hello-from-client" in m.get("text", "") for m in messages):
    problems.append("echoed server -> client text message was not captured")
if not any("server-fragmented" in text for text in texts):
    problems.append("fragmented server message was not reassembled")
if not any(m.get("kind") == "close" for m in messages):
    problems.append("close frame was not captured")
if not any(m.get("truncated") is True for m in messages):
    problems.append("1 MB frame should be captured as truncated")
if not any(m.get("bytes", 0) >= 1024 * 1024 for m in messages):
    problems.append("1 MB frame should report the real byte count")
if not any(c.get("websocket") is True for c in captures.values()):
    problems.append("capture did not flag websocket:true")
if not any(c.get("ws_messages", 0) >= 5 for c in captures.values()):
    problems.append("capture ws_messages count is too low")

if problems:
    print("  FAIL  message assertions")
    for problem in problems:
        print("        -", problem)
    print(f"        saw {len(sent)} sent / {len(received)} received messages")
    for message in messages[:12]:
        print("        ", message)
    sys.exit(1)
print(f"  PASS  message assertions ({len(sent)} sent / {len(received)} received)")
PY
if [ $? -eq 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

echo
echo "== Summary: $PASS passed, $FAIL failed =="
if [ "$FAIL" -gt 0 ]; then
  echo "Proxy log:"; tail -25 "$WORK/proxy.log"
  exit 1
fi
exit 0
