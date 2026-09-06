#!/usr/bin/env bash
# Runs all script unit tests in scripts/tests/ (*.test.sh) and exits non-zero
# if any fail. These are unit tests for the repo's own scripts — distinct from
# scripts/checks/ (pre-push working-tree cleanliness) and test-rig/ (per-backend
# integration smoke). Run on demand, and in CI via .forgejo/workflows/tests.yml.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)/tests"
fail=0
ran=0

for test in "$TEST_DIR"/*.test.sh; do
	[ -e "$test" ] || continue
	ran=$((ran + 1))
	printf '\033[1m━━━ %s ━━━\033[0m\n' "$(basename "$test")"
	if bash "$test"; then
		:
	else
		fail=$((fail + 1))
	fi
done

if [ "$ran" -eq 0 ]; then
	printf '\033[0;33mNo tests found in %s\033[0m\n' "$TEST_DIR"
fi

if [ "$fail" -gt 0 ]; then
	printf '\n\033[0;31m%d test file(s) failed.\033[0m\n' "$fail"
	exit 1
fi

printf '\n\033[0;32mAll tests passed.\033[0m\n'
