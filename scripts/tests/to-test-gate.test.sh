#!/usr/bin/env bash
# Behavioural tests for working-an-issue Step 2's repo preflight gate (FJ-221).
#
# Like promote-gate.test.sh, this does not grep the prose: it lifts the REAL Step 2 block out of
# the skill and runs it in a fresh shell against a fake `flight` whose `preflight run` is the REAL
# preflight helper (FJ-307), running a real gate in a real git worktree. The property: the to-test
# label moves only when the repo is ungated or the gate passed, and every refusal says why.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PREFLIGHT_HELPER="$REPO_ROOT/flight/scripts/preflight"
SKILL="$REPO_ROOT/flight/skills/working-an-issue/SKILL.md"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
export SANDBOX   # the fake below reads it
mkdir -p "$SANDBOX/bin" "$SANDBOX/scratch"
# A real worktree: the helper stamps its verdict with the commit it judged.
git init -q "$SANDBOX/wt"
git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m base

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

# Structural: the block runs the gate through the verb, never as its own `sh -c` (FJ-307), and its
# set-status is not unconditional.
grep -q "flight preflight run" "$SANDBOX/step2.sh" || { echo "FAIL: Step 2 does not run flight preflight run"; exit 1; }
grep -q 'sh -c' "$SANDBOX/step2.sh" && { echo "FAIL: Step 2 still runs the gate with sh -c"; exit 1; }
grep -q '^flight issues set-status' "$SANDBOX/step2.sh" \
	&& { echo "FAIL: Step 2 moves the label outside the gate's guard"; exit 1; }

# The fake dispatcher: `preflight run` reads the gate as the real one does and hands it to the
# real helper; an unreadable config fails the way the real dispatcher reports it.
cat >"$SANDBOX/bin/flight" <<'SH'
#!/usr/bin/env bash
case "$*" in
	*"--status to-test"*)
		echo "DID-TO-TEST" >>"$SANDBOX/actions"
		;;
	"preflight run "*)
		if [ -f "$SANDBOX/config-unreadable" ]; then
			echo "flight: could not read code.preflight from .flightdirector/config.json" >&2
			exit 1
		fi
		shift 2
		exec "$PREFLIGHT_HELPER" run --gate "$(cat "$SANDBOX/gate")" "$@"
		;;
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
fresh 'echo boom; exit 3'; call; held "red gate" 'did not pass'
grep -q boom "$SANDBOX/out" || { echo "FAIL: red gate did not show the log tail"; exit 1; }
fresh 'true';  touch "$SANDBOX/config-unreadable"; call; held "config unreadable" 'could not read'
# The gate runs in the issue's worktree, not wherever the shell happens to be.
fresh 'touch marker'; call; moved "gate in worktree"
[ -f "$SANDBOX/wt/marker" ] || { echo "FAIL: the gate did not run in \$WT"; exit 1; }
PASSED=$((PASSED + 1))

printf 'Passed: %d  Failed: 0\n' "$PASSED"
printf 'to-test gate tests passed\n'
