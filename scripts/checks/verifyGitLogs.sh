#!/usr/bin/env bash
# Verify that recent commits carry valid signatures.
# Can be run from anywhere:
#   verifyGitLogs.sh        — check the unpushed commits (vs the upstream),
#                             or the last 10 if there are none / no upstream
#   verifyGitLogs.sh N      — check the most recent N commits
#
# A commit passes when `git` reports its signature as good (`%G?` = G or U,
# i.e. cryptographically valid; U = valid but the signing key isn't trusted).
# Bad, missing, expired, revoked, or unverifiable signatures fail.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

green=$'\033[0;32m'
red=$'\033[0;31m'
bold=$'\033[1m'
reset=$'\033[0m'

# ---------------------------------------------------------------------------
# Determine how many commits to verify.
# ---------------------------------------------------------------------------
count="${1:-}"

if [ -z "$count" ]; then
	unpushed=0
	if upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)"; then
		unpushed="$(git rev-list --count "${upstream}..HEAD" 2>/dev/null || echo 0)"
		echo "Upstream ${upstream}: ${unpushed} unpushed commit(s)."
	else
		echo "No upstream configured."
	fi
	if [ "$unpushed" -gt 0 ]; then
		count="$unpushed"
	else
		count=10
		echo "Falling back to the last ${count} commits."
	fi
fi

if ! [[ "$count" =~ ^[0-9]+$ ]] || [ "$count" -eq 0 ]; then
	echo "${red}error: commit count must be a positive integer (got '${count}')${reset}" >&2
	exit 2
fi

# Don't ask for more commits than exist.
total="$(git rev-list --count HEAD)"
if [ "$count" -gt "$total" ]; then
	count="$total"
fi

# ---------------------------------------------------------------------------
# Verify each commit's signature.
# ---------------------------------------------------------------------------
printf '%s▶ Verifying signatures on the most recent %s commit(s)%s\n' "$bold" "$count" "$reset"

fail=0
while read -r sha; do
	status="$(git show --no-patch --format='%G?' "$sha")"
	subject="$(git show --no-patch --format='%s' "$sha")"
	short="$(git rev-parse --short "$sha")"
	case "$status" in
	G | U)
		printf '%s  ✓ %s [%s] %s%s\n' "$green" "$short" "$status" "${subject:0:60}" "$reset"
		;;
	*)
		printf '%s  ✗ %s [%s] %s%s\n' "$red" "$short" "$status" "${subject:0:60}" "$reset"
		fail=$((fail + 1))
		;;
	esac
done < <(git rev-list -n "$count" HEAD)

echo
if [ "$fail" -gt 0 ]; then
	printf '%s%d of %d commit(s) have invalid or missing signatures.%s\n' "$red" "$fail" "$count" "$reset" >&2
	exit 1
fi
printf '%sAll %d commit(s) have valid signatures.%s\n' "$green" "$count" "$reset"
