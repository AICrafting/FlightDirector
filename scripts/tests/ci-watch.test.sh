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
  */pulls/*|*/merge_requests/*)
    # PR_SWITCH=1 + pr-after.json: the first read sees pr.json, every later one
    # pr-after.json — a head that moved during the watch (FJ-281).
    body="$(cat "$FAKE_RESP/pr.json")"
    if [ "${PR_SWITCH:-0}" = 1 ] && [ -f "$FAKE_RESP/pr-after.json" ]; then
      if [ -f "$FAKE_RESP/pr-calls" ]; then body="$(cat "$FAKE_RESP/pr-after.json")"; fi
      : >"$FAKE_RESP/pr-calls"
    fi ;;
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

# Which backends this process covers. The file is the slowest in the suite and
# sets the floor for the whole parallel run (#212) — its timeout cases wait on a
# real `date +%s` clock, so they cannot be sped up, only run side by side.
# run-tests.sh therefore invokes this file once per backend; unset (running it by
# hand) still covers all three, exactly as before.
CI_WATCH_BACKENDS="${CI_WATCH_BACKENDS:-forgejo github gitlab}"

# covers <backend> — true when this shard is responsible for <backend>. Needed by
# the blocks below that test ONE backend's quirk outside the per-backend loops.
covers() { case " $CI_WATCH_BACKENDS " in *" $1 "*) return 0 ;; esac; return 1; }

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
# running) | skip (finished, but nothing executed) | cancel (stopped before it
# finished — usually a newer push superseded it). <ident> is the dedupe
# identity (workflow file / pipeline source, #43); it defaults to a per-id
# unique value so unrelated runs never collapse. <event>
# is the trigger event (forgejo/github; default push) — gitlab expresses the
# trigger through <ident> (its pipeline `source`).
run_obj() {
	local ident="${5:-wf-$3}" ev="${6:-push}"
	case "$1:$2" in
		forgejo:ok)   printf '{"id":%s,"commit_sha":"%s","status":"success","workflow_id":"%s","trigger_event":"%s"}'   "$3" "$4" "$ident" "$ev" ;;
		forgejo:fail) printf '{"id":%s,"commit_sha":"%s","status":"failure","workflow_id":"%s","trigger_event":"%s"}'   "$3" "$4" "$ident" "$ev" ;;
		forgejo:run)  printf '{"id":%s,"commit_sha":"%s","status":"running","workflow_id":"%s","trigger_event":"%s"}'   "$3" "$4" "$ident" "$ev" ;;
		forgejo:skip) printf '{"id":%s,"commit_sha":"%s","status":"skipped","workflow_id":"%s","trigger_event":"%s"}'   "$3" "$4" "$ident" "$ev" ;;
		forgejo:wait) printf '{"id":%s,"commit_sha":"%s","status":"waiting","workflow_id":"%s","trigger_event":"%s"}'   "$3" "$4" "$ident" "$ev" ;;
		github:ok)    printf '{"id":%s,"head_sha":"%s","status":"completed","conclusion":"success","workflow_id":"%s","event":"%s"}'    "$3" "$4" "$ident" "$ev" ;;
		github:fail)  printf '{"id":%s,"head_sha":"%s","status":"completed","conclusion":"failure","workflow_id":"%s","event":"%s"}'    "$3" "$4" "$ident" "$ev" ;;
		github:run)   printf '{"id":%s,"head_sha":"%s","status":"in_progress","conclusion":null,"workflow_id":"%s","event":"%s"}'       "$3" "$4" "$ident" "$ev" ;;
		github:skip)  printf '{"id":%s,"head_sha":"%s","status":"completed","conclusion":"skipped","workflow_id":"%s","event":"%s"}'    "$3" "$4" "$ident" "$ev" ;;
		gitlab:ok)    printf '{"id":%s,"sha":"%s","status":"success","source":"%s"}'   "$3" "$4" "$ident" ;;
		gitlab:fail)  printf '{"id":%s,"sha":"%s","status":"failed","source":"%s"}'    "$3" "$4" "$ident" ;;
		gitlab:run)   printf '{"id":%s,"sha":"%s","status":"running","source":"%s"}'   "$3" "$4" "$ident" ;;
		gitlab:skip)  printf '{"id":%s,"sha":"%s","status":"skipped","source":"%s"}'   "$3" "$4" "$ident" ;;
		forgejo:cancel) printf '{"id":%s,"commit_sha":"%s","status":"cancelled","workflow_id":"%s","trigger_event":"%s"}' "$3" "$4" "$ident" "$ev" ;;
		github:cancel)  printf '{"id":%s,"head_sha":"%s","status":"completed","conclusion":"cancelled","workflow_id":"%s","event":"%s"}' "$3" "$4" "$ident" "$ev" ;;
		gitlab:cancel)  printf '{"id":%s,"sha":"%s","status":"canceled","source":"%s"}' "$3" "$4" "$ident" ;;
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

for backend in $CI_WATCH_BACKENDS; do
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
		"$([ "$rc" = 0 ] && grep -q "runs=2 pending=0 failed=0 skipped=0 cancelled=0 status=success" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"

	# 5. Aggregate: any run fails → status=failure (even if others passed).
	set_runs "$backend" "$(run_obj "$backend" ok 42 "$REMOTE_SHA")" "$(run_obj "$backend" fail 43 "$REMOTE_SHA")"
	out="$(run_watch "$backend" 10 --sha "$REMOTE_SHA")"; rc=$?
	check "$backend: any failed run → status=failure" \
		"$([ "$rc" = 0 ] && grep -q "failed=1 skipped=0 cancelled=0 status=failure" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"

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

if covers forgejo; then
	# 9. Forgejo blind spot (#53): a run still in `waiting` state has no task yet, so
	#    the old /actions/tasks poll saw nothing and reported "no CI run found". The
	#    /actions/runs endpoint lists it immediately — the watcher must report it as
	#    pending, not missing. (Times out non-zero since the run never completes.)
	printf '\033[1m── forgejo: waiting runs (#53) ──\033[0m\n'
	set_runs forgejo "$(run_obj forgejo wait 44 "$REMOTE_SHA")"
	out="$(run_watch forgejo 2 --sha "$REMOTE_SHA")"; rc=$?
	check "forgejo: a waiting run is seen as pending, not 'no CI run found'" \
		"$(grep -q "pending=1 failed=0 skipped=0 cancelled=0 status=pending" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"
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
fi

# 11. Superseded runs (#43): a failed attempt replaced by a newer run of the
#     SAME identity (workflow/trigger — GitLab: pipeline source) must not
#     poison the verdict; only the latest attempt per group counts. Mirrors
#     how the providers' own UIs show a re-run job as green.
printf '\033[1m── superseded runs (#43) ──\033[0m\n'
for backend in $CI_WATCH_BACKENDS; do
	set_runs "$backend" "$(run_obj "$backend" fail 42 "$REMOTE_SHA" lint.yml)" "$(run_obj "$backend" ok 43 "$REMOTE_SHA" lint.yml)"
	out="$(run_watch "$backend" 10 --sha "$REMOTE_SHA")"; rc=$?
	check "$backend: superseded failed run is ignored (latest attempt wins)" \
		"$([ "$rc" = 0 ] && grep -q "runs=1 pending=0 failed=0 skipped=0 cancelled=0 status=success" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"

	set_runs "$backend" "$(run_obj "$backend" ok 43 "$REMOTE_SHA" lint.yml)" "$(run_obj "$backend" fail 42 "$REMOTE_SHA" lint.yml)"
	out="$(run_watch "$backend" 10 --sha "$REMOTE_SHA")"; rc=$?
	check "$backend: dedupe is list-order independent" \
		"$([ "$rc" = 0 ] && grep -q "runs=1 pending=0 failed=0 skipped=0 cancelled=0 status=success" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"

	set_runs "$backend" "$(run_obj "$backend" ok 42 "$REMOTE_SHA" lint.yml)" "$(run_obj "$backend" fail 43 "$REMOTE_SHA" lint.yml)"
	out="$(run_watch "$backend" 10 --sha "$REMOTE_SHA")"; rc=$?
	check "$backend: latest attempt failed → still failure" \
		"$([ "$rc" = 0 ] && grep -q "failed=1 skipped=0 cancelled=0 status=failure" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"

	# Distinct identities must NOT collapse: a failed lint.yml is not superseded
	# by a green tests.yml.
	set_runs "$backend" "$(run_obj "$backend" fail 42 "$REMOTE_SHA" lint.yml)" "$(run_obj "$backend" ok 43 "$REMOTE_SHA" tests.yml)"
	out="$(run_watch "$backend" 10 --sha "$REMOTE_SHA")"; rc=$?
	check "$backend: different workflows never dedupe" \
		"$([ "$rc" = 0 ] && grep -q "runs=2 pending=0 failed=1 skipped=0 cancelled=0 status=failure" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"

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
		"$([ "$rc" = 0 ] && grep -q "runs=1 pending=0 failed=0 skipped=0 cancelled=0 status=success" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"

	# …but only for the SAME workflow: a green dispatch of tests.yml does not
	# absolve a failed push run of lint.yml. (GitLab has no workflow dimension —
	# a newer web pipeline covers the whole sha — so this guard is forgejo/github.)
	if [ "$backend" != gitlab ]; then
		set_runs "$backend" "$(run_obj "$backend" fail 42 "$REMOTE_SHA" lint.yml push)" "$(run_obj "$backend" ok 43 "$REMOTE_SHA" tests.yml workflow_dispatch)"
		out="$(run_watch "$backend" 10 --sha "$REMOTE_SHA")"; rc=$?
		check "$backend: a dispatch of another workflow doesn't absolve the failure" \
			"$([ "$rc" = 0 ] && grep -q "failed=1 skipped=0 cancelled=0 status=failure" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"
	fi
done

# 12. Skipped runs (#150): `skipped` used to be folded into the success side, so a
#     run where NOTHING executed (a path filter that matched nothing, a `needs:`
#     whose dependency was skipped, a false conditional) reported green and sailed
#     through the merge gate. Skipped is now counted on its own axis: all-skipped
#     is its own verdict, a partial skip still passes but says how many.
printf '\033[1m── skipped runs (#150) ──\033[0m\n'
for backend in $CI_WATCH_BACKENDS; do
	# Every run skipped → NOT a pass; its own status so the human sees nothing ran.
	set_runs "$backend" "$(run_obj "$backend" skip 42 "$REMOTE_SHA" lint.yml)"
	out="$(run_watch "$backend" 10 --sha "$REMOTE_SHA")"; rc=$?
	check "$backend: an all-skipped run reports status=skipped, not success" \
		"$([ "$rc" = 0 ] && grep -q "runs=1 pending=0 failed=0 skipped=1 cancelled=0 status=skipped" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"
	check "$backend: an all-skipped run never claims success" \
		"$(grep -q "status=success" <<<"$out" && echo 0 || echo 1)" "out=$out"

	# Skipped across several runs still lands on the skipped verdict.
	set_runs "$backend" "$(run_obj "$backend" skip 42 "$REMOTE_SHA" lint.yml)" "$(run_obj "$backend" skip 43 "$REMOTE_SHA" tests.yml)"
	out="$(run_watch "$backend" 10 --sha "$REMOTE_SHA")"; rc=$?
	check "$backend: every run skipped → status=skipped" \
		"$([ "$rc" = 0 ] && grep -q "runs=2 pending=0 failed=0 skipped=2 cancelled=0 status=skipped" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"

	# Some ran, some skipped → still a pass, but the count is on the line.
	set_runs "$backend" "$(run_obj "$backend" ok 42 "$REMOTE_SHA" lint.yml)" "$(run_obj "$backend" skip 43 "$REMOTE_SHA" tests.yml)"
	out="$(run_watch "$backend" 10 --sha "$REMOTE_SHA")"; rc=$?
	check "$backend: a partial skip still passes and names the skip count" \
		"$([ "$rc" = 0 ] && grep -q "runs=2 pending=0 failed=0 skipped=1 cancelled=0 status=success" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"

	# A skip never launders a failure.
	set_runs "$backend" "$(run_obj "$backend" skip 42 "$REMOTE_SHA" lint.yml)" "$(run_obj "$backend" fail 43 "$REMOTE_SHA" tests.yml)"
	out="$(run_watch "$backend" 10 --sha "$REMOTE_SHA")"; rc=$?
	check "$backend: a skipped sibling doesn't hide a failure" \
		"$([ "$rc" = 0 ] && grep -q "runs=2 pending=0 failed=1 skipped=1 cancelled=0 status=failure" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"

	# Skipped is terminal, so a still-running sibling must keep the watch open.
	set_runs "$backend" "$(run_obj "$backend" skip 42 "$REMOTE_SHA" lint.yml)" "$(run_obj "$backend" run 43 "$REMOTE_SHA" tests.yml)"
	before="$(date +%s)"
	out="$(run_watch "$backend" 2 --sha "$REMOTE_SHA")"; rc=$?
	elapsed=$(( $(date +%s) - before ))
	check "$backend: a skipped run doesn't cut short a pending sibling" \
		"$([ "$rc" != 0 ] && [ "$elapsed" -ge 2 ] && [ "$elapsed" -lt 8 ] && echo 1 || echo 0)" "rc=$rc elapsed=${elapsed}s out=$out"

	# The status file the gate reads must carry the skipped verdict too.
	set_runs "$backend" "$(run_obj "$backend" skip 42 "$REMOTE_SHA" lint.yml)"
	sf="$SANDBOX/status-$backend.json"; rm -f "$sf"
	out="$(run_watch "$backend" 10 --sha "$REMOTE_SHA" --status-file "$sf")"; rc=$?
	check "$backend: --status-file records skipped, not success" \
		"$([ "$rc" = 0 ] && [ "$(jq -r .status "$sf" 2>/dev/null)" = skipped ] && echo 1 || echo 0)" "rc=$rc file=$(cat "$sf" 2>/dev/null)"
done

# 12b. Cancelled runs (FJ-281): a cancelled run used to count as failed, so a run
#      cut short by a newer push watched as `status=failure` — while `ci log`,
#      which only looks for failed jobs, found nothing. Cancelled is now its own
#      axis and its own verdict: not a pass (it verified nothing), not a failure.
printf '\033[1m── cancelled runs (FJ-281) ──\033[0m\n'
for backend in $CI_WATCH_BACKENDS; do
	set_runs "$backend" "$(run_obj "$backend" cancel 42 "$REMOTE_SHA" tests.yml)"
	out="$(run_watch "$backend" 10 --sha "$REMOTE_SHA")"; rc=$?
	check "$backend: a cancelled run reports status=cancelled, not failure" \
		"$([ "$rc" = 0 ] && grep -q "runs=1 pending=0 failed=0 skipped=0 cancelled=1 status=cancelled" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"

	# A green sibling doesn't turn a cancelled run into a pass: part of CI never finished.
	set_runs "$backend" "$(run_obj "$backend" ok 42 "$REMOTE_SHA" lint.yml)" "$(run_obj "$backend" cancel 43 "$REMOTE_SHA" tests.yml)"
	out="$(run_watch "$backend" 10 --sha "$REMOTE_SHA")"; rc=$?
	check "$backend: success + cancelled → status=cancelled" \
		"$([ "$rc" = 0 ] && grep -q "runs=2 pending=0 failed=0 skipped=0 cancelled=1 status=cancelled" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"

	# A real failure still wins over a cancellation.
	set_runs "$backend" "$(run_obj "$backend" fail 42 "$REMOTE_SHA" lint.yml)" "$(run_obj "$backend" cancel 43 "$REMOTE_SHA" tests.yml)"
	out="$(run_watch "$backend" 10 --sha "$REMOTE_SHA")"; rc=$?
	check "$backend: a cancelled sibling doesn't hide a failure" \
		"$([ "$rc" = 0 ] && grep -q "runs=2 pending=0 failed=1 skipped=0 cancelled=1 status=failure" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"

	# Cancelled beats all-skipped: something was meant to run and didn't finish.
	set_runs "$backend" "$(run_obj "$backend" skip 42 "$REMOTE_SHA" lint.yml)" "$(run_obj "$backend" cancel 43 "$REMOTE_SHA" tests.yml)"
	out="$(run_watch "$backend" 10 --sha "$REMOTE_SHA")"; rc=$?
	check "$backend: skipped + cancelled → status=cancelled" \
		"$([ "$rc" = 0 ] && grep -q "skipped=1 cancelled=1 status=cancelled" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"

	set_runs "$backend" "$(run_obj "$backend" cancel 42 "$REMOTE_SHA" tests.yml)"
	sf="$SANDBOX/status-cancel-$backend.json"; rm -f "$sf"
	out="$(run_watch "$backend" 10 --sha "$REMOTE_SHA" --status-file "$sf")"; rc=$?
	check "$backend: --status-file records cancelled" \
		"$([ "$rc" = 0 ] && [ "$(jq -r .status "$sf" 2>/dev/null)" = cancelled ] && echo 1 || echo 0)" "rc=$rc file=$(cat "$sf" 2>/dev/null)"

	# The PR's head moved during the watch: the verdict is for the old commit, and
	# stderr says so. pr.json is read once to resolve the SHA (REMOTE) and again
	# at the end; swap it between the two by pointing the end read at a new head.
	set_runs "$backend" "$(run_obj "$backend" cancel 42 "$REMOTE_SHA" tests.yml)"
	out="$(run_watch "$backend" 10 --pr 7)"; rc=$?
	check "$backend: --pr with an unchanged head prints no head-moved note" \
		"$([ "$rc" = 0 ] && ! grep -q "moved to" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"
	printf '{"head":{"sha":"%s"},"sha":"%s"}\n' "$LOCAL_SHA" "$LOCAL_SHA" >"$RESP/pr-after.json"
	out="$(PR_SWITCH=1 run_watch "$backend" 10 --pr 7)"; rc=$?
	rm -f "$RESP/pr-after.json" "$RESP/pr-calls"
	check "$backend: --pr whose head moved names the new head on stderr" \
		"$([ "$rc" = 0 ] && grep -q "status=cancelled" <<<"$out" && grep -q "moved to ${LOCAL_SHA:0:12}" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"
done
if covers gitlab; then
	# GitLab's `canceling` is on its way to `canceled`, so the watch keeps waiting.
	set_runs gitlab '{"id":42,"sha":"'"$REMOTE_SHA"'","status":"canceling","source":"push"}'
	out="$(run_watch gitlab 2 --sha "$REMOTE_SHA")"; rc=$?
	check "gitlab: a canceling pipeline is still pending" \
		"$([ "$rc" != 0 ] && grep -q "pending=1 failed=0 skipped=0 cancelled=0 status=pending" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"
fi

# 13. Queued ≠ hung (#171). `--timeout` bounds EXECUTION; time in which every
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

for backend in $CI_WATCH_BACKENDS; do
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
