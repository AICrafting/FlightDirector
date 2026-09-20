#!/usr/bin/env bash
# Unit tests for the `ci log` adapter verb — mostly Forgejo: the Forgejo 16
# /actions/runs + /actions/runs/{id}/jobs + /actions/jobs/{id}/logs flow
# (issue #54) — plus the #138 shapes on all three code backends: PR-event runs
# that a branch-ref lookup cannot see, and several runs on one commit. The network
# is stubbed with a fake `curl` on PATH, same pattern as ci-watch.test.sh — no
# live backend needed.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

pass=0; fail=0
check() { if [ "$2" = 1 ]; then printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass+1));
			else printf '\033[0;31m  ✗ %s\033[0m  %s\n' "$1" "${3:-}"; fail=$((fail+1)); fi; }

SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT

# --- fake curl: serves the runs list (with server-side head_sha / status
# filters emulated), a run's job list, and per-job plaintext logs.
# Honors `-o FILE` + `-w` (used by _api) as well as plain stdout.
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
  */actions/jobs/*/logs*)
    jid="${url##*/actions/jobs/}"; jid="${jid%%/*}"
    body="FAKE-LOG job=${jid}" ;;
  */actions/runs/*/jobs*)
    rid="${url##*/actions/runs/}"; rid="${rid%%/*}"
    if [ -f "$FAKE_RESP/jobs-${rid}.json" ]; then body="$(cat "$FAKE_RESP/jobs-${rid}.json")"
    else body="$(cat "$FAKE_RESP/jobs.json")"; fi ;;
  */pulls/*)
    body="$(cat "$FAKE_RESP/pull.json" 2>/dev/null || echo '{}')" ;;
  */branches/*)
    body="$(cat "$FAKE_RESP/branch.json" 2>/dev/null || echo '{}')" ;;
  */actions/runs\?*)
    body="$(cat "$FAKE_RESP/runs.json")"
    case "$url" in *head_sha=*)
      q="${url##*head_sha=}"; q="${q%%&*}"
      body="$(printf '%s' "$body" | jq -c --arg s "$q" '.workflow_runs |= map(select(.commit_sha==$s))')"
    esac
    case "$url" in *ref=*)	# fixtures without a `ref` predate the filter: treat them as matching
      q="${url##*ref=}"; q="${q%%&*}"
      body="$(printf '%s' "$body" | jq -c --arg s "$q" '.workflow_runs |= map(select((.ref // $s)==$s))')"
    esac
    case "$url" in *status=*)
      q="${url##*status=}"; q="${q%%&*}"
      body="$(printf '%s' "$body" | jq -c --arg s "$q" '.workflow_runs |= map(select(.status==$s))')"
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

run_log() {
	PATH="$FAKE_DIR:$PATH" bash "$REPO_ROOT/flight/scripts/adapters/forgejo/ci" log "$@" 2>&1
}

SHA_FAIL="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SHA_OK="cccccccccccccccccccccccccccccccccccccccc"

printf '\033[1m── forgejo ci log ──\033[0m\n'

# runs.json: a failed run on SHA_FAIL (branch develop) and a green run on SHA_OK.
cat >"$RESP/runs.json" <<JSON
{"total_count":2,"workflow_runs":[
  {"id":42,"commit_sha":"$SHA_FAIL","status":"failure","prettyref":"develop","html_url":"http://fake/run/42","started":"2026-08-01T10:00:00Z"},
  {"id":43,"commit_sha":"$SHA_OK","status":"success","prettyref":"develop","html_url":"http://fake/run/43","started":"2026-08-01T11:00:00Z"}
]}
JSON
# jobs.json (bare array, Forgejo shape): one failed job, one green.
cat >"$RESP/jobs.json" <<JSON
[
  {"id":101,"name":"script tests","status":"failure","attempt":1,"run_id":42},
  {"id":102,"name":"lint","status":"success","attempt":1,"run_id":42}
]
JSON

# 1. --sha on a failed run → dumps the failed job's log (header + content), exit 0.
out="$(run_log --sha "$SHA_FAIL")"; rc=$?
check "--sha dumps the failed job's log" \
	"$([ "$rc" = 0 ] && grep -q "FAKE-LOG job=101" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"
check "--sha names the failed job in a header" \
	"$(grep -q "job 101" <<<"$out" && grep -q "script tests" <<<"$out" && echo 1 || echo 0)" "out=$out"
check "--sha skips logs of jobs that passed" \
	"$(grep -q "FAKE-LOG job=102" <<<"$out" && echo 0 || echo 1)" "out=$out"

# 1b. Short SHA prefix: ?head_sha= is exact-match server-side, so the adapter
#     must fall back to client-side startswith — and must not silently pick a
#     different run (run 43 is newer but on another commit).
out="$(run_log --sha "${SHA_FAIL:0:12}")"; rc=$?
check "short --sha prefix finds the right run's failed job" \
	"$([ "$rc" = 0 ] && grep -q "FAKE-LOG job=101" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"

# 2. --failed BRANCH → latest failed run for the branch, no local git needed.
out="$(run_log --failed develop)"; rc=$?
check "--failed BRANCH finds the failed run server-side" \
	"$([ "$rc" = 0 ] && grep -q "FAKE-LOG job=101" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"

# 3. Run exists but no failed jobs → friendly note, exit 0.
cat >"$RESP/jobs.json" <<JSON
[{"id":201,"name":"script tests","status":"success","attempt":1,"run_id":43}]
JSON
out="$(run_log --sha "$SHA_OK")"; rc=$?
check "green run → '(no failed jobs …)', exit 0" \
	"$([ "$rc" = 0 ] && grep -qi "no failed jobs" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"

# 4. No run for the SHA → clear non-zero error.
out="$(run_log --sha bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)"; rc=$?
check "unknown SHA → non-zero 'no CI run found'" \
	"$([ "$rc" != 0 ] && grep -q "no CI run found" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"

# 5. Neither --sha nor --failed → usage error.
out="$(run_log)"; rc=$?
check "errors when neither --sha nor --failed given" \
	"$([ "$rc" != 0 ] && grep -q -- "--sha" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"

# --- #138: runs triggered by a pull_request event, and several runs per commit ---
# Two workflows ran on the PR's head commit in the same second: tests (red) and
# lint (green). Both carry the PR ref, not refs/heads/<branch> — and the green one
# sorts last, which is the run the old `sort_by(.started) | last` handed back.
SHA_PR="dddddddddddddddddddddddddddddddddddddddd"
cat >"$RESP/runs.json" <<JSON
{"total_count":2,"workflow_runs":[
  {"id":8264,"commit_sha":"$SHA_PR","status":"failure","ref":"refs/pull/128/head","html_url":"http://fake/run/8264","started":"2026-09-17T10:00:00Z"},
  {"id":8263,"commit_sha":"$SHA_PR","status":"success","ref":"refs/pull/128/head","html_url":"http://fake/run/8263","started":"2026-09-17T10:00:00Z"}
]}
JSON
printf '[{"id":301,"name":"tests","status":"failure","run_id":8264}]' >"$RESP/jobs-8264.json"
printf '[{"id":302,"name":"lint","status":"success","run_id":8263}]' >"$RESP/jobs-8263.json"
printf '{"number":128,"head":{"sha":"%s"}}' "$SHA_PR" >"$RESP/pull.json"
printf '{"name":"feature/127-x","commit":{"id":"%s"}}' "$SHA_PR" >"$RESP/branch.json"

out="$(run_log --sha "$SHA_PR")"; rc=$?
check "--sha with a red and a green run in the same second dumps the red one" \
	"$([ "$rc" = 0 ] && grep -q "FAKE-LOG job=301" <<<"$out" && ! grep -q "no failed jobs" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"
check "…and says which run it is" "$(grep -q "^run 8264: status=failure" <<<"$out" && echo 1 || echo 0)" "out=$out"

out="$(run_log --pr 128)"; rc=$?
check "--pr N resolves the PR's head commit and dumps its failed job" \
	"$([ "$rc" = 0 ] && grep -q "FAKE-LOG job=301" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"

out="$(run_log --failed feature/127-x)"; rc=$?
check "--failed BRANCH falls back to the branch's head commit for PR-event runs" \
	"$([ "$rc" = 0 ] && grep -q "FAKE-LOG job=301" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"

# both workflows red → both dumped, not just one
jq -c '.workflow_runs[1].status="failure"' "$RESP/runs.json" >"$RESP/runs.tmp" && mv "$RESP/runs.tmp" "$RESP/runs.json"
printf '[{"id":302,"name":"lint","status":"failure","run_id":8263}]' >"$RESP/jobs-8263.json"
out="$(run_log --pr 128)"; rc=$?
check "every failed run on the commit is dumped" \
	"$([ "$rc" = 0 ] && grep -q "FAKE-LOG job=301" <<<"$out" && grep -q "FAKE-LOG job=302" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"

# a PR whose head cannot be resolved, and a branch with no runs and no head, are loud
printf '{}' >"$RESP/pull.json"; printf '{}' >"$RESP/branch.json"
out="$(run_log --pr 999)"; rc=$?
check "--pr with no resolvable head → non-zero" "$([ "$rc" != 0 ] && grep -q "could not resolve head sha" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"
out="$(run_log --failed feature/gone)"; rc=$?
check "--failed on a branch with no runs and no head → non-zero 'no CI run found'" \
	"$([ "$rc" != 0 ] && grep -q "no CI run found for feature/gone" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"

# --- #138 on the other code backends: same two shapes, their own API vocabulary ---
# One fake curl for both: GitHub (/actions/runs?head_sha=, .jobs[], conclusion) and
# GitLab (/pipelines?sha=, /pipelines/N/jobs, /repository/branches, merge_requests).
FAKE2="$SANDBOX/bin2"; mkdir -p "$FAKE2"
cat >"$FAKE2/curl" <<'EOF'
#!/usr/bin/env bash
outfile=""; want_code=0; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) outfile="$2"; shift 2 ;;
    -w) want_code=1; shift 2 ;;
    http*|https*) url="$1"; shift ;;
    *) shift ;;
  esac
done
case "$url" in
  */actions/jobs/*/logs*|*/jobs/*/trace*)
    jid="${url%/*}"; jid="${jid##*/}"; body="FAKE-LOG job=${jid}" ;;
  */actions/runs/*/jobs*)
    rid="${url##*/actions/runs/}"; rid="${rid%%/*}"; body="$(cat "$FAKE_RESP/gh-jobs-${rid}.json")" ;;
  */actions/runs\?*)   body="$(cat "$FAKE_RESP/gh-runs.json")" ;;
  */pulls/*)           body="$(cat "$FAKE_RESP/pull.json")" ;;
  */pipelines/*/jobs*)
    pid="${url##*/pipelines/}"; pid="${pid%%/*}"; body="$(cat "$FAKE_RESP/gl-jobs-${pid}.json")" ;;
  */pipelines\?*ref=*) body='[]' ;;	# nothing failed under the branch ref: MR pipelines carry refs/merge-requests/N/head
  */pipelines\?*sha=*) body="$(cat "$FAKE_RESP/gl-pipelines.json")" ;;
  */repository/branches/*) body="$(cat "$FAKE_RESP/branch.json")" ;;
  */merge_requests/*)  body="$(cat "$FAKE_RESP/mr.json")" ;;
  *) body='{}' ;;
esac
if [ -n "$outfile" ]; then printf '%s' "$body" >"$outfile"; else printf '%s' "$body"; fi
[ "$want_code" = 1 ] && printf '200'
exit 0
EOF
chmod +x "$FAKE2/curl"
run_other() {	# run_other <backend> <args…>
	local backend="$1"; shift
	PATH="$FAKE2:$PATH" bash "$REPO_ROOT/flight/scripts/adapters/$backend/ci" log "$@" 2>&1
}
printf '{"number":128,"head":{"sha":"%s"}}' "$SHA_PR" >"$RESP/pull.json"
printf '{"name":"feature/127-x","commit":{"id":"%s"}}' "$SHA_PR" >"$RESP/branch.json"
printf '{"iid":128,"sha":"%s"}' "$SHA_PR" >"$RESP/mr.json"

printf '\n\033[1m── github ci log ──\033[0m\n'
cat >"$RESP/gh-runs.json" <<JSON
{"workflow_runs":[
  {"id":71,"head_sha":"$SHA_PR","conclusion":"failure","run_started_at":"2026-09-17T10:00:00Z"},
  {"id":72,"head_sha":"$SHA_PR","conclusion":"success","run_started_at":"2026-09-17T10:00:00Z"}
]}
JSON
printf '{"jobs":[{"id":401,"conclusion":"failure"},{"id":402,"conclusion":"success"}]}' >"$RESP/gh-jobs-71.json"
printf '{"jobs":[{"id":403,"conclusion":"success"}]}' >"$RESP/gh-jobs-72.json"
out="$(run_other github --sha "$SHA_PR")"; rc=$?
check "github --sha: the red run is dumped even though a green one sorts last" \
	"$([ "$rc" = 0 ] && grep -q "FAKE-LOG job=401" <<<"$out" && ! grep -q "job=402\|job=403" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"
out="$(run_other github --pr 128)"; rc=$?
check "github --pr N resolves the head commit" "$([ "$rc" = 0 ] && grep -q "FAKE-LOG job=401" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"
jq -c '.workflow_runs |= map(.conclusion="success")' "$RESP/gh-runs.json" >"$RESP/gh.tmp" && mv "$RESP/gh.tmp" "$RESP/gh-runs.json"
out="$(run_other github --sha "$SHA_PR")"; rc=$?
check "github: all green → '(no failed jobs …)', exit 0" "$([ "$rc" = 0 ] && grep -q "no failed jobs" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"

printf '\n\033[1m── gitlab ci log ──\033[0m\n'
printf '[{"id":81,"sha":"%s","status":"success"},{"id":82,"sha":"%s","status":"failed"}]' "$SHA_PR" "$SHA_PR" >"$RESP/gl-pipelines.json"
printf '[{"id":502}]' >"$RESP/gl-jobs-82.json"
out="$(run_other gitlab --pr 128)"; rc=$?
check "gitlab --pr N resolves the MR's head commit and dumps the failed pipeline" \
	"$([ "$rc" = 0 ] && grep -q "FAKE-LOG job=502" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"
out="$(run_other gitlab --failed feature/127-x)"; rc=$?
check "gitlab --failed BRANCH falls back to the branch head for merge-request pipelines" \
	"$([ "$rc" = 0 ] && grep -q "FAKE-LOG job=502" <<<"$out" && echo 1 || echo 0)" "rc=$rc out=$out"

# Summary: plain when nothing failed, red when something did (#123).
[ "$fail" -gt 0 ] && summary_colour=$'\033[0;31m' || summary_colour=''
printf '\n%sPassed: %d  Failed: %d\033[0m\n' "$summary_colour" "$pass" "$fail"
[ "$fail" -eq 0 ]
