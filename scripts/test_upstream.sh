#!/usr/bin/env bash
# Tests ProxyDog's upstream-proxy chaining (ProxyDog -> local HTTP CONNECT proxy -> internet).
#
#   ./scripts/test_upstream.sh
#   UPSTREAM_REAL=127.0.0.1:1235 ./scripts/test_upstream.sh   # also chain through a real proxy
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/env.sh"

PORT="${PORT:-18981}"
UPSTREAM_PORT="${UPSTREAM_PORT:-18991}"
WORK="$ROOT/.build-cache/test-upstream"
BIN="$ROOT/.build/debug/ProxyDog"
PROXY_PID=""
UPSTREAM_PID=""

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

cleanup() {
  for pid in "$PROXY_PID" "$UPSTREAM_PID"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}
trap cleanup EXIT

wait_for_file() { # file pattern timeout-seconds
  local file="$1" pattern="$2" timeout="${3:-15}"
  local deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ -f "$file" ] && grep -q "$pattern" "$file" 2>/dev/null; then return 0; fi
    sleep 0.2
  done
  return 1
}

start_proxy() { # out-file + extra args
  local out="$1"; shift
  "$BIN" --headless --port "$PORT" --out "$out" "$@" >"$WORK/proxy.log" 2>&1 &
  PROXY_PID=$!
  wait_for_file "$WORK/proxy.log" '"type":"ready"' 20
}

rm -rf "$WORK"; mkdir -p "$WORK"

echo "== Building =="
if ! "$ROOT/scripts/build.sh" >"$WORK/build.log" 2>&1; then
  "$ROOT/scripts/build.sh" 2>&1 | tail -20
  exit 1
fi

echo "== Starting local CONNECT proxy on 127.0.0.1:$UPSTREAM_PORT =="
python3 "$ROOT/scripts/test_upstream_proxy.py" --port "$UPSTREAM_PORT" --log "$WORK/upstream.log" >"$WORK/upstream-server.log" 2>&1 &
UPSTREAM_PID=$!
if ! wait_for_file "$WORK/upstream-server.log" '"type":"ready"' 10; then
  echo "Could not start the test upstream proxy"; cat "$WORK/upstream-server.log"; exit 1
fi
pass "test upstream proxy is listening"

echo "== Starting ProxyDog with --upstream 127.0.0.1:$UPSTREAM_PORT =="
if start_proxy "$WORK/chained.jsonl" --upstream "127.0.0.1:$UPSTREAM_PORT"; then
  pass "ProxyDog reported ready with an upstream proxy"
else
  fail "ProxyDog did not become ready with an upstream proxy"; cat "$WORK/proxy.log"; exit 1
fi

PROXY_URL="http://127.0.0.1:$PORT"

echo "== Case: plain HTTP through the chain =="
HTTP_CODE=$(curl -s -o "$WORK/http-body.txt" -w '%{http_code}' --max-time 25 -x "$PROXY_URL" http://example.com/ 2>"$WORK/http-err.txt")
if [ "$HTTP_CODE" = "200" ] && grep -qi "example" "$WORK/http-body.txt"; then
  pass "GET http://example.com -> 200 through the chain"
else
  fail "GET http://example.com -> $HTTP_CODE ($(head -c 200 "$WORK/http-err.txt"))"
fi

echo "== Case: HTTPS interception through the chain =="
HTTPS_CODE=$(curl -s -k -o "$WORK/https-body.txt" -w '%{http_code}' --max-time 30 -x "$PROXY_URL" https://example.com/ 2>"$WORK/https-err.txt")
if [ "$HTTPS_CODE" = "200" ] && grep -qi "example" "$WORK/https-body.txt"; then
  pass "GET https://example.com -> 200 decrypted through the chain"
else
  fail "GET https://example.com -> $HTTPS_CODE ($(head -c 200 "$WORK/https-err.txt"))"
fi

echo "== Case: upstream proxy really carried the tunnel =="
sleep 0.5
if grep -q "CONNECT example.com:443" "$WORK/upstream.log" 2>/dev/null; then
  pass "upstream proxy saw CONNECT example.com:443"
else
  fail "upstream proxy never saw the CONNECT for example.com:443"
  cat "$WORK/upstream.log" 2>/dev/null | head -5
fi
if grep -q "CONNECT example.com:80" "$WORK/upstream.log" 2>/dev/null; then
  pass "upstream proxy saw CONNECT example.com:80"
else
  fail "upstream proxy never saw the CONNECT for example.com:80"
fi

echo "== Case: captures are the client-visible exchanges =="
sleep 0.5
python3 - "$WORK/chained.jsonl" <<'PY'
import json
import sys

records = {}
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        continue
    if event.get("type") == "capture":
        records[event["id"]] = event

problems = []
https = [r for r in records.values() if r.get("url", "").startswith("https://example.com")]
http = [r for r in records.values() if r.get("url", "").startswith("http://example.com")]
if not http or not any(r.get("status") == 200 for r in http):
    problems.append("plain HTTP capture missing or not 200")
if not https or not any(r.get("status") == 200 for r in https):
    problems.append("HTTPS capture missing or not 200")
if not any(r.get("intercepted") is True for r in https):
    problems.append("HTTPS capture was not decrypted")
if any(r.get("host") == "127.0.0.1" for r in records.values()):
    problems.append("the upstream proxy leaked into the captures as a host")

if problems:
    print("  FAIL  capture assertions")
    for problem in problems:
        print("        -", problem)
    for record in records.values():
        print("        ", record.get("method"), record.get("url"), record.get("status"))
    sys.exit(1)
print(f"  PASS  capture assertions ({len(records)} exchanges)")
PY
if [ $? -eq 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

echo "== Case: unreachable upstream fails cleanly =="
kill "$PROXY_PID" 2>/dev/null || true
wait "$PROXY_PID" 2>/dev/null || true
PROXY_PID=""
if start_proxy "$WORK/failing.jsonl" --upstream "127.0.0.1:9"; then
  curl -s -o /dev/null --max-time 12 -x "$PROXY_URL" http://example.com/ >/dev/null 2>&1
  sleep 0.8
  if grep -qi "upstream" "$WORK/failing.jsonl" 2>/dev/null; then
    pass "unreachable upstream produced a readable upstream error"
  elif grep -q '"state":"failed"' "$WORK/failing.jsonl" 2>/dev/null; then
    pass "unreachable upstream produced a failed capture"
  else
    fail "unreachable upstream did not produce a failed capture"
    tail -3 "$WORK/failing.jsonl" 2>/dev/null
  fi
else
  fail "ProxyDog did not start with an unreachable upstream"
fi

if [ -n "${UPSTREAM_REAL:-}" ]; then
  echo "== Case: chain through the real proxy $UPSTREAM_REAL =="
  kill "$PROXY_PID" 2>/dev/null || true
  wait "$PROXY_PID" 2>/dev/null || true
  PROXY_PID=""
  if start_proxy "$WORK/real.jsonl" --upstream "$UPSTREAM_REAL"; then
    CODE=$(curl -s -k -o /dev/null -w '%{http_code}' --max-time 30 -x "$PROXY_URL" https://example.com/ 2>/dev/null)
    if [ "$CODE" = "200" ]; then
      pass "HTTPS through the real upstream proxy -> 200"
    else
      fail "HTTPS through the real upstream proxy -> $CODE"
    fi
  else
    fail "ProxyDog did not start with the real upstream proxy"
  fi
fi

echo
echo "== Summary: $PASS passed, $FAIL failed =="
if [ "$FAIL" -gt 0 ]; then
  echo "Proxy log:"; tail -20 "$WORK/proxy.log"
  exit 1
fi
exit 0
