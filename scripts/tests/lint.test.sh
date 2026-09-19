#!/usr/bin/env bash
# Unit tests for scripts/checks/lint.sh — the skip accounting and the exit
# code when no linter is installed (#135), plus the #123 summary contract.
#
# A missing linter is simulated the way the issue's reproduction does: the
# script runs under a restricted PATH built from scratch, holding only the
# handful of tools lint.sh itself needs, plus whichever linter stubs the case
# under test wants to be "installed".
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LINT_SRC="$REPO_ROOT/scripts/checks/lint.sh"
ESC=$'\033'

pass=0; fail=0
# A failed check prints the run it judged (exit code + output): the restricted
# PATH below behaves differently per platform, and a bare ✗ from a CI leg
# nobody can reproduce locally says nothing about why.
check() { if [ "$2" = 1 ]; then printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass+1));
			else printf '\033[0;31m  ✗ %s\033[0m\n' "$1"; fail=$((fail+1));
				printf '      rc=%s\n' "${rc:-unset}"; sed 's/^/      | /' <<<"${out:-}"; fi; }

SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT

# lint.sh cd's to "$(dirname "$0")/../..", so stage it at the same depth and
# give that tree one clean YAML file and one clean shell script to look at.
mkdir -p "$SANDBOX/repo/scripts/checks"
cp "$LINT_SRC" "$SANDBOX/repo/scripts/checks/lint.sh"
chmod +x "$SANDBOX/repo/scripts/checks/lint.sh"
LINT="$SANDBOX/repo/scripts/checks/lint.sh"
printf 'key: value\n' >"$SANDBOX/repo/sample.yml"
printf '#!/usr/bin/env bash\ntrue\n' >"$SANDBOX/repo/sample.sh"

# --- a PATH with no linters on it at all ---
BASEBIN="$SANDBOX/basebin"; mkdir -p "$BASEBIN"
# Each tool is a wrapper that execs the real one by absolute path, not a symlink:
# on Windows (MSYS) `ln -s` copies the file, and a copied bash.exe outside
# /usr/bin cannot find msys-2.0.dll, so nothing under this PATH would start.
for tool in bash dirname find xargs; do
	src="$(command -v "$tool")"
	printf '#!/bin/sh\nexec "%s" "$@"\n' "$src" >"$BASEBIN/$tool"
	chmod +x "$BASEBIN/$tool"
done

stub() {  # stub <bin dir> <name> <exit code>
	printf '#!/usr/bin/env bash\nexit %s\n' "$3" >"$1/$2"
	chmod +x "$1/$2"
}

BOTH="$SANDBOX/both"; mkdir -p "$BOTH"
stub "$BOTH" yamllint 0
stub "$BOTH" shellcheck 0

ONE="$SANDBOX/one"; mkdir -p "$ONE"
stub "$ONE" shellcheck 0

FAILING="$SANDBOX/failing"; mkdir -p "$FAILING"
stub "$FAILING" yamllint 1

run_lint() {  # run_lint <extra bin dir or ""> ; sets $out and $rc
	local extra="$1"; shift
	local path="$BASEBIN"
	if [ -n "$extra" ]; then path="$extra:$BASEBIN"; fi
	out="$(env -i PATH="$path" HOME="$SANDBOX" "$LINT" "$@" 2>&1)" && rc=0 || rc=$?
	# shellcheck disable=SC2001  # an SGR sequence needs a regex, not ${var//…}
	out="$(sed "s/${ESC}\[[0-9;]*m//g" <<<"$out")"
}

# --- both linters present: nothing skipped, green ---
run_lint "$BOTH"
check "both linters present exits 0" "$([ "$rc" = 0 ] && echo 1 || echo 0)"
check "both linters present reports two passes" \
	"$(grep -q '^Passed: 2  Failed: 0$' <<<"$out" && echo 1 || echo 0)"
check "both linters present prints no skip count" \
	"$(grep -q 'Skipped:' <<<"$out" && echo 0 || echo 1)"

# --- one linter missing: still a pass, but the line says one was skipped ---
run_lint "$ONE"
check "one linter missing still exits 0" "$([ "$rc" = 0 ] && echo 1 || echo 0)"
check "one linter missing counts the skip on the summary line" \
	"$(grep -q '^Passed: 1  Failed: 0  Skipped: 1$' <<<"$out" && echo 1 || echo 0)"
check "one linter missing names the skipped linter" \
	"$(grep -q 'yamllint not installed — skipping' <<<"$out" && echo 1 || echo 0)"

# --- both linters missing: nothing ran, so it must not come back green ---
run_lint ""
check "no linter installed exits non-zero" "$([ "$rc" = 1 ] && echo 1 || echo 0)"
check "no linter installed reports both skips" \
	"$(grep -q '^Passed: 0  Failed: 0  Skipped: 2$' <<<"$out" && echo 1 || echo 0)"
check "no linter installed explains why it is red" \
	"$(grep -q 'No checks ran' <<<"$out" && echo 1 || echo 0)"
check "no linter installed names what to install" \
	"$(grep -q 'Install yamllint shellcheck' <<<"$out" && echo 1 || echo 0)"

# --- a filter that skips its only linter also counts as nothing having run ---
run_lint "" yaml
check "filtered run with its linter missing exits non-zero" \
	"$([ "$rc" = 1 ] && echo 1 || echo 0)"
check "filtered run with its linter missing reports one skip" \
	"$(grep -q '^Passed: 0  Failed: 0  Skipped: 1$' <<<"$out" && echo 1 || echo 0)"

# --- a real failure still wins over the skip accounting (#123) ---
run_lint "$FAILING"
check "a failing linter exits 1" "$([ "$rc" = 1 ] && echo 1 || echo 0)"
check "a failing linter is counted as failed, not skipped" \
	"$(grep -q '^Passed: 0  Failed: 1  Skipped: 1$' <<<"$out" && echo 1 || echo 0)"
check "a failing linter does not print the nothing-ran message" \
	"$(grep -q 'No checks ran' <<<"$out" && echo 0 || echo 1)"

# Summary: plain when nothing failed, red when something did (#123).
[ "$fail" -gt 0 ] && summary_colour=$'\033[0;31m' || summary_colour=''
printf '\n%sPassed: %d  Failed: %d\033[0m\n' "$summary_colour" "$pass" "$fail"
[ "$fail" -eq 0 ]
