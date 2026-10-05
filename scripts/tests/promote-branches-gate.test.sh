#!/usr/bin/env bash
# Behavioural tests for promoting-branches' `pr`-hop repo preflight gate (FJ-231).
#
# The red-gate handler once ended in a `continue` with no shell loop around it: bash prints a
# warning, returns 0, and falls through to the push on the next line. A wording check passed it.
# So, like promote-gate.test.sh, this lifts the REAL gate and publish blocks out of the skill and
# runs each in its own shell, with the real Step 1 block restated on top, against a fake `flight`,
# `git` and identity helper. Only things that survive a tool call may carry the verdict (the
# config, a file under $SCRATCH). $SCRATCH, $INT and the issue identity are values the agent
# names rather than derives, so they are given to every call, not carried.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$REPO_ROOT/flight/skills/promoting-branches/SKILL.md"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
export SANDBOX   # the fakes below read it
mkdir -p "$SANDBOX/bin" "$SANDBOX/scratch" "$SANDBOX/main/.git"

# The first fenced block containing $2. Same extractor as promote-gate.test.sh: line-based (a
# multi-character RS is not portable awk), CR-stripped for the MSYS leg, and reading to the END
# so an early exit cannot SIGPIPE `tr` under pipefail. <zone> is left for call() to fill.
block() {
	tr -d '\r' < "$SKILL" | awk -v want="$2" '
		found { next }
		/^```/ { if (inb) { if (hit) { printf "%s", buf; found = 1 } inb = 0 }
		         else { inb = 1; buf = ""; hit = 0 }
		         next }
		inb { buf = buf $0 "\n"; if (index($0, want)) hit = 1 }
		END { exit !found }
	' | sed -e 's/<your-model-id>/test-model/g' -e 's/<pr#>/7/g' > "$SANDBOX/$1.sh" \
		|| { echo "FAIL: no fenced block containing '$2' in promoting-branches/SKILL.md"; exit 1; }
}
block step1 'git rev-parse --git-common-dir'
block gate 'preflight-verdict-<zone>"'
block publish 'pr open --head'

# Structural, as well as behavioural: the push and `pr open` are guarded by the verdict, and the
# block has no `continue` to fall through (the per-group loop is prose, not shell).
grep -q 'continue' "$SANDBOX/gate.sh" "$SANDBOX/publish.sh" \
	&& { echo "FAIL: a gate or publish block uses continue, which has no loop to continue"; exit 1; }
awk '
	/preflight-verdict-<zone>/ { guard = NR }
	/push -u origin "\$INT"/  { push = NR }
	/pr open --head/          { open = NR }
	/^else$/                  { els = NR }
	END { exit !(guard && push > guard && open > push && els > open) }
' "$SANDBOX/publish.sh" || { echo "FAIL: push / pr open do not sit inside the verdict guard"; exit 1; }

cat >"$SANDBOX/bin/flight" <<'SH'
#!/usr/bin/env bash
[ -f "$SANDBOX/config-unreadable" ] && exit 1
case "$*" in
	"pr open"*)  echo "DID-PR" >>"$SANDBOX/actions"; printf '7\thttp://example.invalid/7\n' ;;
	"pr merge"*) echo "DID-PR-MERGE" >>"$SANDBOX/actions" ;;
	*preflight*) cat "$SANDBOX/gate" ;;
	*"stages | length"*) echo 1 ;;
	*closesIssues*) echo null ;;
	*"stages[0].name"*) echo develop ;;
	*"stages[0].merge"*) echo pr ;;
	*) echo merge ;;
esac
SH
cat >"$SANDBOX/bin/git" <<'SH'
#!/usr/bin/env bash
case "$*" in
	*"rev-parse --git-common-dir"*) echo "$SANDBOX/main/.git" ;;
	# Only the integration worktree being judged answers with the group's sha.
	*"/int-"*"rev-parse HEAD"*) cat "$SANDBOX/sha" ;;
	*"rev-parse HEAD"*) echo "main-tip-never-moves" ;;
	*" push"*) echo "DID-PUSH $*" >>"$SANDBOX/actions" ;;
	*"branch -D"*|*"worktree remove --force"*) echo "CLEANUP $*" >>"$SANDBOX/cleanup" ;;
esac
exit 0
SH
cat >"$SANDBOX/bin/issue-identity" <<'SH'
#!/usr/bin/env bash
echo "DID-BODY" >>"$SANDBOX/actions"; echo "Closes #1"
SH
chmod +x "$SANDBOX/bin/flight" "$SANDBOX/bin/git" "$SANDBOX/bin/issue-identity"

# One tool call: a new shell, Step 1 restated, then the block for zone $2 (default zone1).
call() {
	local zone="${2:-zone1}"
	PATH="$SANDBOX/bin:$PATH" bash -c "SCRATCH='$SANDBOX/scratch'
INT='batch/$zone-x'
ISSUE='{}'
ISSUE_IDENTITY='$SANDBOX/bin/issue-identity'
$(cat "$SANDBOX/step1.sh")
$(sed "s/<zone>/$zone/g" "$SANDBOX/$1.sh")" >>"$SANDBOX/out" 2>&1 || true
}
fresh() {   # $1 = the configured gate command ('' = key absent)
	rm -rf "$SANDBOX/scratch" "$SANDBOX/actions" "$SANDBOX/cleanup" "$SANDBOX/out" "$SANDBOX/config-unreadable"
	mkdir -p "$SANDBOX/scratch/int-zone1" "$SANDBOX/scratch/int-zone2"   # the assemble block's worktrees
	printf '%s' "$1" >"$SANDBOX/gate"
	echo aaa111 >"$SANDBOX/sha"
	: >"$SANDBOX/actions"; : >"$SANDBOX/cleanup"; : >"$SANDBOX/out"
}
PASSED=0
acted() {
	if ! grep -q DID-PUSH "$SANDBOX/actions" || ! grep -q DID-PR "$SANDBOX/actions"; then
		echo "FAIL: $1: should have pushed and opened the PR"; cat "$SANDBOX/out"; exit 1
	fi
	PASSED=$((PASSED + 1))
}
refused() {
	# Nothing after the handler: no push attempt, no PR body, no `pr open`.
	[ ! -s "$SANDBOX/actions" ] || { echo "FAIL: $1: published, must skip the group"; cat "$SANDBOX/actions" "$SANDBOX/out"; exit 1; }
	# A refusal must say why: silence is indistinguishable from a group that did nothing.
	grep -q "$2" "$SANDBOX/out" || { echo "FAIL: $1: skipped without saying '$2'"; cat "$SANDBOX/out"; exit 1; }
	PASSED=$((PASSED + 1))
}

fresh '';      call publish;                         acted   "ungated, gate block skipped"
fresh '';      call gate; call publish;              acted   "ungated, gate block run"
fresh 'true';  call gate; call publish;              acted   "green gate"
fresh 'false'; call gate; call publish;              refused "red gate" 'not green'
grep -q 'FAILED(zone1, preflight)' "$SANDBOX/out" || { echo "FAIL: red gate not recorded as FAILED"; exit 1; }
grep -q 'branch -D batch/zone1-x' "$SANDBOX/cleanup" || { echo "FAIL: red gate left \$INT standing"; exit 1; }
fresh 'true';  call publish;                         refused "gated, gate never run" 'not green'
fresh 'true';  call gate; echo bbb222 >"$SANDBOX/sha"
               call publish;                         refused "stale pass, new commit" 'not green'
fresh 'true';  call gate; touch "$SANDBOX/config-unreadable"
               call publish;                         refused "config unreadable" 'could not read'
fresh 'true';  call gate; printf 'false' >"$SANDBOX/gate"
               call gate; call publish;              refused "green, then red re-run" 'not green'
fresh 'false'; call gate; printf 'true' >"$SANDBOX/gate"
               call gate; call publish;              acted   "red, fixed, re-run"

# Other groups continue: a red zone1 does not stop a green zone2, and zone2's pass is its own.
fresh 'false'; call gate zone1; call publish zone1
printf 'true' >"$SANDBOX/gate"; call gate zone2; call publish zone2
grep -q 'DID-PUSH.*batch/zone2-x' "$SANDBOX/actions" || { echo "FAIL: green zone2 did not publish"; cat "$SANDBOX/out"; exit 1; }
grep -q 'batch/zone1-x' "$SANDBOX/actions" && { echo "FAIL: red zone1 published"; exit 1; }
PASSED=$((PASSED + 1))

printf 'Passed: %d  Failed: 0\n' "$PASSED"
printf 'promoting-branches gate tests passed\n'
