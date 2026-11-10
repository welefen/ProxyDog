#!/usr/bin/env bash
# Tests HTTP/2 MITM support: the proxy must negotiate h2 with the client, capture h2
# exchanges with http_version "HTTP/2", and keep HTTP/1.1 working.
#
#   ./scripts/test_http2.sh
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/env.sh"

PORT="${PORT:-19005}"
WORK="$ROOT/.build-cache/test-http2"
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

wait_for_pattern() {
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

echo "== Starting ProxyDog =="
"$BIN" --headless --port "$PORT" --print-bodies --out "$WORK/captures.jsonl" >"$WORK/proxy.log" 2>&1 &
PROXY_PID=$!
if wait_for_pattern "$WORK/proxy.log" '"type":"ready"' 20; then
  pass "ProxyDog reported ready"
else
  fail "ProxyDog did not become ready"; cat "$WORK/proxy.log"; exit 1
fi

PROXY_URL="http://127.0.0.1:$PORT"

echo "== Case: HTTP/2 through the MITM proxy =="
H2_OUT=$(curl -s -k --http2 -o /dev/null --max-time 30 -x "$PROXY_URL" \
  -w '%{http_version} %{http_code}' https://example.com/ 2>"$WORK/curl-h2.log")
echo "  curl reported: $H2_OUT"
case "$H2_OUT" in
  "2 200"*) pass "client negotiated HTTP/2 and got 200" ;;
  *) fail "expected '2 200', got '$H2_OUT' ($(head -c 200 "$WORK/curl-h2.log"))" ;;
esac

echo "== Case: HTTP/1.1 still works through the same proxy =="
H1_OUT=$(curl -s -k --http1.1 -o /dev/null --max-time 30 -x "$PROXY_URL" \
  -w '%{http_version} %{http_code}' https://example.com/ 2>"$WORK/curl-h1.log")
echo "  curl reported: $H1_OUT"
case "$H1_OUT" in
  "1.1 200"*) pass "HTTP/1.1 capture path still works" ;;
  *) fail "expected '1.1 200', got '$H1_OUT'" ;;
esac

echo "== Case: HTTP/2 capture recorded with http_version =="
sleep 1
python3 - "$WORK/captures.jsonl" <<'PY'
import json
import sys

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
h2 = [c for c in captures.values() if c.get("http_version") == "HTTP/2"]
h1 = [c for c in captures.values() if c.get("http_version") == "HTTP/1.1"]
if not h2:
    problems.append("no capture had http_version HTTP/2")
else:
    example = [c for c in h2 if "example.com" in (c.get("url") or "")]
    if not example:
        problems.append("the HTTP/2 capture for example.com is missing")
    else:
        capture = example[0]
        if capture.get("status") != 200:
            problems.append(f"h2 capture status was {capture.get('status')}")
        prefix = capture.get("body_prefix") or ""
        if "Example Domain" not in prefix:
            problems.append(f"h2 capture body was not readable: {prefix!r}")
if not h1:
    problems.append("no capture had http_version HTTP/1.1")

if problems:
    print("  FAIL  h2 capture assertions")
    for problem in problems:
        print("        -", problem)
    for capture in captures.values():
        print("        ", capture.get("http_version"), capture.get("status"), (capture.get("url") or "")[:80])
    sys.exit(1)
print(f"  PASS  h2 capture assertions ({len(h2)} HTTP/2, {len(h1)} HTTP/1.1 exchanges)")
PY
if [ $? -eq 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

echo
echo "== Summary: $PASS passed, $FAIL failed =="
if [ "$FAIL" -gt 0 ]; then
  echo "Proxy log:"; tail -30 "$WORK/proxy.log"
  echo "curl h2 stderr:"; tail -10 "$WORK/curl-h2.log"
  exit 1
fi
exit 0
