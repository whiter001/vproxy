#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
found=0

while IFS= read -r -d '' file; do
	found=1
	v fmt -w "$file"
done < <(find "$repo_root" -type f -name '*.v' -not -path '*/.git/*' -print0)

if [[ "$found" -eq 0 ]]; then
	echo "No V files found."
fi