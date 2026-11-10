#!/usr/bin/env bash
# Tests that compressed HTTP bodies are decoded for the inspector and that intercepted
# requests ask upstream for an encoding macOS can decode (gzip instead of br/zstd).
#
#   ./scripts/test_compression.sh
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/env.sh"

PORT="${PORT:-18982}"
UPSTREAM_PORT="${UPSTREAM_PORT:-18984}"
WORK="$ROOT/.build-cache/test-compression"
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

echo "== Starting a gzip-aware test server on 127.0.0.1:$UPSTREAM_PORT =="
python3 - "$UPSTREAM_PORT" "$WORK" <<'PY' >"$WORK/upstream.log" 2>&1 &
import gzip
import http.server
import json
import sys

port = int(sys.argv[1])
work = sys.argv[2]

HTML = "<!doctype html><html><head><title>t</title></head><body><h1>Hello ProxyDog compression</h1></body></html>"
JSON_BODY = json.dumps({"ok": True, "message": "decoded json body"}).encode()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        accept = self.headers.get("Accept-Encoding", "")
        with open(f"{work}/accept-encoding.log", "a", encoding="utf-8") as log:
            log.write(self.path + " " + accept + "\n")
        if self.path.startswith("/html"):
            body = HTML.encode()
            content_type = "text/html; charset=utf-8"
        else:
            body = JSON_BODY
            content_type = "application/json"
        if "gzip" in accept.lower():
            body = gzip.compress(body)
            encoding = "gzip"
        else:
            encoding = "identity"
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Encoding", encoding)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):  # keep the log clean
        pass


server = http.server.HTTPServer(("127.0.0.1", port), Handler)
print(json.dumps({"type": "ready", "port": port}), flush=True)
server.serve_forever()
PY
UPSTREAM_PID=$!
if wait_for_pattern "$WORK/upstream.log" '"type": "ready"' 10; then
  pass "gzip test server is listening"
else
  fail "could not start the gzip test server"; cat "$WORK/upstream.log"; exit 1
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
UPSTREAM_URL="http://127.0.0.1:$UPSTREAM_PORT"

echo "== Case: gzip HTML body =="
# Ask for br to prove the proxy rewrites Accept-Encoding to something it can decode.
curl -s -o /dev/null --max-time 15 -x "$PROXY_URL" -H "Accept-Encoding: br, gzip" "$UPSTREAM_URL/html"
echo "== Case: gzip JSON body =="
curl -s -o /dev/null --max-time 15 -x "$PROXY_URL" -H "Accept-Encoding: gzip, br" "$UPSTREAM_URL/json"
sleep 0.8

echo "== Case: upstream was asked for a decodable encoding =="
if grep -q "gzip" "$WORK/accept-encoding.log" 2>/dev/null && ! grep -qi "br" "$WORK/accept-encoding.log" 2>/dev/null; then
  pass "Accept-Encoding rewritten to gzip (br stripped)"
else
  fail "unexpected upstream Accept-Encoding: $(cat "$WORK/accept-encoding.log" 2>/dev/null)"
fi

echo "== Case: captured bodies were decoded =="
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
html = [c for c in captures.values() if c.get("url", "").endswith("/html")]
json_capture = [c for c in captures.values() if c.get("url", "").endswith("/json")]
if not html:
    problems.append("no capture for the html request")
elif "Hello ProxyDog compression" not in (html[0].get("body_prefix") or ""):
    problems.append(f"html body was not decoded: {html[0].get('body_prefix')!r}")
if not json_capture:
    problems.append("no capture for the json request")
elif "decoded json body" not in (json_capture[0].get("body_prefix") or ""):
    problems.append(f"json body was not decoded: {json_capture[0].get('body_prefix')!r}")
if any(c.get("body_prefix") and "�" in c["body_prefix"] for c in captures.values()):
    problems.append("decoded body still contains replacement characters")

if problems:
    print("  FAIL  decode assertions")
    for problem in problems:
        print("        -", problem)
    for capture in captures.values():
        print("        ", capture.get("url"), capture.get("content_encoding"), repr(capture.get("body_prefix"))[:120])
    sys.exit(1)
print(f"  PASS  decode assertions ({len(captures)} exchanges)")
PY
if [ $? -eq 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

echo
echo "== Summary: $PASS passed, $FAIL failed =="
if [ "$FAIL" -gt 0 ]; then
  echo "Proxy log:"; tail -20 "$WORK/proxy.log"
  echo "Upstream log:"; tail -10 "$WORK/upstream.log"
  exit 1
fi
exit 0
