#!/usr/bin/env bash
# Runs all script unit tests in scripts/tests/ (*.test.sh) and exits non-zero
# if any fail. These are unit tests for the repo's own scripts — distinct from
# scripts/checks/ (pre-push working-tree cleanliness) and test-rig/ (per-backend
# integration smoke). Run on demand, and in CI via .github/workflows/tests.yml.
#
# Test files run in PARALLEL (#212). They are independent by construction — each
# builds its own `mktemp -d` sandbox — and the Windows leg was ~25x the Linux one
# purely on per-process cost, so width is the only lever that helps every leg at
# once. Each file's output is buffered and flushed in one write when it finishes,
# so blocks stay contiguous; the ORDER is completion order, not alphabetical.
#
# Knobs:
#   TEST_JOBS=N  width. Default is the core count, capped at 8. TEST_JOBS=1 is
#                the old serial path, and the first thing to reach for when a
#                failure looks like it depends on what else was running.
#   TEST_DIR=…   the directory of *.test.sh to run (default: scripts/tests/).
set -euo pipefail

TEST_DIR="${TEST_DIR:-$(cd "$(dirname "$0")" && pwd)/tests}"
# Absolute, so the xargs re-exec below does not depend on the caller's cwd.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# ── worker mode: run exactly one job ─────────────────────────────────────────
# `--one <spec>` where <spec> is "<file>" or "<file><TAB><VAR>=<value>".
# Re-execing this script beats a second file: the worker and the tally can never
# drift out of sync. $OUT_DIR is where the parent collects exit codes; without it
# (someone running --one by hand) the rc is simply this process's exit status.
if [ "${1:-}" = --one ]; then
	spec="${2:-}"
	[ -n "$spec" ] || { echo "run-tests.sh --one: missing job spec" >&2; exit 2; }

	file="${spec%%	*}"                       # up to the first literal tab
	label="$(basename "$file")"
	if [ "$spec" != "$file" ]; then           # a sharded job carries one VAR=value
		assign="${spec#*	}"
		export "${assign%%=*}"="${assign#*=}"
		label="$label (${assign#*=})"
	fi

	buf="$(mktemp "${TMPDIR:-/tmp}/run-tests-out.XXXXXX")"
	printf '\033[1m━━━ %s ━━━\033[0m\n' "$label" >"$buf"
	rc=0
	bash "$file" >>"$buf" 2>&1 || rc=$?
	if [ "$rc" -ne 0 ]; then
		# Name the exit code: 141 = SIGPIPE from an early-closing `| head` under pipefail (#110).
		printf '\033[0;31m✗ %s exited %d%s\033[0m\n' "$label" "$rc" \
			"$([ "$rc" -eq 141 ] && printf ' (SIGPIPE — a pipe reader closed early, e.g. "| head")')" >>"$buf"
	fi
	cat "$buf"                                # one write, so the block stays whole
	rm -f "$buf"

	if [ -n "${OUT_DIR:-}" ]; then
		# mktemp, not $$: a recycled pid could otherwise clobber an earlier result.
		printf '%s\t%s\n' "$rc" "$label" >"$(mktemp "$OUT_DIR/rc.XXXXXX")"
		exit 0                                # the tally owns the verdict, not xargs
	fi
	exit "$rc"
fi

# ── job list ─────────────────────────────────────────────────────────────────
# shards <file> — the jobs for one test file: normally itself, but a file slow
# enough to set the floor for the whole parallel run is split here. ci-watch is
# sleep-bound rather than spawn-bound (real `date +%s` waits in its timeout
# cases), so it stays the longest job on every leg unless its three backends run
# side by side.
shards() {
	case "$1" in
		*/ci-watch.test.sh)
			printf '%s\tCI_WATCH_BACKENDS=forgejo\n' "$1"
			printf '%s\tCI_WATCH_BACKENDS=github\n'  "$1"
			printf '%s\tCI_WATCH_BACKENDS=gitlab\n'  "$1"
			;;
		*) printf '%s\n' "$1" ;;
	esac
}

OUT_DIR="$(mktemp -d)"
trap 'rm -rf "$OUT_DIR"' EXIT

for test in "$TEST_DIR"/*.test.sh; do
	[ -e "$test" ] || continue
	shards "$test"
done >"$OUT_DIR/jobs"

# BSD `wc` pads its count, hence the tr.
jobs_total="$(tr -cd '\n' <"$OUT_DIR/jobs" | wc -c | tr -d ' ')"
if [ "$jobs_total" -eq 0 ]; then
	printf '\033[0;33mNo tests found in %s\033[0m\n' "$TEST_DIR"
	exit 0
fi

# ── width ────────────────────────────────────────────────────────────────────
# Capped: past ~8 these tests contend on /tmp and the git index, and a 64-core
# box would otherwise start 30 sandboxes at once for no gain.
width="${TEST_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
case "$width" in ''|*[!0-9]*) width=4 ;; esac
if [ "$width" -lt 1 ]; then width=1; fi
if [ "$width" -gt 8 ]; then width=8; fi

printf '\033[1mRunning %d job(s) across %d worker(s)\033[0m\n' "$jobs_total" "$width"

# NUL-delimited so a spec's tab stays inside one argv. BusyBox xargs — what both
# Alpine legs have, since they install coreutils but not findutils — supports
# -0/-n1/-P; verified on alpine:3.22.6, where -P works although its own --help
# does not list it. `|| true` because xargs reports 123 for "some child failed",
# which is not the verdict: the rc files below are.
tr '\n' '\0' <"$OUT_DIR/jobs" \
	| OUT_DIR="$OUT_DIR" xargs -0 -n1 -P "$width" bash "$SELF" --one || true

# ── tally ────────────────────────────────────────────────────────────────────
# Read from the rc files, never from xargs' exit status: xargs cannot say WHICH
# job failed, and a worker that died before writing its rc has to count as a
# failure rather than vanish.
ran=0; fail=0; failed=''
for rc_file in "$OUT_DIR"/rc.*; do
	[ -e "$rc_file" ] || continue
	ran=$((ran + 1))
	# An empty rc means the worker was killed mid-write; that is a failure, not a pass.
	rc="$(cut -f1 <"$rc_file")"; rc="${rc:-killed}"
	if [ "$rc" != 0 ]; then
		fail=$((fail + 1))
		failed="$failed  $(cut -f2 <"$rc_file") (exit $rc)
"
	fi
done

# Failures print before the accounting check, so a run that both failed a test AND
# lost a worker still tells you which test failed.
if [ "$fail" -gt 0 ]; then
	printf '\n\033[0;31m%d test file(s) failed:\033[0m\n%s' "$fail" "$failed"
fi

if [ "$ran" -ne "$jobs_total" ]; then
	printf '\033[0;31m✗ %d job(s) queued but only %d reported — a worker died\033[0m\n' \
		"$jobs_total" "$ran"
	exit 1
fi

if [ "$fail" -gt 0 ]; then
	exit 1
fi

printf '\n\033[0;32mAll tests passed.\033[0m\n'
