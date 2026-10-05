#!/usr/bin/env bash
# Contract tests for `flight preflight run|check` (FJ-307): the repo's code.preflight gate,
# run through the REAL dispatcher in a real git repository, with the verdict file the
# promotion guards read. The skills' own gate blocks are covered by to-test-gate,
# promote-gate and promote-branches-gate; this pins the verb they now call.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DISP="$REPO_ROOT/flight/scripts/flight"
SANDBOX="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

pass=0
fail=0
check() {
	if [ "$2" = 1 ]; then
		printf '\033[0;32m  ✓ %s\033[0m\n' "$1"
		pass=$((pass + 1))
	else
		printf '\033[0;31m  ✗ %s\033[0m\n  %s\n' "$1" "${3:-}"
		fail=$((fail + 1))
	fi
}
yes_if() { if "$@"; then echo 1; else echo 0; fi; }

# A repository with one commit and a flight config; `gate` sets code.preflight.
R="$SANDBOX/repo"
git init -q -b develop "$R"
git -C "$R" config user.email t@t
git -C "$R" config user.name t
git -C "$R" config commit.gpgsign false
printf 'base\n' >"$R/base"
git -C "$R" add base
git -C "$R" commit -qm base
mkdir -p "$R/.flightdirector"
gate() {
	jq -n --arg g "$1" '{schemaVersion: 3, code: {backend: "forgejo", preflight: $g}} | if $g == "" then del(.code.preflight) else . end' \
		>"$R/.flightdirector/config.json"
}

V="$SANDBOX/verdict"
LOG="$SANDBOX/gate.log"
HEAD_SHA="$(git -C "$R" rev-parse HEAD)"
run_gate()   { (cd "$R" && "$DISP" preflight run --worktree "$R" --log "$LOG" --verdict "$V") >"$SANDBOX/out" 2>&1; }
check_gate() { (cd "$R" && "$DISP" preflight check --worktree "$R" --verdict "$V") >"$SANDBOX/out" 2>&1; }

printf '\033[1m── run ──\033[0m\n'
gate ''
check "no gate configured: run succeeds" "$(yes_if run_gate)" "$(cat "$SANDBOX/out")"
check "…and says so" "$(yes_if grep -q 'none configured' "$SANDBOX/out")" "$(cat "$SANDBOX/out")"
check "…and records 'none <sha>'" "$(yes_if [ "$(cat "$V")" = "none $HEAD_SHA" ])" "$(cat "$V")"

gate 'echo all-good'
check "a green gate: run succeeds" "$(yes_if run_gate)" "$(cat "$SANDBOX/out")"
check "…reports it passed, naming the gate" "$(yes_if grep -q 'preflight: passed (echo all-good)' "$SANDBOX/out")" "$(cat "$SANDBOX/out")"
check "…records 'pass <sha>'" "$(yes_if [ "$(cat "$V")" = "pass $HEAD_SHA" ])" "$(cat "$V")"
check "…and writes the gate's output to --log" "$(yes_if grep -q all-good "$LOG")" "$(cat "$LOG")"

gate 'echo boom; exit 3'
check "a red gate: run fails" "$(yes_if [ "$(run_gate; echo $?)" = 1 ])" "$(cat "$SANDBOX/out")"
check "…shows the log's tail" "$(yes_if grep -q boom "$SANDBOX/out")" "$(cat "$SANDBOX/out")"
check "…and says where the full log is" "$(yes_if grep -q "full log: $LOG" "$SANDBOX/out")" "$(cat "$SANDBOX/out")"
check "…records 'fail <sha>'" "$(yes_if [ "$(cat "$V")" = "fail $HEAD_SHA" ])" "$(cat "$V")"

gate 'touch ran-here'
run_gate || true
check "the gate runs in --worktree, not the caller's directory" "$(yes_if [ -f "$R/ran-here" ])"
rm -f "$R/ran-here"

# An interrupted run must not leave the previous verdict standing.
gate 'echo ok'
run_gate
# shellcheck disable=SC2016  # $PPID is for the gate's own shell to expand, not this one
gate 'kill -9 $PPID'
( run_gate ) 2>/dev/null || true   # the subshell keeps bash's "Killed" notice out of the output
check "the old verdict is gone before the gate starts" "$(yes_if [ ! -s "$V" ])" "$(cat "$V" 2>/dev/null)"

printf '\033[1m── check ──\033[0m\n'
gate 'true'
run_gate
check "a pass for the current commit is accepted" "$(yes_if check_gate)" "$(cat "$SANDBOX/out")"
gate ''
run_gate
check "'none' for the current commit is accepted" "$(yes_if check_gate)" "$(cat "$SANDBOX/out")"

gate 'false'
run_gate || true
check "a failed gate is refused" "$(yes_if [ "$(check_gate; echo $?)" = 1 ])"
check "…and the refusal says the gate failed" "$(yes_if grep -q 'FAILED' "$SANDBOX/out")" "$(cat "$SANDBOX/out")"

gate 'true'
run_gate
printf 'more\n' >>"$R/base"
git -C "$R" commit -qam more
check "a verdict for an older commit is refused" "$(yes_if [ "$(check_gate; echo $?)" = 1 ])"
check "…and the refusal names both commits" "$(yes_if grep -q 'not the current' "$SANDBOX/out")" "$(cat "$SANDBOX/out")"

rm -f "$V"
check "no verdict at all is refused" "$(yes_if [ "$(check_gate; echo $?)" = 1 ])"
check "…and the refusal says to run the gate" "$(yes_if grep -q 'flight preflight run' "$SANDBOX/out")" "$(cat "$SANDBOX/out")"

printf '\033[1m── usage ──\033[0m\n'
check "run without --worktree is a usage error" \
	"$(yes_if [ "$(cd "$R" && "$DISP" preflight run >/dev/null 2>&1; echo $?)" = 2 ])"
check "an unknown verb is an error" \
	"$(yes_if [ "$(cd "$R" && "$DISP" preflight nope --worktree "$R" >/dev/null 2>&1; echo $?)" != 0 ])"
check "the capability token is advertised" "$(yes_if grep -qx preflight <<<"$("$DISP" capabilities)")"

[ "$fail" -gt 0 ] && colour=$'\033[0;31m' || colour=''
printf '\n%sPassed: %d  Failed: %d\033[0m\n' "$colour" "$pass" "$fail"
[ "$fail" -eq 0 ]
