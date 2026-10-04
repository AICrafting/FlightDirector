#!/usr/bin/env bash
# Behavioural tests for working-an-issue Step 2's repo preflight gate (FJ-221).
#
# Like promote-gate.test.sh, this does not grep the prose: it lifts the REAL Step 2 block out of
# the skill and runs it in a fresh shell against a fake `flight`, with a real `sh -c` gate in a
# real worktree directory. The property: the to-test label moves only when the repo is ungated or
# the gate passed, and every refusal says why.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$REPO_ROOT/flight/skills/working-an-issue/SKILL.md"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
export SANDBOX   # the fake below reads it
mkdir -p "$SANDBOX/bin" "$SANDBOX/scratch" "$SANDBOX/wt"

# The first fenced block containing $1. Line-based, CR-stripped for the MSYS leg, and reading to
# the END so an early exit cannot SIGPIPE `tr` under pipefail.
tr -d '\r' < "$SKILL" | awk -v want='--status to-test' '
	found { next }
	/^```/ { if (inb) { if (hit) { printf "%s", buf; found = 1 } inb = 0 }
	         else { inb = 1; buf = ""; hit = 0 }
	         next }
	inb { buf = buf $0 "\n"; if (index($0, want)) hit = 1 }
	END { exit !found }
' > "$SANDBOX/step2.sh" || { echo "FAIL: no fenced block moving to to-test in working-an-issue/SKILL.md"; exit 1; }

# Structural: the block reads the gate, and its set-status is not unconditional.
grep -q "code.preflight" "$SANDBOX/step2.sh" || { echo "FAIL: Step 2 does not read code.preflight"; exit 1; }
grep -q '^flight issues set-status' "$SANDBOX/step2.sh" \
	&& { echo "FAIL: Step 2 moves the label outside the gate's guard"; exit 1; }

cat >"$SANDBOX/bin/flight" <<'SH'
#!/usr/bin/env bash
[ -f "$SANDBOX/config-unreadable" ] && exit 1
case "$*" in
	*"--status to-test"*) echo "DID-TO-TEST" >>"$SANDBOX/actions" ;;
	*preflight*) cat "$SANDBOX/gate" ;;
esac
SH
chmod +x "$SANDBOX/bin/flight"

call() {
	PATH="$SANDBOX/bin:$PATH" bash -c "SCRATCH='$SANDBOX/scratch'
WT='$SANDBOX/wt'
TRACKER=FJ NUMBER=221 PREFIX=fj-221 DISPLAY=FJ-221
$(cat "$SANDBOX/step2.sh")" >>"$SANDBOX/out" 2>&1 || true
}
fresh() {   # $1 = the configured gate command ('' = key absent)
	rm -f "$SANDBOX/actions" "$SANDBOX/out" "$SANDBOX/config-unreadable" "$SANDBOX/wt/marker"
	printf '%s' "$1" >"$SANDBOX/gate"
	: >"$SANDBOX/actions"; : >"$SANDBOX/out"
}
PASSED=0
moved() {
	grep -q DID-TO-TEST "$SANDBOX/actions" || { echo "FAIL: $1: should have moved to to-test"; cat "$SANDBOX/out"; exit 1; }
	PASSED=$((PASSED + 1))
}
held() {
	[ ! -s "$SANDBOX/actions" ] || { echo "FAIL: $1: moved to to-test, must not"; cat "$SANDBOX/out"; exit 1; }
	grep -q "$2" "$SANDBOX/out" || { echo "FAIL: $1: held without saying '$2'"; cat "$SANDBOX/out"; exit 1; }
	PASSED=$((PASSED + 1))
}

fresh '';      call; moved "ungated"
fresh 'true';  call; moved "green gate"
grep -q 'preflight: passed' "$SANDBOX/out" || { echo "FAIL: a green gate is not reported"; exit 1; }
fresh 'echo boom; exit 3'; call; held "red gate" 'preflight failed'
grep -q boom "$SANDBOX/out" || { echo "FAIL: red gate did not show the log tail"; exit 1; }
fresh 'true';  touch "$SANDBOX/config-unreadable"; call; held "config unreadable" 'could not read'
# The gate runs in the issue's worktree, not wherever the shell happens to be.
fresh 'touch marker'; call; moved "gate in worktree"
[ -f "$SANDBOX/wt/marker" ] || { echo "FAIL: the gate did not run in \$WT"; exit 1; }
PASSED=$((PASSED + 1))

printf 'Passed: %d  Failed: 0\n' "$PASSED"
printf 'to-test gate tests passed\n'
