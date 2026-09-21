#!/usr/bin/env bash
# Unit tests for scripts/run-tests.sh itself — the parallel runner (#212).
#
# The runner is the one script whose failure mode is silence: if it loses a
# child's exit code, every other test in the suite can go red and CI still
# reports green. So the contract under test is narrow and behavioural:
# each test file's rc reaches the tally, 141 is still named, output is not
# interleaved, and TEST_JOBS=1 is still the serial path people debug with.
#
# Fixtures are generated into a throwaway TEST_DIR rather than reusing the real
# scripts/tests/, so this test neither runs the suite recursively nor depends on
# how many files the suite happens to have.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUNNER="$REPO_ROOT/scripts/run-tests.sh"

pass=0; fail=0
check() { if [ "$2" = 1 ]; then printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass+1));
			else printf '\033[0;31m  ✗ %s\033[0m  %s\n' "$1" "${3:-}"; fail=$((fail+1)); fi; }

SANDBOX="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$SANDBOX"' EXIT

# ── fixtures: one test file per exit behaviour ────────────────────────────────
# mkfixture <name> <body…> — a *.test.sh in $D that does exactly what we say.
D="$SANDBOX/tests"; mkdir -p "$D"
mkfixture() {
	local name="$1"; shift
	printf '#!/usr/bin/env bash\n%s\n' "$*" >"$D/$name.test.sh"
	chmod +x "$D/$name.test.sh"
}

# `env` is load-bearing: a bare `TEST_DIR=… "$@" bash …` would parse an expanded
# VAR=value as the command name, not as an assignment.
run() { TEST_DIR="$D" env "$@" bash "$RUNNER" 2>&1; }

# ── 1. all green ─────────────────────────────────────────────────────────────
mkfixture alpha 'echo alpha-ran; exit 0'
mkfixture beta  'echo beta-ran;  exit 0'

out="$(run)"; rc=$?
check "all-passing suite exits 0" \
	"$([ "$rc" -eq 0 ] && echo 1 || echo 0)" "rc=$rc"
check "all-passing suite says so" \
	"$(grep -q 'All tests passed' <<<"$out" && echo 1 || echo 0)" "out=$out"
check "each test file's own output is shown" \
	"$(grep -q alpha-ran <<<"$out" && grep -q beta-ran <<<"$out" && echo 1 || echo 0)" "out=$out"
check "each test file gets its banner" \
	"$(grep -q 'alpha.test.sh' <<<"$out" && grep -q 'beta.test.sh' <<<"$out" && echo 1 || echo 0)" "out=$out"

# ── 2. a failing child must reach the tally ──────────────────────────────────
# The whole point: with xargs -P the parent sees 123, not which child failed,
# so a lost rc here would turn a red suite green.
mkfixture gamma 'echo gamma-ran; exit 1'

out="$(run)"; rc=$?
check "one failing test file makes the suite exit 1" \
	"$([ "$rc" -eq 1 ] && echo 1 || echo 0)" "rc=$rc"
check "the failing file is named in the summary" \
	"$(grep -q 'gamma.test.sh' <<<"$out" && echo 1 || echo 0)" "out=$out"
check "the passing files still ran alongside it" \
	"$(grep -q alpha-ran <<<"$out" && grep -q beta-ran <<<"$out" && echo 1 || echo 0)" "out=$out"
check "the failure count is 1, not 0 or 3" \
	"$(grep -qE '1 test file\(s\) failed' <<<"$out" && echo 1 || echo 0)" "out=$out"
rm -f "$D/gamma.test.sh"

# ── 3. exit 141 is still named as SIGPIPE (#110) ──────────────────────────────
# releases.test.sh really did exit 141 from `| head -1` under pipefail, and the
# runner naming it is what made that diagnosable. Keep it.
mkfixture sigpipe 'echo sigpipe-ran; exit 141'

out="$(run)"; rc=$?
check "exit 141 fails the suite" \
	"$([ "$rc" -eq 1 ] && echo 1 || echo 0)" "rc=$rc"
check "exit 141 is explained as SIGPIPE, not just numbered" \
	"$(grep -q 'SIGPIPE' <<<"$out" && echo 1 || echo 0)" "out=$out"
rm -f "$D/sigpipe.test.sh"

# ── 4. TEST_JOBS=1 is the serial path, and still correct ─────────────────────
mkfixture delta 'echo delta-ran; exit 1'

out="$(run TEST_JOBS=1)"; rc=$?
check "TEST_JOBS=1 still exits 1 on a failure" \
	"$([ "$rc" -eq 1 ] && echo 1 || echo 0)" "rc=$rc"
check "TEST_JOBS=1 still names the failing file" \
	"$(grep -q 'delta.test.sh' <<<"$out" && echo 1 || echo 0)" "out=$out"
rm -f "$D/delta.test.sh"

# ── 5. output is not interleaved ──────────────────────────────────────────────
# Each file's lines must arrive as one contiguous block, or a parallel failure is
# unreadable. Two files that each emit an interleavable burst; assert that every
# line between a file's first and last marker belongs to that file.
# The single quotes are the point: the body is written to the fixture verbatim and
# expanded when the fixture RUNS, not here.
# shellcheck disable=SC2016
mkfixture noise1 'for i in $(seq 1 40); do echo "N1-$i"; sleep 0.01; done'
# shellcheck disable=SC2016
mkfixture noise2 'for i in $(seq 1 40); do echo "N2-$i"; sleep 0.01; done'
rm -f "$D/alpha.test.sh" "$D/beta.test.sh"

out="$(run TEST_JOBS=4)"
# Between the first and last N1 line there must be no N2 line (and vice versa).
block_clean() {
	local mine="$1" other="$2"
	printf '%s\n' "$out" | grep -E "^($mine|$other)-" \
		| awk -v m="$mine" -v o="$other" '
			$0 ~ "^"m"-" { if (seen_other_after_mine) { bad=1 } ; seen_mine=1 }
			$0 ~ "^"o"-" { if (seen_mine && !done_mine) { seen_other_after_mine=1 } }
			END { exit (bad ? 1 : 0) }'
}
check "a test file's output arrives contiguously, not interleaved" \
	"$(block_clean N1 N2 && echo 1 || echo 0)" \
	"$(printf '%s\n' "$out" | grep -cE '^N[12]-') marker lines"

# ── 6. an empty test dir is not a silent pass ────────────────────────────────
E="$SANDBOX/empty"; mkdir -p "$E"
out="$(TEST_DIR="$E" bash "$RUNNER" 2>&1)"; rc=$?
check "an empty test dir says so" \
	"$(grep -q 'No tests found' <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"

# Summary: plain when nothing failed, red when something did (#123).
[ "$fail" -gt 0 ] && summary_colour=$'\033[0;31m' || summary_colour=''
printf '\n%sPassed: %d  Failed: %d\033[0m\n' "$summary_colour" "$pass" "$fail"
[ "$fail" -eq 0 ]
