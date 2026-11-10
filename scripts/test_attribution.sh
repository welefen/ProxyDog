#!/usr/bin/env bash
# Tests that ProxyDog attributes captured connections to the originating local app
# (libproc based process lookup for loopback clients).
#
#   ./scripts/test_attribution.sh
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/env.sh"

PORT="${PORT:-18976}"
SOCKS_PORT="${SOCKS_PORT:-18995}"
WORK="$ROOT/.build-cache/test-attribution"
BIN="$ROOT/.build/debug/ProxyDog"
PROXY_PID=""

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

cleanup() {
  [ -n "$PROXY_PID" ] && kill "$PROXY_PID" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT

rm -rf "$WORK"; mkdir -p "$WORK"

echo "== Building =="
if ! "$ROOT/scripts/build.sh" >"$WORK/build.log" 2>&1; then
  "$ROOT/scripts/build.sh" 2>&1 | tail -20
  exit 1
fi

echo "== Starting ProxyDog with HTTP + SOCKS5 listeners =="
"$BIN" --headless --port "$PORT" --socks-port "$SOCKS_PORT" --out "$WORK/captures.jsonl" >"$WORK/proxy.log" 2>&1 &
PROXY_PID=$!
READY=0
for _ in $(seq 1 80); do
  if grep -q '"type":"ready"' "$WORK/proxy.log" 2>/dev/null; then READY=1; break; fi
  sleep 0.25
done
if [ "$READY" != "1" ]; then
  fail "ProxyDog did not become ready"; cat "$WORK/proxy.log"; exit 1
fi
pass "ProxyDog reported ready"

PROXY_URL="http://127.0.0.1:$PORT"

echo "== Case: curl through the HTTP proxy =="
curl -s -o /dev/null --max-time 20 -x "$PROXY_URL" http://example.com/
curl -s -k -o /dev/null --max-time 25 -x "$PROXY_URL" https://example.com/
pass "curl requests completed"

echo "== Case: a long-lived Python client (keep-alive) =="
python3 - "$PORT" <<'PY' >"$WORK/python-client.log" 2>&1
import http.client
import sys

port = int(sys.argv[1])
conn = http.client.HTTPConnection("127.0.0.1", port, timeout=15)
for _ in range(2):
    conn.request("GET", "http://example.com/", headers={"User-Agent": "ProxyDog-Attribution-Test"})
    response = conn.getresponse()
    response.read()
conn.close()
print("python client done")
PY
if grep -q "python client done" "$WORK/python-client.log"; then
  pass "python keep-alive client completed"
else
  fail "python client failed: $(head -c 200 "$WORK/python-client.log")"
fi

echo "== Case: curl through the SOCKS5 listener =="
curl -s -o /dev/null --max-time 20 --socks5-hostname "127.0.0.1:$SOCKS_PORT" http://example.com/
pass "socks5 request completed"

echo "== Case: captures carry the originating app =="
sleep 1
python3 - "$WORK/captures.jsonl" <<'PY'
import json
import sys

# Keep the last state per exchange id (captures are upserted while attribution resolves).
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
with_app = [c for c in captures.values() if c.get("client_app")]
if not with_app:
    problems.append("no capture had a client_app attribution")

apps = {c.get("client_app") for c in with_app}
if "curl" not in apps:
    problems.append(f"curl was not attributed (apps seen: {sorted(a for a in apps if a)})")
if "Python" not in apps:
    problems.append(f"python was not attributed (apps seen: {sorted(a for a in apps if a)})")

pids = [c.get("client_pid") for c in with_app if isinstance(c.get("client_pid"), int)]
if not pids:
    problems.append("no capture had a numeric client_pid")

https = [c for c in with_app if c.get("intercepted") is True]
if not https:
    problems.append("MITM (https) capture was not attributed")

if problems:
    print("  FAIL  attribution assertions")
    for problem in problems:
        print("        -", problem)
    for capture in captures.values():
        print("        ", capture.get("method"), capture.get("url"), capture.get("client_app"), capture.get("client_pid"))
    sys.exit(1)
print(f"  PASS  attribution assertions ({len(with_app)} captures with app, apps: {sorted(a for a in apps if a)})")
PY
if [ $? -eq 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

echo
echo "== Summary: $PASS passed, $FAIL failed =="
if [ "$FAIL" -gt 0 ]; then
  echo "Proxy log:"; tail -20 "$WORK/proxy.log"
  exit 1
fi
exit 0
