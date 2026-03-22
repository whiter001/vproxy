#!/bin/bash

# SOCKS5 Proxy Test Script (curl only)

set -e

PROXY_ADDR="${SOCKS5_PROXY_ADDR:-127.0.0.1:5778}"
PROXY_USER="${SOCKS5_AUTH_USERNAME:-user}"
PROXY_PASS="${SOCKS5_AUTH_PASSWORD:-pwd}"

echo "=== SOCKS5 Proxy Tests ==="
echo "Proxy: ${PROXY_ADDR}"
echo

# Test 1: No auth - HTTP over HTTPS
echo "[1/4] Test HTTPS (no auth)..."
curl --fail --silent --show-error \
  --socks5 "${PROXY_ADDR}" \
  https://httpbin.org/get
echo " PASS"

# Test 2: No auth - HTTP
echo "[2/4] Test HTTP (no auth)..."
curl --fail --silent --show-error \
  --socks5 "${PROXY_ADDR}" \
  http://httpbin.org/ip
echo " PASS"

# Test 3: With auth - HTTPS
echo "[3/4] Test HTTPS (with auth)..."
curl --fail --silent --show-error \
  --proxy-user "${PROXY_USER}:${PROXY_PASS}" \
  --socks5 "${PROXY_ADDR}" \
  https://httpbin.org/get
echo " PASS"

# Test 4: With auth - HTTP
echo "[4/4] Test HTTP (with auth)..."
curl --fail --silent --show-error \
  --proxy-user "${PROXY_USER}:${PROXY_PASS}" \
  --socks5 "${PROXY_ADDR}" \
  http://httpbin.org/ip
echo " PASS"

echo
echo "=== All tests passed! ==="
