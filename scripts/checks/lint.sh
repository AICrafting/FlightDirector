#!/usr/bin/env bash
# Local pre-push lint check — mirrors the CI lint workflow.
# Can be run from anywhere:
#   lint.sh             — run all checks
#   lint.sh yaml        — yamllint only
#   lint.sh shell       — shellcheck only
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

pass=0
fail=0
filter="${1:-all}"

run_check() {
	local name="$1"
	shift
	printf '\033[1m▶ %s\033[0m\n' "$name"
	if "$@"; then
		printf '\033[0;32m  ✓ %s passed\033[0m\n\n' "$name"
		pass=$((pass + 1))
	else
		printf '\033[0;31m  ✗ %s failed\033[0m\n\n' "$name"
		fail=$((fail + 1))
	fi
}

should_run() {
	[ "$filter" = "all" ] || [ "$filter" = "$1" ]
}

# yamllint (exclude node_modules)
if should_run yaml; then
	if command -v yamllint &>/dev/null; then
		run_check "yamllint" bash -c \
			'find . \( -name "*.yml" -o -name "*.yaml" \) -not -path "*/node_modules/*" -not -path "./external/*" | xargs yamllint'
	else
		printf '\033[0;31m  ⚠ yamllint not installed — skipping\033[0m\n\n'
	fi
fi

# ShellCheck
if should_run shell; then
	if command -v shellcheck &>/dev/null; then
		run_check "shellcheck" bash -c \
			'find . -type f -name "*.sh" -not -path "./node_modules/*" -not -path "./external/*" -print0 | xargs -0 -r shellcheck'
	else
		printf '\033[0;31m  ⚠ shellcheck not installed — skipping\033[0m\n\n'
	fi
fi

printf '\033[1m────────────────────────────\033[0m\n'
printf '\033[0;32mPassed: %d\033[0m  \033[0;31mFailed: %d\033[0m\n' "$pass" "$fail"

if [ "$fail" -gt 0 ]; then
	exit 1
fi
