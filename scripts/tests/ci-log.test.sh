#!/usr/bin/env bash
# Unit tests for the forgejo `ci log` adapter verb — the Forgejo 16
# /actions/runs + /actions/runs/{id}/jobs + /actions/jobs/{id}/logs flow
# (issue #54). The network is stubbed with a fake `curl` on PATH, same
# pattern as ci-watch.test.sh — no live backend needed.
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
    body="$(cat "$FAKE_RESP/jobs.json")" ;;
  */actions/runs\?*)
    body="$(cat "$FAKE_RESP/runs.json")"
    case "$url" in *head_sha=*)
      q="${url##*head_sha=}"; q="${q%%&*}"
      body="$(printf '%s' "$body" | jq -c --arg s "$q" '.workflow_runs |= map(select(.commit_sha==$s))')"
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
	PATH="$FAKE_DIR:$PATH" bash "$REPO_ROOT/lightspeed/scripts/adapters/forgejo/ci" log "$@" 2>&1
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

printf '\033[1m────────────────────────────\033[0m\n'
printf 'Passed: %d  Failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
