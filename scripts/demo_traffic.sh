#!/usr/bin/env bash
# Pushes a handful of varied requests through a running ProxyDog instance so the UI
# has realistic traffic (used for README screenshots and manual QA).
# Usage: ./scripts/demo_traffic.sh [port]
set -uo pipefail
PORT="${1:-8888}"
PROXY="http://127.0.0.1:$PORT"
BASE_ARGS=(-s -o /dev/null --max-time 20 -x "$PROXY" -k)

echo "Generating demo traffic through $PROXY"

curl "${BASE_ARGS[@]}" -A "ProxyDog-Demo/1.0" http://example.com/ || true
curl "${BASE_ARGS[@]}" -A "ProxyDog-Demo/1.0" https://example.com/ || true
curl "${BASE_ARGS[@]}" -A "Safari/605.1.15" https://httpbin.org/json || true
curl "${BASE_ARGS[@]}" -A "Safari/605.1.15" -X POST \
  -H 'Content-Type: application/json' \
  -d '{"name":"ProxyDog","version":"1.0.0","features":["capture","inspect","export"]}' \
  https://httpbin.org/post || true
curl "${BASE_ARGS[@]}" -A "RxSwift/6.0" https://jsonplaceholder.typicode.com/posts/1 || true
curl "${BASE_ARGS[@]}" -A "Safari/605.1.15" https://jsonplaceholder.typicode.com/users || true
curl "${BASE_ARGS[@]}" -A "Safari/605.1.15" -o /dev/null https://httpbin.org/image/png || true
curl "${BASE_ARGS[@]}" -A "Safari/605.1.15" https://httpbin.org/status/404 || true
curl "${BASE_ARGS[@]}" -A "Safari/605.1.15" https://httpbin.org/redirect/2 || true
curl "${BASE_ARGS[@]}" -A "ProxyDog-Demo/1.0" http://httpbin.org/delay/1 || true
curl "${BASE_ARGS[@]}" -A "Safari/605.1.15" https://httpbin.org/headers || true
curl -s -o /dev/null --max-time 4 -x "$PROXY" -k https://proxy-dog-unreachable.invalid/ || true

sleep 1
echo "Done"
