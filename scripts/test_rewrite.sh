#!/usr/bin/env bash
# Tests static rewrite rules: redirect, replace request, modify request, replace response,
# modify response, and that disabled rules are ignored.
#
#   ./scripts/test_rewrite.sh
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/env.sh"

PORT="${PORT:-19020}"
UPSTREAM_PORT="${UPSTREAM_PORT:-19021}"
WORK="$ROOT/.build-cache/test-rewrite"
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

echo "== Starting upstream echo server on 127.0.0.1:$UPSTREAM_PORT =="
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
        if self.path.startswith("/api"):
            self._respond(200, json.dumps({"code": 0, "message": "ok"}), "application/json")
        elif self.path.startswith("/old"):
            self._respond(200, "old")
        elif self.path.startswith("/new"):
            self._respond(200, "new")
        elif self.path.startswith("/replace"):
            self._respond(200, "upstream-replace-target")
        elif self.path.startswith("/ignored"):
            self._respond(200, "upstream-ignored")
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
  pass "echo server is listening"
else
  fail "could not start the echo server"; cat "$WORK/upstream.log"; exit 1
fi

echo "== Writing rewrite rules =="
python3 - "$UPSTREAM_PORT" "$WORK/rules.json" <<'PY'
import json
import sys

port = int(sys.argv[1])
rules = [
    {
        "id": "11111111-1111-1111-1111-111111111111",
        "name": "Fix api code",
        "isEnabled": True,
        "urlPattern": "/api",
        "action": "modifyResponse",
        "findText": '"code": 0',
        "replaceText": '"code": -1',
        "responseStatus": 200,
        "responseContentType": "application/json",
        "redirectURL": "",
        "replacementBody": "",
        "method": "GET",
    },
    {
        "id": "22222222-2222-2222-2222-222222222222",
        "name": "Local replace",
        "isEnabled": True,
        "urlPattern": "/replace",
        "action": "replaceResponse",
        "redirectURL": "",
        "replacementBody": '{"from":"proxy"}',
        "findText": "",
        "replaceText": "",
        "responseStatus": 200,
        "responseContentType": "application/json",
        "method": None,
    },
    {
        "id": "33333333-3333-3333-3333-333333333333",
        "name": "Move old to new",
        "isEnabled": True,
        "urlPattern": "/old",
        "action": "redirect",
        "redirectURL": f"http://127.0.0.1:{port}/new",
        "replacementBody": "",
        "findText": "",
        "replaceText": "",
        "responseStatus": 200,
        "responseContentType": "application/json",
        "method": "GET",
    },
    {
        "id": "44444444-4444-4444-4444-444444444444",
        "name": "Replace echo body",
        "isEnabled": True,
        "urlPattern": "/echo-replace",
        "action": "replaceRequest",
        "redirectURL": "",
        "replacementBody": "replaced-body",
        "findText": "",
        "replaceText": "",
        "responseStatus": 200,
        "responseContentType": "text/plain",
        "method": "POST",
    },
    {
        "id": "55555555-5555-5555-5555-555555555555",
        "name": "Patch echo body",
        "isEnabled": True,
        "urlPattern": "/echo-mod",
        "action": "modifyRequest",
        "redirectURL": "",
        "replacementBody": "",
        "findText": "code:0",
        "replaceText": "code:-1",
        "responseStatus": 200,
        "responseContentType": "text/plain",
        "method": "POST",
    },
    {
        "id": "66666666-6666-6666-6666-666666666666",
        "name": "Disabled rule",
        "isEnabled": False,
        "urlPattern": "/ignored",
        "action": "replaceResponse",
        "redirectURL": "",
        "replacementBody": "should-not-apply",
        "findText": "",
        "replaceText": "",
        "responseStatus": 200,
        "responseContentType": "text/plain",
        "method": None,
    },
]
json.dump(rules, open(sys.argv[2], "w"), indent=2)
print(f"wrote {len(rules)} rules")
PY
pass "rules file written"

echo "== Starting ProxyDog with the rules =="
"$BIN" --headless --port "$PORT" --rules-file "$WORK/rules.json" --print-bodies --out "$WORK/captures.jsonl" >"$WORK/proxy.log" 2>&1 &
PROXY_PID=$!
if wait_for_pattern "$WORK/proxy.log" '"type":"ready"' 20; then
  pass "ProxyDog reported ready"
else
  fail "ProxyDog did not become ready"; cat "$WORK/proxy.log"; exit 1
fi

PROXY="http://127.0.0.1:$PORT"
UPSTREAM="http://127.0.0.1:$UPSTREAM_PORT"

echo "== Case: modify response =="
API_BODY=$(curl -s --max-time 15 -x "$PROXY" "$UPSTREAM/api")
echo "  body: $API_BODY"
if echo "$API_BODY" | grep -q '"code": -1'; then
  pass "response body was modified (code -> -1)"
else
  fail "response body was not modified: $API_BODY"
fi

echo "== Case: replace response (upstream must be skipped) =="
REPLACE_BODY=$(curl -s --max-time 15 -x "$PROXY" "$UPSTREAM/replace")
echo "  body: $REPLACE_BODY"
if [ "$REPLACE_BODY" = '{"from":"proxy"}' ]; then pass "response was replaced"; else fail "response was not replaced: $REPLACE_BODY"; fi
if grep -q "GET /replace" "$WORK/requests.log" 2>/dev/null; then
  fail "the replaced request still reached the upstream"
else
  pass "replaced request never reached the upstream"
fi

echo "== Case: redirect =="
REDIRECT_BODY=$(curl -s --max-time 15 -x "$PROXY" "$UPSTREAM/old")
echo "  body: $REDIRECT_BODY"
if [ "$REDIRECT_BODY" = "new" ]; then pass "request was redirected to /new"; else fail "redirect failed: $REDIRECT_BODY"; fi
if grep -q "GET /new" "$WORK/requests.log" 2>/dev/null; then pass "upstream saw the redirected path"; else fail "upstream did not see /new"; fi
if grep -q "GET /old" "$WORK/requests.log" 2>/dev/null; then fail "upstream still saw the original /old path"; else pass "upstream never saw /old"; fi

echo "== Case: replace request body =="
REQ_RESP=$(curl -s --max-time 15 -x "$PROXY" -X POST --data "original-body" "$UPSTREAM/echo-replace")
echo "  echoed: $REQ_RESP"
if [ "$REQ_RESP" = "replaced-body" ]; then pass "request body was replaced"; else fail "request body replacement failed: $REQ_RESP"; fi

echo "== Case: modify request body =="
MOD_RESP=$(curl -s --max-time 15 -x "$PROXY" -X POST --data "code:0&x=1" "$UPSTREAM/echo-mod")
echo "  echoed: $MOD_RESP"
if [ "$MOD_RESP" = "code:-1&x=1" ]; then pass "request body was patched"; else fail "request body patch failed: $MOD_RESP"; fi

echo "== Case: disabled rule is ignored =="
IGNORED=$(curl -s --max-time 15 -x "$PROXY" "$UPSTREAM/ignored")
echo "  body: $IGNORED"
if [ "$IGNORED" = "upstream-ignored" ]; then pass "disabled rule was ignored"; else fail "disabled rule was applied: $IGNORED"; fi

echo "== Case: captures record which rule was applied =="
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

with_rule = [c for c in captures.values() if c.get("rewrite_rule")]
missing = []
if not any(c.get("rewrite_rule") == "Fix api code" for c in captures.values()):
    missing.append("modify-response capture has no rewrite_rule")
if not any(c.get("rewrite_rule") == "Local replace" for c in captures.values()):
    missing.append("replace-response capture has no rewrite_rule")
if not any(c.get("url", "").startswith("http") and "/ignored" in c.get("url", "") for c in captures.values()):
    missing.append("disabled-rule request was not captured at all")
if missing:
    print("  FAIL  capture assertions")
    for item in missing:
        print("        -", item)
    for c in captures.values():
        print("        ", c.get("status"), c.get("url"), c.get("rewrite_rule"))
    sys.exit(1)
print(f"  PASS  capture assertions ({len(with_rule)} rewritten exchanges)")
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
