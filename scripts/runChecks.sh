#!/usr/bin/env bash
# Runs all check scripts in scripts/checks/ and exits non-zero if any fail.
# Set RUNCHECKS_SKIP to a space-separated list of script basenames to skip
# (used by the pre-push hook, which runs the signature check itself on the
# exact push range).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/checks" && pwd)"
fail=0
skip=" ${RUNCHECKS_SKIP:-} "

for script in "$SCRIPT_DIR"/*.sh; do
	[ -x "$script" ] || continue
	name="$(basename "$script")"
	if [[ "$skip" == *" $name "* ]]; then
		printf '\033[2m━━━ %s (skipped) ━━━\033[0m\n' "$name"
		continue
	fi
	printf '\033[1m━━━ %s ━━━\033[0m\n' "$name"
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
