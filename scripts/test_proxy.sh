#!/usr/bin/env bash
# End-to-end test for the ProxyDog proxy engine.
#
#   ./scripts/test_proxy.sh            # builds, runs headless proxy, asserts captures
#   PORT=18899 ./scripts/test_proxy.sh
#
# Requires curl (system) and python3. Exits non-zero when any case fails.
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/env.sh"

PORT="${PORT:-18899}"
WORK="$ROOT/.build-cache/test-proxy"
CAPTURES="$WORK/captures.jsonl"
LOG="$WORK/server.log"
BIN="$ROOT/.build/debug/ProxyDog"

PASS=0
FAIL=0
SERVER_PID=""

pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "== Building =="
if ! "$ROOT/scripts/build.sh" >"$WORK.build.log" 2>&1; then
  "$ROOT/scripts/build.sh" 2>&1 | tail -20
  echo "Build failed"
  exit 1
fi

rm -rf "$WORK"
mkdir -p "$WORK"

echo "== Starting headless proxy on 127.0.0.1:$PORT =="
"$BIN" --headless --port "$PORT" --out "$CAPTURES" >"$LOG" 2>&1 &
SERVER_PID=$!

READY=0
for _ in $(seq 1 60); do
  if grep -q '"type":"ready"' "$LOG" 2>/dev/null; then READY=1; break; fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then break; fi
  sleep 0.25
done
if [ "$READY" = "1" ]; then
  pass "proxy reported ready"
else
  fail "proxy never became ready"
  cat "$LOG"
  exit 1
fi

PROXY="http://127.0.0.1:$PORT"

echo "== Case: plain HTTP =="
HTTP_CODE=$(curl -s -o "$WORK/http-body.txt" -w '%{http_code}' --max-time 20 -x "$PROXY" http://example.com/ 2>"$WORK/http-err.txt")
if [ "$HTTP_CODE" = "200" ] && grep -qi "example" "$WORK/http-body.txt"; then
  pass "GET http://example.com -> 200 with body"
else
  fail "GET http://example.com -> $HTTP_CODE ($(head -c 200 "$WORK/http-err.txt"))"
fi

echo "== Case: HTTPS interception =="
HTTPS_CODE=$(curl -s -k -o "$WORK/https-body.txt" -w '%{http_code}' --max-time 25 -x "$PROXY" https://example.com/ 2>"$WORK/https-err.txt")
if [ "$HTTPS_CODE" = "200" ] && grep -qi "example" "$WORK/https-body.txt"; then
  pass "GET https://example.com -> 200 with body"
else
  fail "GET https://example.com -> $HTTPS_CODE ($(head -c 200 "$WORK/https-err.txt"))"
fi

echo "== Case: HTTPS POST body =="
POST_CODE=$(curl -s -k -o /dev/null -w '%{http_code}' --max-time 25 \
  -x "$PROXY" -X POST -H 'Content-Type: application/json' \
  --data '{"proxydog":"test","n":42}' https://httpbin.org/post 2>"$WORK/post-err.txt")
if [ "$POST_CODE" = "200" ]; then
  pass "POST https://httpbin.org/post -> 200"
else
  echo "  SKIP  POST https://httpbin.org/post -> $POST_CODE (network/endpoint may be unavailable)"
fi

echo "== Case: unreachable upstream =="
curl -s -o /dev/null --max-time 15 -x "$PROXY" http://proxy-dog-unreachable.invalid/ >/dev/null 2>&1
sleep 0.6
if grep -q '"error"' "$CAPTURES" 2>/dev/null; then
  pass "unreachable host produced a failed capture"
else
  fail "unreachable host did not produce a failed capture"
fi

echo "== Case: capture records =="
sleep 0.8
python3 - "$CAPTURES" <<'PY'
import json, sys

path = sys.argv[1]
records = {}
for line in open(path):
    line = line.strip()
    if not line:
        continue
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        continue
    if event.get("type") != "capture":
        continue
    records[event["id"]] = event

failures = []

https = [r for r in records.values() if r.get("url", "").startswith("https://example.com")]
http = [r for r in records.values() if r.get("url", "").startswith("http://example.com")]
posts = [r for r in records.values() if "httpbin.org" in r.get("url", "")]

if not http:
    failures.append("no capture for http://example.com")
elif not any(r.get("status") == 200 for r in http):
    failures.append("http://example.com capture has no status 200")

if not https:
    failures.append("no capture for https://example.com")
else:
    if not any(r.get("status") == 200 for r in https):
        failures.append("https://example.com capture has no status 200")
    if not any(r.get("intercepted") is True for r in https):
        failures.append("https://example.com capture was not decrypted (intercepted != true)")

if posts and not any(r.get("status") == 200 for r in posts):
    failures.append("httpbin.org capture has no status 200")

if failures:
    print("  FAIL  capture assertions")
    for failure in failures:
        print("        -", failure)
    print("  captures seen:")
    for record in records.values():
        print("        ", record.get("method"), record.get("url"), record.get("status"), record.get("state"))
    sys.exit(1)

print(f"  PASS  capture assertions ({len(records)} exchanges recorded)")
PY
if [ $? -eq 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

echo "== Case: restart on same port =="
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
sleep 0.5
"$BIN" --headless --port "$PORT" --out "$WORK/captures2.jsonl" >"$WORK/server2.log" 2>&1 &
SERVER_PID=$!
READY2=0
for _ in $(seq 1 40); do
  if grep -q '"type":"ready"' "$WORK/server2.log" 2>/dev/null; then READY2=1; break; fi
  sleep 0.25
done
if [ "$READY2" = "1" ] && curl -s -o /dev/null --max-time 15 -x "$PROXY" http://example.com/; then
  pass "proxy restarts and serves on the same port"
else
  fail "proxy did not restart on the same port"
  tail -20 "$WORK/server2.log"
fi

echo
echo "== Summary: $PASS passed, $FAIL failed =="
if [ "$FAIL" -gt 0 ]; then
  echo "Server log:"
  tail -40 "$LOG"
  exit 1
fi
exit 0
