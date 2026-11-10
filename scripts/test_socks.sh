#!/usr/bin/env bash
# Tests ProxyDog's SOCKS5 listener (apps that only speak SOCKS5) plus SOCKS5 upstream chaining.
#
#   ./scripts/test_socks.sh
#   UPSTREAM_SOCKS_REAL=socks5://127.0.0.1:1234 ./scripts/test_socks.sh   # also chain via the real VPN SOCKS port
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/env.sh"

PORT="${PORT:-18983}"
SOCKS_PORT="${SOCKS_PORT:-18994}"
UPSTREAM_PORT="${UPSTREAM_PORT:-18993}"
WORK="$ROOT/.build-cache/test-socks"
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

wait_for_pattern() { # file pattern timeout
  local file="$1" pattern="$2" timeout="${3:-20}"
  local deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ -f "$file" ] && grep -q "$pattern" "$file" 2>/dev/null; then return 0; fi
    sleep 0.2
  done
  return 1
}

start_proxy() { # out-file + extra args
  local out="$1"; shift
  "$BIN" --headless --port "$PORT" --socks-port "$SOCKS_PORT" --out "$out" "$@" >"$WORK/proxy.log" 2>&1 &
  PROXY_PID=$!
  wait_for_pattern "$WORK/proxy.log" '"type":"ready"' 20
}

rm -rf "$WORK"; mkdir -p "$WORK"

echo "== Building =="
if ! "$ROOT/scripts/build.sh" >"$WORK/build.log" 2>&1; then
  "$ROOT/scripts/build.sh" 2>&1 | tail -20
  exit 1
fi

echo "== Starting reference dual-protocol proxy on 127.0.0.1:$UPSTREAM_PORT =="
python3 "$ROOT/scripts/test_upstream_proxy.py" --port "$UPSTREAM_PORT" --log "$WORK/upstream.log" >"$WORK/upstream-server.log" 2>&1 &
UPSTREAM_PID=$!
if wait_for_pattern "$WORK/upstream-server.log" '"type":"ready"' 10; then
  pass "reference proxy is listening"
else
  fail "could not start the reference proxy"; cat "$WORK/upstream-server.log"; exit 1
fi

echo "== Starting ProxyDog with SOCKS5 listener on 127.0.0.1:$SOCKS_PORT =="
if start_proxy "$WORK/listener.jsonl"; then
  pass "ProxyDog reported ready with the SOCKS5 listener"
else
  fail "ProxyDog did not become ready"; cat "$WORK/proxy.log"; exit 1
fi
sleep 0.6

echo "== Case: HTTPS through the SOCKS5 listener (MITM) =="
CODE=$(curl -s -k -o "$WORK/socks-https.txt" -w '%{http_code}' --max-time 30 --socks5-hostname "127.0.0.1:$SOCKS_PORT" https://example.com/ 2>"$WORK/socks-https-err.txt")
if [ "$CODE" = "200" ] && grep -qi "example" "$WORK/socks-https.txt"; then
  pass "curl --socks5-hostname https://example.com -> 200"
else
  fail "curl --socks5-hostname https://example.com -> $CODE ($(head -c 200 "$WORK/socks-https-err.txt"))"
fi

echo "== Case: plain HTTP through the SOCKS5 listener =="
CODE=$(curl -s -o "$WORK/socks-http.txt" -w '%{http_code}' --max-time 25 --socks5-hostname "127.0.0.1:$SOCKS_PORT" http://example.com/ 2>"$WORK/socks-http-err.txt")
if [ "$CODE" = "200" ] && grep -qi "example" "$WORK/socks-http.txt"; then
  pass "curl --socks5-hostname http://example.com -> 200"
else
  fail "curl --socks5-hostname http://example.com -> $CODE ($(head -c 200 "$WORK/socks-http-err.txt"))"
fi

echo "== Case: captures from the SOCKS5 listener =="
sleep 0.8
python3 - "$WORK/listener.jsonl" <<'PY'
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

https = [r for r in records.values() if r.get("url", "").startswith("https://example.com")]
http = [r for r in records.values() if r.get("url", "").startswith("http://example.com")]
problems = []
if not https or not any(r.get("status") == 200 for r in https):
    problems.append("SOCKS5 HTTPS capture missing or not 200")
if not any(r.get("intercepted") is True for r in https):
    problems.append("SOCKS5 HTTPS capture was not decrypted")
if not http or not any(r.get("status") == 200 for r in http):
    problems.append("SOCKS5 HTTP capture missing or not 200")
if problems:
    print("  FAIL  capture assertions")
    for problem in problems:
        print("        -", problem)
    for record in records.values():
        print("        ", record.get("method"), record.get("url"), record.get("status"), record.get("intercepted"))
    sys.exit(1)
print(f"  PASS  capture assertions ({len(records)} exchanges)")
PY
if [ $? -eq 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

echo "== Case: SOCKS5 listener + SOCKS5 upstream chain =="
kill "$PROXY_PID" 2>/dev/null || true
wait "$PROXY_PID" 2>/dev/null || true
PROXY_PID=""
if start_proxy "$WORK/chained.jsonl" --upstream "socks5://127.0.0.1:$UPSTREAM_PORT"; then
  CODE=$(curl -s -k -o /dev/null -w '%{http_code}' --max-time 30 --socks5-hostname "127.0.0.1:$SOCKS_PORT" https://example.com/ 2>/dev/null)
  sleep 0.6
  if [ "$CODE" = "200" ] && grep -q "SOCKS5 example.com:443" "$WORK/upstream.log" 2>/dev/null; then
    pass "SOCKS5 listener -> SOCKS5 upstream -> 200 (upstream log confirms)"
  else
    fail "SOCKS5 listener -> SOCKS5 upstream failed (code=$CODE)"
  fi
else
  fail "ProxyDog did not start with SOCKS5 upstream"
fi

echo "== Case: failed upstream through the SOCKS5 listener =="
kill "$PROXY_PID" 2>/dev/null || true
wait "$PROXY_PID" 2>/dev/null || true
PROXY_PID=""
if start_proxy "$WORK/failing.jsonl" --upstream "socks5://127.0.0.1:9"; then
  curl -s -o /dev/null --max-time 12 --socks5-hostname "127.0.0.1:$SOCKS_PORT" http://example.com/ >/dev/null 2>&1
  sleep 0.8
  if grep -q '"state":"failed"' "$WORK/failing.jsonl" 2>/dev/null; then
    pass "unreachable SOCKS5 upstream produced a failed capture"
  else
    fail "unreachable SOCKS5 upstream did not produce a failed capture"
    tail -3 "$WORK/failing.jsonl" 2>/dev/null
  fi
else
  fail "ProxyDog did not start with an unreachable SOCKS5 upstream"
fi

if [ -n "${UPSTREAM_SOCKS_REAL:-}" ]; then
  echo "== Case: SOCKS5 listener chained through $UPSTREAM_SOCKS_REAL =="
  kill "$PROXY_PID" 2>/dev/null || true
  wait "$PROXY_PID" 2>/dev/null || true
  PROXY_PID=""
  if start_proxy "$WORK/real.jsonl" --upstream "$UPSTREAM_SOCKS_REAL"; then
    CODE=$(curl -s -k -o /dev/null -w '%{http_code}' --max-time 35 --socks5-hostname "127.0.0.1:$SOCKS_PORT" https://example.com/ 2>/dev/null)
    if [ "$CODE" = "200" ]; then
      pass "SOCKS5 listener through the real SOCKS5 VPN proxy -> 200"
    else
      fail "SOCKS5 listener through the real SOCKS5 VPN proxy -> $CODE"
    fi
  else
    fail "ProxyDog did not start with the real upstream SOCKS5 proxy"
  fi
fi

echo
echo "== Summary: $PASS passed, $FAIL failed =="
if [ "$FAIL" -gt 0 ]; then
  echo "Proxy log:"; tail -25 "$WORK/proxy.log"
  exit 1
fi
exit 0
