#!/usr/bin/env bash
# docs-only.sh — decide whether a pull request may take CI's cheap path (FJ-235).
#
# The cheap path skips the expensive STEPS of a test leg (installing tools, running
# scripts/run-tests.sh) when every path a PR changes is on an allowlist of files that no
# test reads. It never skips the JOB: a skipped job makes `flight ci watch` report
# `status=skipped` ("CI ran nothing"), and Forgejo posts a `success` commit status for a
# skipped job, so anything reading statuses would see green for work that never ran. A
# job that runs, decides, and reports `success` is the honest form.
#
# Usage:
#   docs-only.sh --pr <number> --base <branch>     classify HEAD against origin/<branch>
#   docs-only.sh --pr <number> --paths-from <file> classify a newline-separated path list
#                                                  ('-' = stdin; for tests)
#   docs-only.sh --print-allowlist                 print the allowlist, one pattern a line
#
# Output: a one-line verdict on stdout (the path taken and, on a full run, the reason
# and the first path that forced it); `cheap=true|false` appended to $GITHUB_OUTPUT and a
# summary line appended to $GITHUB_STEP_SUMMARY when those are set.
#
# It fails OPEN: anything unexpected — no PR number, a missing or unfetchable base ref, a
# git error, an empty diff, an unrecognised path — is `cheap=false`, i.e. the full suite.
# It never exits non-zero for a decision; the workflow step also carries
# `continue-on-error`, so even a crash leaves the output unset, which the gated steps read
# as "not cheap".
#
# "Is this a PR" comes from the PR number the workflow passes in, not from the event name
# (inside a reusable workflow that is `workflow_call`). A push has no PR number, so a push
# to develop — the post-merge record — always runs in full.
#
# The diff is origin/<base>...HEAD — what the PR changes since it forked. Sound because the
# fork point was itself a tip of the base, which a push ran in full; and the merge is run in
# full again by the push that lands it. A CI checkout is usually shallow (depth 1), so when
# there is no merge base the classifier unshallows; when it still cannot find one (no
# credentials to fetch, say) it falls back to the two-dot tree diff origin/<base> HEAD.
# That form needs only the base tip and can only ADD paths when the base has moved on, so
# the fallback errs to a full run, never to a cheap one.
#
# Bash 3.2, BSD and MSYS safe, like everything else under scripts/.

# ── the allowlist ──────────────────────────────────────────────────────────────────────
# Paths NO test reads, as bash `case` patterns (`*` crosses `/`). Much of this product is
# markdown and the suite reads it — skills, references, the plugin's CHANGELOG and GUIDE,
# the root README — so this is a list of files, not an extension match. Before adding a
# path, confirm nothing under scripts/tests/ reads it (or runs a script that does);
# scripts/tests/docs-only.test.sh fails if a test file names an allowlisted path.
ALLOWLIST='docs/*
CONTRIBUTING.md
CODE_OF_CONDUCT.md
SECURITY.md'

PR=''; BASE=''; PATHS_FROM=''; BAD_ARG=''
while [ $# -gt 0 ]; do
	case "$1" in
		--pr)              PR="${2:-}"; shift 2 2>/dev/null || shift ;;
		--base)            BASE="${2:-}"; shift 2 2>/dev/null || shift ;;
		--paths-from)      PATHS_FROM="${2:-}"; shift 2 2>/dev/null || shift ;;
		--print-allowlist) printf '%s\n' "$ALLOWLIST"; exit 0 ;;
		*)                 BAD_ARG="$1"; shift ;;
	esac
done

# verdict <true|false> <message> — print, record, and stop. Always exit 0.
verdict() {
	if [ "$1" = true ]; then
		line="docs-only: CHEAP path — $2; install and test steps are skipped"
	else
		line="docs-only: FULL run — $2"
	fi
	printf '%s\n' "$line"
	if [ -n "${GITHUB_OUTPUT:-}" ]; then
		printf 'cheap=%s\n' "$1" >>"$GITHUB_OUTPUT" 2>/dev/null \
			|| printf 'docs-only: could not write GITHUB_OUTPUT (treated as a full run)\n'
	fi
	if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
		printf '%s\n' "$line" >>"$GITHUB_STEP_SUMMARY" 2>/dev/null || true
	fi
	exit 0
}

[ -z "$BAD_ARG" ] || verdict false "classifier error: unknown argument '$BAD_ARG'"
case "$PR" in
	'')          verdict false "not a pull request (no PR number), so nothing is skipped" ;;
	*[!0-9]*)    verdict false "classifier error: PR number '$PR' is not a number" ;;
esac

LIST="$(mktemp "${TMPDIR:-/tmp}/docs-only.XXXXXX" 2>/dev/null)" \
	|| verdict false "classifier error: cannot create a temp file"
trap 'rm -f "$LIST" "$LIST.z"' EXIT

if [ -n "$PATHS_FROM" ]; then
	if [ "$PATHS_FROM" = - ]; then
		cat >"$LIST" || verdict false "classifier error: cannot read the path list from stdin"
	else
		cat "$PATHS_FROM" >"$LIST" 2>/dev/null \
			|| verdict false "classifier error: cannot read the path list '$PATHS_FROM'"
	fi
else
	[ -n "$BASE" ] || verdict false "classifier error: no base branch given"
	# Checked out by CI as root in a container, the workspace may be "dubious ownership"
	# to git; the env-var form of -c reaches every git below.
	export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'
	export GIT_TERMINAL_PROMPT=0
	git check-ref-format --branch "$BASE" >/dev/null 2>&1 \
		|| verdict false "classifier error: base '$BASE' is not a valid branch name"
	git rev-parse --verify -q HEAD >/dev/null 2>&1 \
		|| verdict false "classifier error: no HEAD to compare (not a git checkout?)"
	REF="refs/remotes/origin/$BASE"
	if ! git rev-parse --verify -q "$REF^{commit}" >/dev/null 2>&1; then
		git fetch -q --no-tags --depth=1 origin "+refs/heads/$BASE:$REF" >/dev/null 2>&1 || true
	fi
	git rev-parse --verify -q "$REF^{commit}" >/dev/null 2>&1 \
		|| verdict false "base ref origin/$BASE could not be resolved or fetched"
	if ! git merge-base "$REF" HEAD >/dev/null 2>&1 \
		&& [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
		git fetch -q --no-tags --unshallow origin "+refs/heads/$BASE:$REF" >/dev/null 2>&1 || true
	fi
	if git merge-base "$REF" HEAD >/dev/null 2>&1; then
		set -- "$REF...HEAD"; how="since the fork from origin/$BASE"
	else
		set -- "$REF" HEAD; how="against the tip of origin/$BASE (no merge base reachable)"
	fi
	# -z so an odd path survives intact; --no-renames so a rename lists BOTH sides (moving a
	# script into docs/ still names the script).
	git -c core.quotepath=off diff --name-only --no-renames -z "$@" >"$LIST.z" 2>/dev/null \
		|| verdict false "classifier error: git diff against origin/$BASE failed"
	tr '\0' '\n' <"$LIST.z" >"$LIST" || verdict false "classifier error: cannot read the diff"
fi

how="${how:-in the given path list}"
n=0
while IFS= read -r p || [ -n "$p" ]; do
	p="${p%$'\r'}"
	[ -n "$p" ] || continue
	n=$((n + 1))
	ok=0
	while IFS= read -r pat; do
		[ -n "$pat" ] || continue
		# shellcheck disable=SC2254 # the patterns are meant to glob
		case "$p" in $pat) ok=1; break ;; esac
	done <<EOF
$ALLOWLIST
EOF
	[ "$ok" = 1 ] || verdict false "'$p' is not on the inert-docs allowlist (scripts/ci/docs-only.sh)"
done <"$LIST"

[ "$n" -gt 0 ] || verdict false "the diff is empty, so there is nothing to prove inert"
verdict true "all $n changed path(s) $how are on the inert-docs allowlist"
