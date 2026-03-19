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

PROXY_LISTEN_ADDR="$listen_addr" v run "$repo_root/proxy/http/1/proxy.1.v" >"$log_file" 2>&1 &
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

curl --fail --silent --show-error \
	-x "http://user:pwd@${listen_addr}" \
	https://httpbin.org/get | grep -q '"url": "https://httpbin.org/get"'

curl --fail --silent --show-error \
	-x "http://user:pwd@${listen_addr}" \
	http://httpbin.org/get | grep -q '"url": "http://httpbin.org/get"'

echo "proxy curl smoke tests passed"
