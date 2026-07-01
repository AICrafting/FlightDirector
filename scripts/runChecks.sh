#!/usr/bin/env bash
# Runs all check scripts in scripts/checks/ and exits non-zero if any fail.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/checks" && pwd)"
fail=0

for script in "$SCRIPT_DIR"/*.sh; do
	[ -x "$script" ] || continue
	printf '\033[1m━━━ %s ━━━\033[0m\n' "$(basename "$script")"
	if "$script"; then
		:
	else
		fail=$((fail + 1))
	fi
done

if [ "$fail" -gt 0 ]; then
	printf '\n\033[0;31m%d check script(s) failed.\033[0m\n' "$fail"
	exit 1
fi

printf '\n\033[0;32mAll checks passed.\033[0m\n'
