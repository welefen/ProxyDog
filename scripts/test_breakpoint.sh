#!/usr/bin/env bash
# Tests breakpoints: matching exchanges pause, accept a manual body edit, resume or drop.
#
#   ./scripts/test_breakpoint.sh
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/env.sh"

PORT="${PORT:-19030}"
UPSTREAM_PORT="${UPSTREAM_PORT:-19031}"
WORK="$ROOT/.build-cache/test-breakpoint"
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

echo "== Starting upstream server on 127.0.0.1:$UPSTREAM_PORT =="
python3 - "$UPSTREAM_PORT" "$WORK" <<'PY' >"$WORK/upstream.log" 2>&1 &
import http.server
import json
import sys

port = int(sys.argv[1])
work = sys.argv[2]


class Handler(http.server.BaseHTTPRequestHandler):
    def _body(self):
        length = int(self.headers.get("Content-Length", "0") or 0)
        return self.rfile.read(length) if length else b""

    def _respond(self, status, body, content_type="text/plain"):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802
        with open(f"{work}/requests.log", "a", encoding="utf-8") as log:
            log.write(f"{self.command} {self.path}\n")
        if self.path.startswith("/pause-response"):
            self._respond(200, json.dumps({"code": 0, "from": "upstream"}), "application/json")
        elif self.path.startswith("/drop-request"):
            self._respond(200, "should-not-be-seen")
        elif self.path.startswith("/ignored"):
            self._respond(200, "ignored-upstream")
        else:
            self._respond(200, "upstream")

    def do_POST(self):  # noqa: N802
        body = self._body()
        with open(f"{work}/requests.log", "a", encoding="utf-8") as log:
            log.write(f"{self.command} {self.path} body={body.decode('utf-8', 'replace')}\n")
        self._respond(200, body, "text/plain")

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", port), Handler)
print(json.dumps({"type": "ready", "port": port}), flush=True)
server.serve_forever()
PY
UPSTREAM_PID=$!
if wait_for_pattern "$WORK/upstream.log" '"type": "ready"' 10; then
  pass "upstream server is listening"
else
  fail "could not start the upstream server"; cat "$WORK/upstream.log"; exit 1
fi

echo "== Writing breakpoint rules and decisions =="
python3 - "$WORK" <<'PY'
import json
import sys

work = sys.argv[1]
rules = [
    {
        "id": "11111111-1111-1111-1111-111111111111",
        "name": "Pause request",
        "isEnabled": True,
        "method": "POST",
        "urlPattern": "/pause-request",
        "breakOnRequest": True,
        "breakOnResponse": False,
    },
    {
        "id": "22222222-2222-2222-2222-222222222222",
        "name": "Pause response",
        "isEnabled": True,
        "method": "GET",
        "urlPattern": "/pause-response",
        "breakOnRequest": False,
        "breakOnResponse": True,
    },
    {
        "id": "33333333-3333-3333-3333-333333333333",
        "name": "Drop request",
        "isEnabled": True,
        "method": "GET",
        "urlPattern": "/drop-request",
        "breakOnRequest": True,
        "breakOnResponse": False,
    },
    {
        "id": "44444444-4444-4444-4444-444444444444",
        "name": "Disabled breakpoint",
        "isEnabled": False,
        "method": "GET",
        "urlPattern": "/ignored",
        "breakOnRequest": True,
        "breakOnResponse": True,
    },
]
json.dump(rules, open(f"{work}/breakpoints.json", "w"), indent=2)

actions = [
    {"action": "resume", "body": "modified-by-breakpoint"},
    {"action": "resume", "body": '{"code": 1, "from": "editor"}'},
    {"action": "drop"},
]
json.dump(actions, open(f"{work}/actions.json", "w"), indent=2)
print("wrote breakpoint rules and decisions")
PY
pass "breakpoint fixtures written"

echo "== Starting ProxyDog with breakpoints =="
"$BIN" --headless --port "$PORT" \
  --breakpoints-file "$WORK/breakpoints.json" \
  --breakpoint-actions "$WORK/actions.json" \
  --print-bodies --out "$WORK/captures.jsonl" >"$WORK/proxy.log" 2>&1 &
PROXY_PID=$!
if wait_for_pattern "$WORK/proxy.log" '"type":"ready"' 20; then
  pass "ProxyDog reported ready"
else
  fail "ProxyDog did not become ready"; cat "$WORK/proxy.log"; exit 1
fi

PROXY="http://127.0.0.1:$PORT"
UPSTREAM="http://127.0.0.1:$UPSTREAM_PORT"

echo "== Case: request breakpoint resumes with an edited body =="
REQ_RESP=$(curl -s --max-time 20 -x "$PROXY" -X POST --data "original-body" "$UPSTREAM/pause-request")
echo "  echoed: $REQ_RESP"
if [ "$REQ_RESP" = "modified-by-breakpoint" ]; then
  pass "request body was edited at the breakpoint"
else
  fail "request breakpoint edit failed: $REQ_RESP"
fi

echo "== Case: response breakpoint resumes with an edited body =="
RESP_BODY=$(curl -s --max-time 20 -x "$PROXY" "$UPSTREAM/pause-response")
echo "  body: $RESP_BODY"
if echo "$RESP_BODY" | grep -q '"from": "editor"'; then
  pass "response body was edited at the breakpoint"
else
  fail "response breakpoint edit failed: $RESP_BODY"
fi

echo "== Case: drop decision =="
DROP_OUT=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -x "$PROXY" "$UPSTREAM/drop-request" 2>&1)
DROP_EXIT=$?
echo "  http=$DROP_OUT curl_exit=$DROP_EXIT"
if [ "$DROP_EXIT" -ne 0 ] || [ "$DROP_OUT" = "000" ] || [ "$DROP_OUT" -ge 400 ] 2>/dev/null; then
  pass "dropped request did not complete normally"
else
  fail "dropped request unexpectedly succeeded: $DROP_OUT"
fi

echo "== Case: disabled breakpoint is ignored =="
IGNORED=$(curl -s --max-time 20 -x "$PROXY" "$UPSTREAM/ignored")
echo "  body: $IGNORED"
if [ "$IGNORED" = "ignored-upstream" ]; then
  pass "disabled breakpoint was ignored"
else
  fail "disabled breakpoint fired: $IGNORED"
fi

echo "== Case: captures record the breakpoint phase =="
sleep 0.8
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
request_hits = [c for c in captures.values() if c.get("breakpoint_phase") == "request"]
response_hits = [c for c in captures.values() if c.get("breakpoint_phase") == "response"]
if not any(c.get("breakpoint_rule") == "Pause request" for c in request_hits):
    problems.append("request breakpoint capture is missing its rule/phase")
if not any(c.get("breakpoint_rule") == "Pause response" for c in response_hits):
    problems.append("response breakpoint capture is missing its rule/phase")
if not any("/pause-request" in c.get("url", "") for c in captures.values()):
    problems.append("paused request was not captured at all")

if problems:
    print("  FAIL  breakpoint capture assertions")
    for problem in problems:
        print("        -", problem)
    for c in captures.values():
        print("        ", c.get("status"), c.get("url"), c.get("breakpoint_rule"), c.get("breakpoint_phase"))
    sys.exit(1)
print(f"  PASS  breakpoint capture assertions ({len(request_hits)} request, {len(response_hits)} response pauses)")
PY
if [ $? -eq 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

echo
echo "== Summary: $PASS passed, $FAIL failed =="
if [ "$FAIL" -gt 0 ]; then
  echo "Proxy log:"; tail -30 "$WORK/proxy.log"
  echo "Upstream requests:"; cat "$WORK/requests.log" 2>/dev/null
  exit 1
fi
exit 0
