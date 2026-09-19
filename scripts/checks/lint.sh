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
skipped=0
missing=""
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

# A linter that isn't installed is skipped, not failed — the pre-push hook has
# to keep working on a machine without the tools. Count the skip so the summary
# can say so, and remember the name so we can tell the user what to install.
skip_check() {
	local name="$1"
	printf '\033[2m  ⚠ %s not installed — skipping\033[0m\n\n' "$name"
	skipped=$((skipped + 1))
	missing="${missing:+$missing }$name"
}

# yamllint (exclude node_modules)
if should_run yaml; then
	if command -v yamllint &>/dev/null; then
		run_check "yamllint" bash -c \
			'find . \( -name "*.yml" -o -name "*.yaml" \) -not -path "*/node_modules/*" -not -path "./external/*" | xargs yamllint'
	else
		skip_check yamllint
	fi
fi

# ShellCheck
if should_run shell; then
	if command -v shellcheck &>/dev/null; then
		run_check "shellcheck" bash -c \
			'find . -type f -name "*.sh" -not -path "./node_modules/*" -not -path "./external/*" -print0 | xargs -0 -r shellcheck'
	else
		skip_check shellcheck
	fi
fi

# Summary: plain when nothing failed, red when something did (#123).
# The skip count is appended dim, in the style run-checks.sh uses for a
# skipped script, so a partial run can't be mistaken for a full one (#135).
[ "$fail" -gt 0 ] && summary_colour=$'\033[0;31m' || summary_colour=''
printf '%sPassed: %d  Failed: %d\033[0m' "$summary_colour" "$pass" "$fail"
if [ "$skipped" -gt 0 ]; then
	printf '\033[2m  Skipped: %d\033[0m' "$skipped"
fi
printf '\n'

if [ "$fail" -gt 0 ]; then
	exit 1
fi

# Nothing actually ran: every check was skipped for want of a linter, so a
# green result here would mean "linted nothing" (#135). The summary line alone
# wouldn't explain the red, so name what to install.
if [ "$((pass + fail))" -eq 0 ] && [ "$skipped" -gt 0 ]; then
	printf '\n\033[0;31mNo checks ran — every linter is missing, so nothing was linted.\033[0m\n'
	printf '\033[0;31mInstall %s to lint locally.\033[0m\n' "$missing"
	exit 1
fi
