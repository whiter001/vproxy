#!/bin/bash

# SOCKS5 Proxy Full Test Script
# Tests both no-auth and auth modes

set -e

PROXY_HOST="${SOCKS5_PROXY_HOST:-127.0.0.1}"
PROXY_PORT="${SOCKS5_PROXY_PORT:-5778}"
PROXY_ADDR="${PROXY_HOST}:${PROXY_PORT}"
PROXY_USER="${SOCKS5_AUTH_USERNAME:-user}"
PROXY_PASS="${SOCKS5_AUTH_PASSWORD:-pwd}"

echo "========================================="
echo "SOCKS5 Proxy Full Test Suite"
echo "========================================="
echo "Proxy: ${PROXY_ADDR}"
echo "Auth: ${PROXY_USER}:${PROXY_PASS}"
echo

FAILED=0

test_case() {
  local name="$1"
  local cmd="$2"
  echo -n "[TEST] ${name}... "
  if eval "${cmd}" > /dev/null 2>&1; then
    echo "PASS"
  else
    echo "FAIL"
    FAILED=$((FAILED + 1))
  fi
}

echo "--- No Auth Mode ---"
test_case "HTTPS GET (no auth)" \
  "curl --fail --silent --show-error --socks5 '${PROXY_ADDR}' https://httpbin.org/get"
test_case "HTTP GET (no auth)" \
  "curl --fail --silent --show-error --socks5 '${PROXY_ADDR}' http://httpbin.org/ip"

echo
echo "--- Auth Mode ---"
test_case "HTTPS GET (auth)" \
  "curl --fail --silent --show-error --socks5-user '${PROXY_USER}:${PROXY_PASS}' --socks5 '${PROXY_ADDR}' https://httpbin.org/get"
test_case "HTTP GET (auth)" \
  "curl --fail --silent --show-error --socks5-user '${PROXY_USER}:${PROXY_PASS}' --socks5 '${PROXY_ADDR}' http://httpbin.org/ip"

echo
echo "========================================="
if [ $FAILED -eq 0 ]; then
  echo "All tests passed! ✓"
else
  echo "$FAILED test(s) failed! ✗"
  exit 1
fi
