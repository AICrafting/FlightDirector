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
  *pipelines*)
    # GitLab: bare array, filtered server-side by ?sha=…; emulate the filter.
    body="$(cat "$FAKE_RESP/runs.json")"
    case "$url" in *sha=*)
      q="${url##*sha=}"; q="${q%%&*}"
      body="$(printf '%s' "$body" | jq -c --arg s "$q" 'map(select(.sha==$s))')"
    esac ;;
  *actions/*)
    body="$(cat "$FAKE_RESP/runs.json")"
    # GitHub filters runs server-side via ?head_sha=…; emulate that so an
    # unmatched SHA yields an empty list (Forgejo filters client-side in jq).
    case "$url" in *head_sha=*)
      q="${url##*head_sha=}"; q="${q%%&*}"
      body="$(printf '%s' "$body" | jq -c --arg s "$q" '.workflow_runs |= map(select(.head_sha==$s))')"
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
run_watch() {
	local backend="$1" tmo="$2"; shift 2
	PATH="$FAKE_DIR:$PATH" LS_CI_WATCH_TIMEOUT="$tmo" \
		bash "$REPO_ROOT/lightspeed/scripts/adapters/$backend/ci" watch "$@" 2>&1
}

REMOTE_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"   # what CI actually ran on
LOCAL_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"     # unpushed local tip

# GitHub/Forgejo read .head.sha; GitLab MRs expose .sha — provide both.
printf '{"head":{"sha":"%s"},"sha":"%s"}\n' "$REMOTE_SHA" "$REMOTE_SHA" >"$RESP/pr.json"

# run_obj <backend> <kind> <id> <sha> — a single run/pipeline JSON object.
# kind: ok (finished success) | fail (finished failure) | run (still running).
run_obj() {
	case "$1:$2" in
		forgejo:ok)   printf '{"id":%s,"head_sha":"%s","status":"success"}'   "$3" "$4" ;;
		forgejo:fail) printf '{"id":%s,"head_sha":"%s","status":"failure"}'   "$3" "$4" ;;
		forgejo:run)  printf '{"id":%s,"head_sha":"%s","status":"running"}'   "$3" "$4" ;;
		github:ok)    printf '{"id":%s,"head_sha":"%s","status":"completed","conclusion":"success"}'    "$3" "$4" ;;
		github:fail)  printf '{"id":%s,"head_sha":"%s","status":"completed","conclusion":"failure"}'    "$3" "$4" ;;
		github:run)   printf '{"id":%s,"head_sha":"%s","status":"in_progress","conclusion":null}'       "$3" "$4" ;;
		gitlab:ok)    printf '{"id":%s,"sha":"%s","status":"success"}'   "$3" "$4" ;;
		gitlab:fail)  printf '{"id":%s,"sha":"%s","status":"failed"}'    "$3" "$4" ;;
		gitlab:run)   printf '{"id":%s,"sha":"%s","status":"running"}'   "$3" "$4" ;;
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

printf '\033[1m────────────────────────────\033[0m\n'
printf 'Passed: %d  Failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
