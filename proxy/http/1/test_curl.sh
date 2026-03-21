#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../../../" && pwd)"
listen_addr="127.0.0.1:5777"
log_file="${script_dir}/proxy.1.log"

cleanup() {
	if [[ -n "${proxy_pid:-}" ]]; then
		kill "${proxy_pid}" >/dev/null 2>&1 || true
		wait "${proxy_pid}" >/dev/null 2>&1 || true
	fi
}

trap cleanup EXIT

# Build first
v -o "${script_dir}/proxy_test_bin" "$repo_root/proxy/http/1/proxy.1.v" >/dev/null 2>&1

# Start proxy
PROXY_LISTEN_ADDR="$listen_addr" "${script_dir}/proxy_test_bin" >"$log_file" 2>&1 &
proxy_pid=$!

for _ in {1..50}; do
	if nc -z 127.0.0.1 5777 >/dev/null 2>&1; then
		break
	fi
	sleep 0.2
done

if ! nc -z 127.0.0.1 5777 >/dev/null 2>&1; then
	echo "proxy did not start"
	cat "$log_file"
	exit 1
fi

auth="http://user:pwd@${listen_addr}"
failed=0

echo "=== Test: HTTP GET (via proxy) ==="
if curl --fail --silent --show-error \
	-x "$auth" \
	http://httpbin.org/get | grep -q '"url": "http://httpbin.org/get"'; then
	echo "PASS"
else
	echo "FAIL"
	((failed++))
fi

echo "=== Test: HTTP POST (via proxy) ==="
if curl --fail --silent --show-error \
	-x "$auth" \
	-X POST \
	-d "hello=world" \
	httpbin.org/post | grep -q '"hello": "world"'; then
	echo "PASS"
else
	echo "FAIL"
	((failed++))
fi

echo "=== Test: HTTP HEAD (via proxy) ==="
if curl --fail --silent --show-error -I \
	-x "$auth" \
	httpbin.org/get >/dev/null 2>&1; then
	echo "PASS"
else
	echo "FAIL"
	((failed++))
fi

echo "=== Test: No auth (should get 407) ==="
if ! curl --fail --silent --show-error \
	-x "$listen_addr" \
	httpbin.org/get >/dev/null 2>&1; then
	echo "PASS (correctly rejected)"
else
	echo "FAIL (should have been rejected)"
	((failed++))
fi

echo "=== Test: Wrong auth (should get 407) ==="
if ! curl --fail --silent --show-error \
	-x "http://wrong:auth@$listen_addr" \
	httpbin.org/get >/dev/null 2>&1; then
	echo "PASS (correctly rejected)"
else
	echo "FAIL (should have been rejected)"
	((failed++))
fi

echo "=== Test: CONNECT tunnel (HTTPS via proxy) ==="
if curl --fail --silent --show-error \
	-x "$auth" \
	https://httpbin.org/get | grep -q '"url"'; then
	echo "PASS"
else
	echo "FAIL"
	((failed++))
fi

echo "=== Test: Invalid method (should get 405) ==="
if ! curl --fail --silent --show-error \
	-x "$auth" \
	-X INVALID_METHOD \
	httpbin.org/get >/dev/null 2>&1; then
	echo "PASS (correctly rejected)"
else
	echo "FAIL (should have been rejected)"
	((failed++))
fi

echo "=== Test: Missing Host with auth (should get 400) ==="
# Send request with auth but no Host header
if printf 'GET / HTTP/1.1\r\nProxy-Authorization: Basic dXNlcjpwd2Q=\r\n\r\n' | nc 127.0.0.1 5777 2>/dev/null | grep -q "400"; then
	echo "PASS"
else
	echo "FAIL"
	((failed++))
fi

echo ""
echo "=== Results: $((9-failed))/9 passed ==="

if [[ $failed -gt 0 ]]; then
	echo "Some tests FAILED"
	cat "$log_file"
	exit 1
else
	echo "All tests PASSED"
fi
