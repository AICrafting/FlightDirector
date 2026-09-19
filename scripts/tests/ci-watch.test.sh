#!/usr/bin/env bash
# Unit tests for the `ci watch` adapter verb (forgejo + github + gitlab), covering the
# SHA-source fix and the no-run hang guard. The network is stubbed with a fake
# `curl` on PATH (see $FAKE_DIR/curl) so no live backend or Docker is needed.
#
# Regression: watching a *local* `git rev-parse HEAD` that was never pushed used
# to poll forever, because CI only ever runs on pushed SHAs. `--pr` now resolves
# the PR head SHA (== the run's head_sha), and `--timeout` bounds the wait.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

pass=0; fail=0
check() { if [ "$2" = 1 ]; then printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass+1));
			else printf '\033[0;31m  ✗ %s\033[0m  %s\n' "$1" "${3:-}"; fail=$((fail+1)); fi; }

SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT

# --- fake curl: answers /pulls/<n> from pr.json and the runs list from runs.json.
# Honors `-o FILE` + `-w` (used by _api) as well as plain stdout (watch loop).
FAKE_DIR="$SANDBOX/bin"; mkdir -p "$FAKE_DIR"
cat >"$FAKE_DIR/curl" <<'EOF'
#!/usr/bin/env bash
# runs_file — which list snapshot this call gets. When runs-after.json exists,
# the first $SWITCH_AFTER calls to the list endpoint see runs.json and every
# later one sees runs-after.json, which is how a run is made to sit queued for
# a while and then finish (#171). The counter lives in a file because each call
# is a fresh process.
runs_file() {
	local n=0
	[ -f "$FAKE_RESP/runs-after.json" ] || { printf '%s' "$FAKE_RESP/runs.json"; return; }
	[ ! -f "$FAKE_RESP/calls" ] || n="$(cat "$FAKE_RESP/calls")"
	n=$((n + 1)); printf '%s' "$n" >"$FAKE_RESP/calls"
	if [ "$n" -gt "${SWITCH_AFTER:-0}" ]; then printf '%s' "$FAKE_RESP/runs-after.json"
	else printf '%s' "$FAKE_RESP/runs.json"; fi
}
outfile=""; want_code=0; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) outfile="$2"; shift 2 ;;
    -w) want_code=1; shift 2 ;;        # consume the format arg too
    http*|https*) url="$1"; shift ;;
    *) shift ;;
  esac
done
case "$url" in
  */pulls/*|*/merge_requests/*) body="$(cat "$FAKE_RESP/pr.json")" ;;
  # Per-run / per-pipeline job list (#171): how the adapter tells a run that is
  # really executing from one whose every leg is still waiting for a runner.
  # Matched before the list endpoints, which these URLs also glob onto.
  */actions/runs/*/jobs*|*/pipelines/*/jobs*)
    # No jobs.json written → empty body, which the adapter must read as "cannot
    # tell", i.e. executing. That is what every pre-#171 case relies on.
    body="$(cat "$FAKE_RESP/jobs.json" 2>/dev/null || true)" ;;
  *pipelines*)
    # GitLab: bare array, filtered server-side by ?sha=…; emulate the filter.
    body="$(cat "$(runs_file)")"
    case "$url" in *sha=*)
      q="${url##*sha=}"; q="${q%%&*}"
      body="$(printf '%s' "$body" | jq -c --arg s "$q" 'map(select(.sha==$s))')"
    esac ;;
  *actions/*)
    body="$(cat "$(runs_file)")"
    # GitHub and Forgejo filter runs server-side via ?head_sha=…; emulate that
    # so an unmatched SHA yields an empty list. GitHub run objects carry
    # head_sha, Forgejo /actions/runs objects carry commit_sha — match either.
    case "$url" in *head_sha=*)
      q="${url##*head_sha=}"; q="${q%%&*}"
      body="$(printf '%s' "$body" | jq -c --arg s "$q" '.workflow_runs |= map(select((.head_sha // .commit_sha)==$s))')"
    esac ;;
  *) body='{}' ;;
esac
if [ -n "$outfile" ]; then printf '%s' "$body" >"$outfile"; else printf '%s' "$body"; fi
[ "$want_code" = 1 ] && printf '200'
exit 0
EOF
chmod +x "$FAKE_DIR/curl"

RESP="$SANDBOX/resp"; mkdir -p "$RESP"
export FAKE_RESP="$RESP"
# Adapters require these; values are irrelevant since curl is stubbed.
export LS_API="http://fake" LS_OWNER="o" LS_REPO="r" LS_TOKEN="t"
export LS_CI_POLL_SECONDS=1          # keep the loop snappy under test

# run_watch <backend> <timeout-secs> -- <extra args…>  → prints "<rc>\n<output>"
# $QTMO bounds the queue allowance (#171); it defaults to the execution timeout
# so a case that says nothing about queueing is bounded exactly as it was before
# the two clocks existed, and never waits out the hour-long production default.
run_watch() {
	local backend="$1" tmo="$2"; shift 2
	PATH="$FAKE_DIR:$PATH" LS_CI_WATCH_TIMEOUT="$tmo" LS_CI_QUEUE_TIMEOUT="${QTMO:-$tmo}" \
		SWITCH_AFTER="${SWITCH_AFTER:-0}" \
		bash "$REPO_ROOT/flight/scripts/adapters/$backend/ci" watch "$@" 2>&1
}

REMOTE_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"   # what CI actually ran on
LOCAL_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"     # unpushed local tip

# GitHub/Forgejo read .head.sha; GitLab MRs expose .sha — provide both.
printf '{"head":{"sha":"%s"},"sha":"%s"}\n' "$REMOTE_SHA" "$REMOTE_SHA" >"$RESP/pr.json"

# run_obj <backend> <kind> <id> <sha> [<ident>] [<event>] — a single run/pipeline
# JSON object. kind: ok (finished success) | fail (finished failure) | run (still
# running). <ident> is the dedupe identity (workflow file / pipeline source, #43);
# it defaults to a per-id unique value so unrelated runs never collapse. <event>
# is the trigger event (forgejo/github; default push) — gitlab expresses the
# trigger through <ident> (its pipeline `source`).
run_obj() {
	local ident="${5:-wf-$3}" ev="${6:-push}"
	case "$1:$2" in
		forgejo:ok)   printf '{"id":%s,"commit_sha":"%s","status":"success","workflow_id":"%s","trigger_event":"%s"}'   "$3" "$4" "$ident" "$ev" ;;
		forgejo:fail) printf '{"id":%s,"commit_sha":"%s","status":"failure","workflow_id":"%s","trigger_event":"%s"}'   "$3" "$4" "$ident" "$ev" ;;
		forgejo:run)  printf '{"id":%s,"commit_sha":"%s","status":"running","workflow_id":"%s","trigger_event":"%s"}'   "$3" "$4" "$ident" "$ev" ;;
		forgejo:wait) printf '{"id":%s,"commit_sha":"%s","status":"waiting","workflow_id":"%s","trigger_event":"%s"}'   "$3" "$4" "$ident" "$ev" ;;
		github:ok)    printf '{"id":%s,"head_sha":"%s","status":"completed","conclusion":"success","workflow_id":"%s","event":"%s"}'    "$3" "$4" "$ident" "$ev" ;;
		github:fail)  printf '{"id":%s,"head_sha":"%s","status":"completed","conclusion":"failure","workflow_id":"%s","event":"%s"}'    "$3" "$4" "$ident" "$ev" ;;
		github:run)   printf '{"id":%s,"head_sha":"%s","status":"in_progress","conclusion":null,"workflow_id":"%s","event":"%s"}'       "$3" "$4" "$ident" "$ev" ;;
		gitlab:ok)    printf '{"id":%s,"sha":"%s","status":"success","source":"%s"}'   "$3" "$4" "$ident" ;;
		gitlab:fail)  printf '{"id":%s,"sha":"%s","status":"failed","source":"%s"}'    "$3" "$4" "$ident" ;;
		gitlab:run)   printf '{"id":%s,"sha":"%s","status":"running","source":"%s"}'   "$3" "$4" "$ident" ;;
	esac
}
# set_runs <backend> <obj> [<obj> …] — write runs.json in the backend's native shape:
# GitLab returns a bare pipelines array; GitHub/Forgejo wrap runs in {workflow_runs:[…]}.
set_runs() {
	local backend="$1"; shift
	local joined; joined="$(IFS=,; echo "$*")"
	case "$backend" in
		gitlab) printf '[%s]\n' "$joined" >"$RESP/runs.json" ;;
		*)      printf '{"workflow_runs":[%s]}\n' "$joined" >"$RESP/runs.json" ;;
	esac
}

for backend in forgejo github gitlab; do
	printf '\033[1m── %s ──\033[0m\n' "$backend"

	# A finished, successful run exists ONLY for the pushed (remote) SHA.
	set_runs "$backend" "$(run_obj "$backend" ok 42 "$REMOTE_SHA")"

	# 1. --pr resolves the PR head SHA and sees the finished run → success, exit 0.
	out="$(run_watch "$backend" 10 --pr 7)"; rc=$?
	check "$backend: --pr watches the resolved run and exits 0 (success)" \
		"$([ "$rc" = 0 ] && grep -q "status=success" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"

	# 2. --pr wins over a bogus (unpushed) --sha rather than hanging on it.
	out="$(run_watch "$backend" 10 --sha "$LOCAL_SHA" --pr 7)"; rc=$?
	check "$backend: --pr overrides an unpushed --sha" \
		"$([ "$rc" = 0 ] && grep -q "status=success" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"

	# 3. Back-compat: an explicit --sha that DOES have a run still works.
	out="$(run_watch "$backend" 10 --sha "$REMOTE_SHA")"; rc=$?
	check "$backend: bare --sha still exits 0 when a run exists" \
		"$([ "$rc" = 0 ] && echo 1 || echo 0)" "rc=$rc out=$out"

	# 4. Aggregate: many runs, all succeed → one success verdict, exit 0.
	set_runs "$backend" "$(run_obj "$backend" ok 42 "$REMOTE_SHA")" "$(run_obj "$backend" ok 43 "$REMOTE_SHA")"
	out="$(run_watch "$backend" 10 --sha "$REMOTE_SHA")"; rc=$?
	check "$backend: all-success across multiple runs → status=success" \
		"$([ "$rc" = 0 ] && grep -q "runs=2 pending=0 failed=0 status=success" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"

	# 5. Aggregate: any run fails → status=failure (even if others passed).
	set_runs "$backend" "$(run_obj "$backend" ok 42 "$REMOTE_SHA")" "$(run_obj "$backend" fail 43 "$REMOTE_SHA")"
	out="$(run_watch "$backend" 10 --sha "$REMOTE_SHA")"; rc=$?
	check "$backend: any failed run → status=failure" \
		"$([ "$rc" = 0 ] && grep -q "failed=1 status=failure" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"

	# 6. Aggregate: does NOT early-exit while a sibling run is still pending.
	#    One finished + one running → must keep watching → hits the timeout.
	set_runs "$backend" "$(run_obj "$backend" ok 42 "$REMOTE_SHA")" "$(run_obj "$backend" run 43 "$REMOTE_SHA")"
	before="$(date +%s)"
	out="$(run_watch "$backend" 2 --sha "$REMOTE_SHA")"; rc=$?
	elapsed=$(( $(date +%s) - before ))
	check "$backend: waits for a still-pending sibling run (no early exit)" \
		"$([ "$rc" != 0 ] && [ "$elapsed" -ge 2 ] && [ "$elapsed" -lt 8 ] && echo 1 || echo 0)" "rc=$rc elapsed=${elapsed}s out=$out"

	# 7. Hang guard: watching an unpushed SHA (no matching run) times out non-zero.
	set_runs "$backend" "$(run_obj "$backend" ok 42 "$REMOTE_SHA")"   # run exists, but for a DIFFERENT sha
	before="$(date +%s)"
	out="$(run_watch "$backend" 2 --sha "$LOCAL_SHA")"; rc=$?
	elapsed=$(( $(date +%s) - before ))
	check "$backend: no-run watch times out non-zero (not forever)" \
		"$([ "$rc" != 0 ] && [ "$elapsed" -lt 8 ] && echo 1 || echo 0)" "rc=$rc elapsed=${elapsed}s"
	check "$backend: timeout message names the missing run / push hint" \
		"$(grep -q "no CI run found" <<<"$out" && echo 1 || echo 0)" "out=$out"

	# 8. Neither --sha nor --pr → clear error, no hang.
	out="$(run_watch "$backend" 10)"; rc=$?
	check "$backend: errors when neither --sha nor --pr given" \
		"$([ "$rc" != 0 ] && grep -q "sha or --pr" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"
done

# 9. Forgejo blind spot (#53): a run still in `waiting` state has no task yet, so
#    the old /actions/tasks poll saw nothing and reported "no CI run found". The
#    /actions/runs endpoint lists it immediately — the watcher must report it as
#    pending, not missing. (Times out non-zero since the run never completes.)
printf '\033[1m── forgejo: waiting runs (#53) ──\033[0m\n'
set_runs forgejo "$(run_obj forgejo wait 44 "$REMOTE_SHA")"
out="$(run_watch forgejo 2 --sha "$REMOTE_SHA")"; rc=$?
check "forgejo: a waiting run is seen as pending, not 'no CI run found'" \
	"$(grep -q "pending=1 failed=0 status=pending" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"
check "forgejo: waiting-run timeout message is not the missing-run one" \
	"$(grep -q "no CI run found" <<<"$out" && echo 0 || echo 1)" "out=$out"
# …and with the two clocks (#171) it is specifically the QUEUE message: a run
# that never leaves `waiting` never executed, so --timeout was never the cap.
check "forgejo: a never-started run fails on the queue allowance, not --timeout" \
	"$(grep -q "never started executing" <<<"$out" && echo 1 || echo 0)" "out=$out"

# 10. A short SHA prefix must still match: ?head_sha= is an exact server-side
#     filter, so the adapter may only send it for a full 40-char SHA and must
#     fall back to the client-side startswith match otherwise.
set_runs forgejo "$(run_obj forgejo ok 45 "$REMOTE_SHA")"
out="$(run_watch forgejo 10 --sha "${REMOTE_SHA:0:12}")"; rc=$?
check "forgejo: short --sha prefix still finds the run" \
	"$([ "$rc" = 0 ] && grep -q "status=success" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"

# 11. Superseded runs (#43): a failed attempt replaced by a newer run of the
#     SAME identity (workflow/trigger — GitLab: pipeline source) must not
#     poison the verdict; only the latest attempt per group counts. Mirrors
#     how the providers' own UIs show a re-run job as green.
printf '\033[1m── superseded runs (#43) ──\033[0m\n'
for backend in forgejo github gitlab; do
	set_runs "$backend" "$(run_obj "$backend" fail 42 "$REMOTE_SHA" lint.yml)" "$(run_obj "$backend" ok 43 "$REMOTE_SHA" lint.yml)"
	out="$(run_watch "$backend" 10 --sha "$REMOTE_SHA")"; rc=$?
	check "$backend: superseded failed run is ignored (latest attempt wins)" \
		"$([ "$rc" = 0 ] && grep -q "runs=1 pending=0 failed=0 status=success" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"

	set_runs "$backend" "$(run_obj "$backend" ok 43 "$REMOTE_SHA" lint.yml)" "$(run_obj "$backend" fail 42 "$REMOTE_SHA" lint.yml)"
	out="$(run_watch "$backend" 10 --sha "$REMOTE_SHA")"; rc=$?
	check "$backend: dedupe is list-order independent" \
		"$([ "$rc" = 0 ] && grep -q "runs=1 pending=0 failed=0 status=success" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"

	set_runs "$backend" "$(run_obj "$backend" ok 42 "$REMOTE_SHA" lint.yml)" "$(run_obj "$backend" fail 43 "$REMOTE_SHA" lint.yml)"
	out="$(run_watch "$backend" 10 --sha "$REMOTE_SHA")"; rc=$?
	check "$backend: latest attempt failed → still failure" \
		"$([ "$rc" = 0 ] && grep -q "failed=1 status=failure" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"

	# Distinct identities must NOT collapse: a failed lint.yml is not superseded
	# by a green tests.yml.
	set_runs "$backend" "$(run_obj "$backend" fail 42 "$REMOTE_SHA" lint.yml)" "$(run_obj "$backend" ok 43 "$REMOTE_SHA" tests.yml)"
	out="$(run_watch "$backend" 10 --sha "$REMOTE_SHA")"; rc=$?
	check "$backend: different workflows never dedupe" \
		"$([ "$rc" = 0 ] && grep -q "runs=2 pending=0 failed=1 status=failure" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"

	# A manual re-dispatch supersedes the workflow's earlier runs across trigger
	# events (a human explicitly re-ran it): flaked push run + newer green
	# workflow_dispatch (gitlab: `web` pipeline) → green verdict.
	if [ "$backend" = gitlab ]; then
		set_runs gitlab "$(run_obj gitlab fail 42 "$REMOTE_SHA" push)" "$(run_obj gitlab ok 43 "$REMOTE_SHA" web)"
	else
		set_runs "$backend" "$(run_obj "$backend" fail 42 "$REMOTE_SHA" lint.yml push)" "$(run_obj "$backend" ok 43 "$REMOTE_SHA" lint.yml workflow_dispatch)"
	fi
	out="$(run_watch "$backend" 10 --sha "$REMOTE_SHA")"; rc=$?
	check "$backend: manual re-dispatch supersedes the flaked push run" \
		"$([ "$rc" = 0 ] && grep -q "runs=1 pending=0 failed=0 status=success" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"

	# …but only for the SAME workflow: a green dispatch of tests.yml does not
	# absolve a failed push run of lint.yml. (GitLab has no workflow dimension —
	# a newer web pipeline covers the whole sha — so this guard is forgejo/github.)
	if [ "$backend" != gitlab ]; then
		set_runs "$backend" "$(run_obj "$backend" fail 42 "$REMOTE_SHA" lint.yml push)" "$(run_obj "$backend" ok 43 "$REMOTE_SHA" tests.yml workflow_dispatch)"
		out="$(run_watch "$backend" 10 --sha "$REMOTE_SHA")"; rc=$?
		check "$backend: a dispatch of another workflow doesn't absolve the failure" \
			"$([ "$rc" = 0 ] && grep -q "failed=1 status=failure" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"
	fi
done

# 12. Queued ≠ hung (#171). `--timeout` bounds EXECUTION; time in which every
#     job is waiting for a runner is bounded by the separate `--queue-timeout`.
#     The run-level status cannot tell the two apart — all three backends mark a
#     run `running`/`in_progress` as soon as ANY job starts, so a run with three
#     legs green and the fourth waiting for its runner still reads as running.
#     Every case below therefore reports the run as executing at run level and
#     puts the real answer in the job list, which is exactly the shape that made
#     a healthy 19-minute run die at 900s.
printf '\033[1m── queued vs executing (#171) ──\033[0m\n'

# jobs_json <backend> <kind> — the run's job list. queued: nothing running, one
# leg still waiting for a runner. busy: a leg actually executing.
jobs_json() {
	local waiting running
	case "$1" in
		forgejo) waiting='waiting'; running='running' ;;
		github)  waiting='queued';  running='in_progress' ;;
		gitlab)  waiting='pending'; running='running' ;;
	esac
	case "$1:$2" in
		github:queued) printf '{"jobs":[{"id":1,"status":"completed","conclusion":"success"},{"id":2,"status":"%s"}]}\n' "$waiting" ;;
		github:busy)   printf '{"jobs":[{"id":1,"status":"%s"},{"id":2,"status":"%s"}]}\n' "$running" "$waiting" ;;
		*:queued)      printf '[{"id":1,"status":"success"},{"id":2,"status":"%s"}]\n' "$waiting" ;;
		*:busy)        printf '[{"id":1,"status":"%s"},{"id":2,"status":"%s"}]\n' "$running" "$waiting" ;;
	esac
}
# reset_seq — forget the previous case's call counter and flip snapshot.
reset_seq() { rm -f "$RESP/calls" "$RESP/runs-after.json"; QTMO=""; SWITCH_AFTER=0; }
# set_runs_after <backend> <obj…> — the snapshot served once SWITCH_AFTER list
# calls have been made; same shapes as set_runs.
set_runs_after() {
	set_runs "$@"
	mv "$RESP/runs.json" "$RESP/runs-after.json"
}

for backend in forgejo github gitlab; do
	# (a) Queued past --timeout, then runs and succeeds → exit 0. Without the
	#     job-list check the run reads as executing from the first poll and this
	#     dies at 1s with the execution message.
	reset_seq
	jobs_json "$backend" queued >"$RESP/jobs.json"
	set_runs_after "$backend" "$(run_obj "$backend" ok 50 "$REMOTE_SHA")"
	set_runs "$backend" "$(run_obj "$backend" run 50 "$REMOTE_SHA")"
	before="$(date +%s)"
	SWITCH_AFTER=3; QTMO=20
	out="$(run_watch "$backend" 1 --sha "$REMOTE_SHA")"; rc=$?
	elapsed=$(( $(date +%s) - before ))
	check "$backend: a run queued past --timeout still finishes green" \
		"$([ "$rc" = 0 ] && grep -q "status=success" <<<"$out" && [ "$elapsed" -ge 2 ] && echo 1 || echo 0)" \
		"rc=$rc elapsed=${elapsed}s out=$out"

	# (b) Never leaves the queue → non-zero, and the message says so and names
	#     the key to raise rather than blaming the execution timeout.
	reset_seq
	set_runs "$backend" "$(run_obj "$backend" run 51 "$REMOTE_SHA")"
	jobs_json "$backend" queued >"$RESP/jobs.json"
	before="$(date +%s)"
	QTMO=2
	out="$(run_watch "$backend" 1 --sha "$REMOTE_SHA")"; rc=$?
	elapsed=$(( $(date +%s) - before ))
	check "$backend: a run that never starts fails on the queue allowance" \
		"$([ "$rc" != 0 ] && grep -q "never started executing" <<<"$out" && [ "$elapsed" -lt 15 ] && echo 1 || echo 0)" \
		"rc=$rc elapsed=${elapsed}s out=$out"
	check "$backend: the queue message names code.ciQueueTimeout" \
		"$(grep -q "ciQueueTimeout" <<<"$out" && echo 1 || echo 0)" "out=$out"

	# (c) Genuinely executing past --timeout → non-zero, and the OTHER message.
	#     The queue allowance is set wide here, so only --timeout can have fired.
	reset_seq
	set_runs "$backend" "$(run_obj "$backend" run 52 "$REMOTE_SHA")"
	jobs_json "$backend" busy >"$RESP/jobs.json"
	before="$(date +%s)"
	QTMO=20
	out="$(run_watch "$backend" 1 --sha "$REMOTE_SHA")"; rc=$?
	elapsed=$(( $(date +%s) - before ))
	check "$backend: a run executing past --timeout fails on the execution cap" \
		"$([ "$rc" != 0 ] && grep -q "of execution" <<<"$out" && [ "$elapsed" -lt 15 ] && echo 1 || echo 0)" \
		"rc=$rc elapsed=${elapsed}s out=$out"
	check "$backend: the execution message names code.ciWatchTimeout" \
		"$(grep -q "ciWatchTimeout" <<<"$out" && echo 1 || echo 0)" "out=$out"

	# (d) --queue-timeout is a flag too, and 0 disables that cap (as --timeout 0
	#     disables the other): the queued run then runs on until --timeout can't
	#     fire either… so bound it with --timeout on a BUSY run to keep it quick.
	reset_seq
	jobs_json "$backend" queued >"$RESP/jobs.json"
	before="$(date +%s)"
	QTMO=900
	out="$(run_watch "$backend" 1 --sha "$REMOTE_SHA" --queue-timeout 2)"; rc=$?
	elapsed=$(( $(date +%s) - before ))
	check "$backend: --queue-timeout overrides the env/config value" \
		"$([ "$rc" != 0 ] && grep -q "never started executing" <<<"$out" && [ "$elapsed" -lt 15 ] && echo 1 || echo 0)" \
		"rc=$rc elapsed=${elapsed}s out=$out"
done
reset_seq
rm -f "$RESP/jobs.json"

# Summary: plain when nothing failed, red when something did (#123).
[ "$fail" -gt 0 ] && summary_colour=$'\033[0;31m' || summary_colour=''
printf '\n%sPassed: %d  Failed: %d\033[0m\n' "$summary_colour" "$pass" "$fail"
[ "$fail" -eq 0 ]
