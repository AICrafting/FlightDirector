#!/usr/bin/env bash
# The patterns below are literal skill text, so their $VARS must NOT expand.
# shellcheck disable=SC2016
# Contract checks for the tracker-aware workflow skills (#198). The skills are prose an agent
# executes, so these greps pin the rules that keep issue work on its originating tracker:
# resolve once, pass --tracker/--number (or a qualified id) on every issue and label call,
# qualified branch/worktree names, per-tracker label maps, and closing keywords only through
# issue-identity.sh's pr-reference.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SK="$REPO_ROOT/flight/skills"

pass=0; fail=0
check() { if [ "$2" = 1 ]; then printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass+1));
			else printf '\033[0;31m  ✗ %s\033[0m\n  %s\n' "$1" "${3:-}"; fail=$((fail+1)); fi; }
none() { [ -z "$1" ] && echo 1 || echo 0; }
has() { grep -qF -- "$2" "$1" && echo 1 || echo 0; }

LIFECYCLE="$SK/working-an-issue/SKILL.md $SK/filing-issues/SKILL.md $SK/triaging-issues/SKILL.md
$SK/queue-batches/SKILL.md $SK/queue-batches/templates/agent-prompt.md $SK/promoting-a-branch/SKILL.md
$SK/promoting-branches/SKILL.md $SK/cleaning-up-branches/SKILL.md"

# shellcheck disable=SC2086  # word-split file list
hits="$(grep -nE "config '\.labels|config \"\.labels" $LIFECYCLE || true)"
check "no workflow skill reads the retired top-level .labels map" "$(none "$hits")" "$hits"

# An issue/label verb on an issue must name its tracker (--tracker) or carry a qualified id.
# shellcheck disable=SC2086
hits="$(grep -nE 'issues (get|comments|comment|set-status|clear-status|close|label-add|label-remove|update|attach|assign)\b.*--number' $LIFECYCLE \
	| grep -vE -- '--tracker|--number "?[A-Z][A-Z0-9]*-[0-9]|--number "?<(qualified|QUALIFIED)|--number "\$QUALIFIED"' || true)"
check "every issue write/read names its tracker or a qualified id" "$(none "$hits")" "$hits"
# shellcheck disable=SC2086
hits="$(grep -nE 'labels ensure .*--model "' $LIFECYCLE | grep -v -- '--tracker' || true)"
check "model labels are ensured on the issue's own tracker" "$(none "$hits")" "$hits"
# shellcheck disable=SC2086
hits="$(grep -nE 'feature/<N>-<slug>"|worktrees/<N>-|feat\(#N\)|feat\(#<N>\)|ticket=#' $LIFECYCLE || true)"
check "no bare-number branch, worktree, commit or status-log templates remain" "$(none "$hits")" "$hits"
# shellcheck disable=SC2086
hits="$(grep -nE 'KEYWORD #N|\$KEYWORD' $LIFECYCLE || true)"
check "no hand-built Closes/Ready keyword lines remain" "$(none "$hits")" "$hits"

W="$SK/working-an-issue/SKILL.md"
check "working-an-issue resolves the issue once" "$(has "$W" 'ISSUE="$(flight issues resolve --number "$INPUT")"')"
check "working-an-issue names branch and worktree by the qualified prefix" \
	"$([ "$(has "$W" 'BRANCH="feature/$PREFIX-<slug>"')" = 1 ] && [ "$(has "$W" '".worktrees/$PREFIX-<slug>"')" = 1 ] && echo 1 || echo 0)"
check "working-an-issue retains the identity for the branch" "$(has "$W" '"$ISSUE_IDENTITY" remember --branch "$BRANCH" --identity "$ISSUE"')"
check "working-an-issue resumes from the branch, not the number" "$(has "$W" '"$ISSUE_IDENTITY" from-branch --branch "$BRANCH"')"

T="$SK/queue-batches/templates/agent-prompt.md"
check "batch agents resolve each qualified issue once" "$(has "$T" 'issues resolve --number <QUALIFIED>')"
check "batch agents name branches by the qualified prefix" "$(has "$T" 'BRANCH="feature/$PREFIX-<slug>"')"

for f in "$SK/promoting-a-branch/SKILL.md" "$SK/promoting-branches/SKILL.md"; do
	n="$(basename "$(dirname "$f")")"
	check "$n writes issue lines only through pr-reference" "$(has "$f" 'pr-reference --identity "$ISSUE" --closes')"
	check "$n closes on the issue's own tracker" "$(has "$f" 'issues close --tracker "$TRACKER" --number "$NUMBER"')"
done
check "promoting-a-branch takes a feature branch's identity from the branch" \
	"$(has "$SK/promoting-a-branch/SKILL.md" 'ISSUE="$("$ISSUE_IDENTITY" from-branch --branch "$BRANCH")"')"
check "promoting-a-branch resolves history references through the helper" \
	"$(has "$SK/promoting-a-branch/SKILL.md" '"$ISSUE_IDENTITY" from-history --ref')"
check "promoting-branches reads each tracker's own to-test label" \
	"$(has "$SK/promoting-branches/SKILL.md" 'issues tracker --tracker "$TRACKER" | jq -r '"'"'.labels.status["to-test"] // empty'"'"'')"
check "cleaning-up-branches reads each tracker's own status labels" \
	"$(has "$SK/cleaning-up-branches/SKILL.md" "issues tracker --tracker FJ | jq -r '.labels.status[\"to-test\"] // empty'")"

for f in "$SK/triaging-issues/SKILL.md" "$SK/filing-issues/SKILL.md" "$SK/queue-batches/SKILL.md"; do
	check "$(basename "$(dirname "$f")") lists every tracker" "$(has "$f" 'issues list --all-trackers')"
done
check "batch manifests are written with qualified identities" "$(has "$SK/queue-batches/SKILL.md" '--issues "<zone-a qualified identities>"')"

check "runtime preflight defines the identity helper" \
	"$(has "$REPO_ROOT/flight/references/runtime.md" 'ISSUE_IDENTITY=<plugin-root>/scripts/issue-identity.sh')"
check "promoting-a-branch asks on an ambiguous bare history reference" \
	"$(has "$SK/promoting-a-branch/SKILL.md" 'Exit 4 always means "ask"')"
check "cleaning-up-branches never treats a failed lookup as no issue" \
	"$(has "$SK/cleaning-up-branches/SKILL.md" '`error` → the identity lookup failed')"
check "the adapter contract documents the branches error value" \
	"$(has "$REPO_ROOT/flight/references/adapter-contract.md" '`error` when the identity lookup itself failed')"
hits="$(grep -rn 'work-items\.json\|bind-legacy-default' "$REPO_ROOT/flight" "$REPO_ROOT/.gitignore" || true)"
check "nothing uses the retired work-items.json path or a second legacy binder" "$(none "$hits")" "$hits"

[ "$fail" -gt 0 ] && colour=$'\033[0;31m' || colour=''
printf '\n%sPassed: %d  Failed: %d\033[0m\n' "$colour" "$pass" "$fail"
[ "$fail" -eq 0 ]
