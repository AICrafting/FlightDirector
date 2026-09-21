#!/usr/bin/env bash
# Dispatcher routing and identity resolution for schema-3 named issue trackers (#197):
# `issues resolve`, `--tracker`, `issues tracker`, `issues list --all-trackers`, and
# which coordinates / credential / label map each adapter call receives. The network
# is a fake `curl` on PATH that logs method, URL, headers and payload.
set -euo pipefail

unset LS_TOKEN FLIGHT_TOKEN FORGEJO_TOKEN LS_SECRETS_FILE LS_EMAIL
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DISP="$REPO_ROOT/flight/scripts/flight"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
R="$SANDBOX/repo"; mkdir -p "$R/.flightdirector" "$SANDBOX/bin"; git -C "$R" init -q
CFG="$R/.flightdirector/config.json"; SEC="$R/.flightdirector/secrets.json"

pass=0; fail=0
check() {
	if [ "$2" = 1 ]; then printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass + 1))
	else printf '\033[0;31m  ✗ %s\033[0m  %s\n' "$1" "${3:-}"; fail=$((fail + 1)); fi
}
section() { printf '\033[1m── %s ──\033[0m\n' "$1"; }

# FJ (default) and ALT are two trackers on one backend with independent tokens; JIR
# is a Jira project whose native key (PROJ) differs from its ref; SAME shares the code
# credential explicitly (same host as code).
cat >"$CFG" <<'JSON'
{
  "schemaVersion": 3,
  "code": {"backend":"forgejo","api":"https://code.example.com/api/v1","owner":"code","repo":"app","stages":[{"name":"main"}]},
  "issues": {"backend":"requires-newer-flight"},
  "issueTrackers": [
    {"ref":"FJ","name":"Primary","default":true,"backend":"forgejo","api":"https://one.example.com/api/v1","owner":"one","repo":"backlog","labels":{"status":{"in-progress":"one/progress","new":"one/new"}}},
    {"ref":"ALT","aliases":["Ext"],"name":"Second","default":false,"backend":"forgejo","api":"https://two.example.com/api/v1","owner":"two","repo":"other","labels":{"status":{"in-progress":"alt/progress"}}},
    {"ref":"JIR","name":"Jira","default":false,"backend":"jira","api":"https://jira.example.com","project":"PROJ","email":"bot@example.com","labels":{}},
    {"ref":"SAME","name":"Shares the code credential","default":false,"backend":"forgejo","api":"https://code.example.com/api/v1/","owner":"code","repo":"issues-only","credentialRef":"code","labels":{}}
  ]
}
JSON
cat >"$SEC" <<'JSON'
{"code":{"token":"code-secret"},"issueTrackers":{"FJ":{"token":"token-one"},"ALT":{"token":"token-two"},"JIR":{"token":"jira-token","email":"jira@example.com"}}}
JSON
cp "$CFG" "$SANDBOX/config.good"

resolve() { (cd "$R" && "$DISP" issues resolve "$@"); }
fails() {	# fails <pattern> <cmd…> — the command exits non-zero and stderr matches
	local pat="$1"; shift
	if (cd "$R" && "$@" >"$SANDBOX/out" 2>"$SANDBOX/err"); then return 1; fi
	grep -Eqi -- "$pat" "$SANDBOX/err"
}

section "identity resolution"
out="$(resolve --number 1)"
check "bare number selects the default" "$(jq -e '.tracker == "FJ"' <<<"$out" >/dev/null && echo 1 || echo 0)" "$out"
check "identity is qualified and branch-safe" "$(jq -e '.number == "1" and .qualified == "FJ-1" and .branchPrefix == "fj-1" and (keys == ["branchPrefix","number","qualified","tracker"])' <<<"$out" >/dev/null && echo 1 || echo 0)" "$out"
check "a leading hash is still the default tracker" "$(resolve --number '#1' | jq -e '.tracker == "FJ" and .number == "1"' >/dev/null && echo 1 || echo 0)"
check "compact REF-less form GH1 is case-insensitive" "$(resolve --number fJ1 | jq -e '.tracker == "FJ" and .number == "1"' >/dev/null && echo 1 || echo 0)"
check "REF#N resolves" "$(resolve --number FJ#2 | jq -e '.qualified == "FJ-2"' >/dev/null && echo 1 || echo 0)"
check "an exact alias resolves case-insensitively to the canonical ref" "$(resolve --number eXt-3 | jq -e '.tracker == "ALT" and .qualified == "ALT-3"' >/dev/null && echo 1 || echo 0)"
check "leading zeros normalise to one identity" "$(resolve --number FJ-007 | jq -e '.number == "7" and .qualified == "FJ-7"' >/dev/null && echo 1 || echo 0)"
check "a Jira key keeps its native id and qualifies with the tracker ref" "$(resolve --number proj-7 | jq -e '.tracker == "JIR" and .number == "PROJ-7" and .qualified == "JIR-7" and .branchPrefix == "jir-7"' >/dev/null && echo 1 || echo 0)"
check "--tracker accepts a native Jira key" "$(resolve --tracker JIR --number PROJ-8 | jq -e '.number == "PROJ-8" and .qualified == "JIR-8"' >/dev/null && echo 1 || echo 0)"
check "the tracker-ref form of a Jira issue maps back to the native key" "$(resolve --number JIR-8 | jq -e '.number == "PROJ-8"' >/dev/null && echo 1 || echo 0)"
check "--tracker with a bare number builds the Jira key" "$(resolve --tracker jir --number 9 | jq -e '.number == "PROJ-9" and .qualified == "JIR-9"' >/dev/null && echo 1 || echo 0)"
check "--tracker by alias selects the canonical tracker" "$(resolve --tracker EXT --number 4 | jq -e '.tracker == "ALT" and .number == "4"' >/dev/null && echo 1 || echo 0)"
check "same number on two trackers stays two identities" "$([ "$(resolve --number FJ-1 | jq -r .qualified)" != "$(resolve --number ALT-1 | jq -r .qualified)" ] && echo 1 || echo 0)"

jq '(.issueTrackers[] | select(.ref == "FJ")).default = false | (.issueTrackers[] | select(.ref == "JIR")).default = true' "$SANDBOX/config.good" >"$CFG"
check "after a default change a bare number follows the new default" "$(resolve --number 10 | jq -e '.tracker == "JIR" and .number == "PROJ-10"' >/dev/null && echo 1 || echo 0)"
check "after a default change a qualified id keeps its tracker" "$(resolve --number FJ-10 | jq -e '.tracker == "FJ" and .number == "10"' >/dev/null && echo 1 || echo 0)"
cp "$SANDBOX/config.good" "$CFG"

section "selection errors — never a guess"
check "an explicit selector conflicting with a qualified id fails" "$(fails 'conflicts' "$DISP" issues resolve --tracker ALT --number FJ-1 && echo 1 || echo 0)" "$(cat "$SANDBOX/err")"
check "an approximate ref suggests, and does not select" "$(fails 'did you mean FJ' "$DISP" issues resolve --number FJJ-1 && echo 1 || echo 0)" "$(cat "$SANDBOX/err")"
check "the suggestion lists the configured trackers" "$(grep -q 'ALT (alias Ext)' "$SANDBOX/err" && grep -q 'Jira project PROJ' "$SANDBOX/err" && echo 1 || echo 0)" "$(cat "$SANDBOX/err")"
check "an unknown --tracker fails and lists the choices" "$(fails "unknown tracker 'NOPE'.*Configured trackers: FJ" "$DISP" issues resolve --tracker NOPE --number 1 && echo 1 || echo 0)" "$(cat "$SANDBOX/err")"
check "a non-number input fails" "$(fails 'not an issue number' "$DISP" issues resolve --number 'hello' && echo 1 || echo 0)" "$(cat "$SANDBOX/err")"
check "an input naming another tracker's prefix under --tracker fails" "$(fails 'does not belong to tracker FJ' "$DISP" issues resolve --tracker FJ --number ZZ-3 && echo 1 || echo 0)" "$(cat "$SANDBOX/err")"
check "--tracker twice fails" "$(fails 'more than once' "$DISP" issues get --tracker FJ --tracker ALT --number 1 && echo 1 || echo 0)" "$(cat "$SANDBOX/err")"
check "--all-trackers is list-only" "$(fails 'only by .issues list' "$DISP" issues get --all-trackers --number 1 && echo 1 || echo 0)" "$(cat "$SANDBOX/err")"
check "--all-trackers cannot be combined with --tracker" "$(fails 'cannot be combined' "$DISP" issues list --all-trackers --tracker FJ && echo 1 || echo 0)" "$(cat "$SANDBOX/err")"

# Overlapping refs: A12 splits as A-12 or A1-2. Fail with both candidates; an
# explicit selector may choose between them.
jq '.issueTrackers = [
  {ref:"A",name:"A",default:true,backend:"forgejo",labels:{}},
  {ref:"A1",name:"A1",default:false,backend:"forgejo",labels:{}}
]' "$SANDBOX/config.good" >"$CFG"
check "an ambiguous split fails and names every candidate" "$(fails 'ambiguous.*A, A1' "$DISP" issues resolve --number A12 && echo 1 || echo 0)" "$(cat "$SANDBOX/err")"
check "--tracker disambiguates an ambiguous split (A1 → A1-2)" "$(resolve --tracker A1 --number A12 | jq -e '.qualified == "A1-2"' >/dev/null && echo 1 || echo 0)"
check "--tracker disambiguates an ambiguous split (A → A-12)" "$(resolve --tracker a --number A12 | jq -e '.qualified == "A-12"' >/dev/null && echo 1 || echo 0)"
cp "$SANDBOX/config.good" "$CFG"

section "configuration validation (before any adapter call)"
invalid() {	# invalid <description> <jq edit> <expected message>
	jq "$2" "$SANDBOX/config.good" >"$CFG"
	check "$1" "$(fails "$3" "$DISP" issues resolve --number 1 && echo 1 || echo 0)" "$(cat "$SANDBOX/err")"
}
invalid "two defaults are rejected" '.issueTrackers[1].default = true' 'exactly one tracker must have "default": true \(found 2\)'
invalid "no default is rejected" '.issueTrackers[0].default = false' 'found 0'
invalid "a non-boolean default is rejected" '.issueTrackers[1].default = "yes"' 'default must be true or false'
invalid "a ref/alias collision (case-insensitive) is rejected" '.issueTrackers[1].aliases = ["fj"]' 'ref/alias "fj" is used more than once'
invalid "a ref with a separator is rejected" '.issueTrackers[1].ref = "AL-T"' 'ref must start with a letter'
invalid "the reserved ref code is rejected" '.issueTrackers[1].ref = "Code"' 'reserved'
invalid "a missing name is rejected" 'del(.issueTrackers[1].name)' 'name must be a non-empty string'
invalid "an empty tracker array is rejected" '.issueTrackers = []' 'non-empty array'
invalid "credentialRef code on another host is rejected" '.issueTrackers[3].api = "https://other.example.com/api/v1"' 'credentialRef "code" reuses the code token only'
invalid "credentialRef naming another tracker is rejected" '.issueTrackers[0].credentialRef = "ALT"' 'credentialRef must be omitted'
invalid "a legacy labels map beside issueTrackers is rejected" '.labels = {}' 'top-level labels'
invalid "a real legacy issues object beside issueTrackers is rejected" '.issues = {"backend":"github"}' 'pre-schema-3 issues object'
invalid "every problem is reported at once" '.issueTrackers[1].default = true | .issueTrackers[2].name = ""' 'found 2'
check "…including the second problem" "$(grep -q 'name must be a non-empty string' "$SANDBOX/err" && echo 1 || echo 0)" "$(cat "$SANDBOX/err")"
jq '.issueTrackers[1].default = true' "$SANDBOX/config.good" >"$CFG"
out="$(cd "$R" && "$DISP" config '.code.backend' 2>&1)"
check "plain config reads still work on an invalid tracker config (so it can be repaired)" "$([ "$out" = forgejo ] && echo 1 || echo 0)" "$out"
cp "$SANDBOX/config.good" "$CFG"
jq '.issueTrackers[3].repo = "different-repo"' "$SANDBOX/config.good" >"$CFG"
check "credentialRef code on the same host but another repo is accepted" "$(resolve --number SAME-1 | jq -e '.tracker == "SAME"' >/dev/null && echo 1 || echo 0)"
cp "$SANDBOX/config.good" "$CFG"
# A local override may move code to another route (a tunnel) on this machine; a tracker
# sharing the code credential on the committed code host stays valid, one elsewhere does not.
printf '%s\n' '{"code":{"api":"https://tunnel.example.com/api/v1"}}' >"$R/.flightdirector/config.local.json"
check "credentialRef code on the tracked code host survives a local code host override" "$(resolve --number SAME-1 | jq -e '.tracker == "SAME"' >/dev/null && echo 1 || echo 0)"
jq '.issueTrackers[3].api = "https://other.example.com/api/v1"' "$SANDBOX/config.good" >"$CFG"
check "…but credentialRef code on a third host is still rejected" "$(fails 'credentialRef "code" reuses the code token only' "$DISP" issues resolve --number 1 && echo 1 || echo 0)" "$(cat "$SANDBOX/err")"
rm -f "$R/.flightdirector/config.local.json"
cp "$SANDBOX/config.good" "$CFG"

# Fake Forgejo/Jira endpoints: log the call, answer plausibly.
cat >"$SANDBOX/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=""; url=""; method=GET; data=""; headers=""; user=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		-D) printf 'x-total-count: 1\r\n' >"$2"; shift 2 ;;
		-w) shift 2 ;;
		-X) method="$2"; shift 2 ;;
		-H) headers="${headers}${headers:+|}$2"; shift 2 ;;
		-u) user="$2"; shift 2 ;;
		--data-binary|-d|--data) data="$2"; shift 2 ;;
		-sS|-L|-s|-f|-fsS) shift ;;
		*) url="$1"; shift ;;
	esac
done
printf '%s\t%s\t%s\t%s\t%s\n' "$method" "$url" "$headers" "$user" "$data" >>"${CURL_LOG:?}"
case "$url" in *fail.example.com*) exit 6 ;; esac
body='[]'
case "$url" in
	*/labels*page=1*) body='[{"id":22,"name":"alt/progress","color":"fff","description":""},{"id":23,"name":"model/sol","color":"fff","description":""},{"id":24,"name":"one/progress","color":"fff","description":""}]' ;;
	*/labels*) body='[]' ;;
	*/rest/api/3/search/jql*) body='{"issues":[{"key":"PROJ-1","fields":{"summary":"Jira issue","labels":[]}}]}' ;;
	*/rest/api/3/issue/*) body='{"key":"PROJ-7","fields":{"summary":"Jira","description":null,"status":{"name":"To Do","statusCategory":{"key":"new"}}}}' ;;
	*/issues/1) body='{"number":1,"title":"Selected","body":"Body","state":"open","labels":[]}' ;;
	*/issues*) body='[{"number":1,"title":"Listed","labels":[]}]' ;;
	*/pulls*) body='[]' ;;
	*/user) body='{"id":2,"login":"bot"}' ;;
	*/repos/*) body='{"full_name":"two/other","private":true}' ;;
esac
if [ -n "$out" ]; then printf '%s' "$body" >"$out"; else printf '%s' "$body"; fi
printf '200'
SH
chmod +x "$SANDBOX/bin/curl"
export PATH="$SANDBOX/bin:$PATH" CURL_LOG="$SANDBOX/curl.log"
log() { cat "$CURL_LOG"; }

section "adapter scoping"
: >"$CURL_LOG"
(cd "$R" && FLIGHT_TOKEN=code-env "$DISP" issues get --tracker ALT --number 1 >/dev/null)
check "--tracker routes the tracker's coordinates" "$(grep -q 'https://two.example.com/api/v1/repos/two/other/issues/1' "$CURL_LOG" && echo 1 || echo 0)" "$(log)"
check "a tracker with its own credential gets only its keyed token — env never shadows it" "$(grep -q 'Authorization: token token-two' "$CURL_LOG" && ! grep -Eq 'token-one|code-secret|code-env' "$CURL_LOG" && echo 1 || echo 0)" "$(log)"

: >"$CURL_LOG"
(cd "$R" && "$DISP" issues get --number ext-1 >/dev/null)
check "a qualified alias id routes without --tracker" "$(grep -q 'two.example.com/api/v1/repos/two/other/issues/1' "$CURL_LOG" && echo 1 || echo 0)" "$(log)"

: >"$CURL_LOG"
(cd "$R" && "$DISP" issues get --number 1 >/dev/null)
check "an unqualified id goes to the default tracker with its token" "$(grep -q 'one.example.com/api/v1/repos/one/backlog/issues/1' "$CURL_LOG" && grep -q 'token token-one' "$CURL_LOG" && echo 1 || echo 0)" "$(log)"

: >"$CURL_LOG"
(cd "$R" && "$DISP" issues set-status --tracker ALT --number 1 --status in-progress >/dev/null 2>&1) || true
check "the selected tracker's own status map is used" "$(grep -q '22' "$CURL_LOG" && ! grep -q '"24"\|\[24\]' "$CURL_LOG" && echo 1 || echo 0)" "$(log)"

: >"$CURL_LOG"
(cd "$R" && "$DISP" issues create --tracker ALT --title T --body B --no-signature >/dev/null 2>&1) || true
check "the default tracker's starting-status label does not leak to another tracker" "$(grep -q 'repos/two/other/issues' "$CURL_LOG" && ! grep -q 'one/new' "$CURL_LOG" && echo 1 || echo 0)" "$(log)"

: >"$CURL_LOG"
out="$(cd "$R" && "$DISP" labels ensure --tracker ALT --model gpt-5.6-sol)"
check "labels ensure --model accepts --tracker" "$([ "$out" = 23 ] && echo 1 || echo 0)" "$out"
check "label operations use the selected tracker's host and credential" "$(grep -q 'two.example.com' "$CURL_LOG" && grep -q 'Authorization: token token-two' "$CURL_LOG" && echo 1 || echo 0)" "$(log)"

: >"$CURL_LOG"
(cd "$R" && "$DISP" issues get --number proj-7 >/dev/null 2>&1) || true
check "a Jira adapter receives the native key and its own email:token" "$(grep -q 'jira.example.com/rest/api/3/issue/PROJ-7' "$CURL_LOG" && echo 1 || echo 0)" "$(log)"

: >"$CURL_LOG"
(cd "$R" && "$DISP" issues get --tracker SAME --number 1 >/dev/null)
check "credentialRef code reuses the code secret" "$(grep -q 'Authorization: token code-secret' "$CURL_LOG" && echo 1 || echo 0)" "$(log)"
: >"$CURL_LOG"
(cd "$R" && FLIGHT_TOKEN=code-env "$DISP" issues get --tracker SAME --number 1 >/dev/null)
check "credentialRef code honours env tokens exactly like the code axis" "$(grep -q 'Authorization: token code-env' "$CURL_LOG" && echo 1 || echo 0)" "$(log)"

: >"$CURL_LOG"
(cd "$R" && FLIGHT_TOKEN=code-env "$DISP" pr list --state open >/dev/null 2>&1) || true
check "PR verbs keep using code coordinates and the code credential" "$(grep -q 'code.example.com/api/v1/repos/code/app/pulls' "$CURL_LOG" && grep -q 'token code-env' "$CURL_LOG" && ! grep -q 'one.example.com' "$CURL_LOG" && echo 1 || echo 0)" "$(log)"
check "PR verbs reject --tracker (it is not a PR selector)" "$(fails 'unknown|usage|--tracker' "$DISP" pr list --tracker ALT && echo 1 || echo 0)" "$(cat "$SANDBOX/err")"

: >"$CURL_LOG"
check "an unknown tracker makes no network call" "$(fails 'unknown tracker' "$DISP" issues comment --tracker NOPE --number 1 --body hi && [ ! -s "$CURL_LOG" ] && echo 1 || echo 0)" "$(cat "$SANDBOX/err")"
jq '.issueTrackers[1].default = true' "$SANDBOX/config.good" >"$CFG"
: >"$CURL_LOG"
check "an invalid config is rejected before any write" "$(fails 'invalid issueTrackers' "$DISP" issues comment --number 1 --body hi && [ ! -s "$CURL_LOG" ] && echo 1 || echo 0)" "$(cat "$SANDBOX/err")"
cp "$SANDBOX/config.good" "$CFG"

out="$(cd "$R" && "$DISP" issues tracker --tracker ext)"
check "issues tracker prints the selected entry" "$(jq -e '.ref == "ALT" and .labels.status["in-progress"] == "alt/progress"' <<<"$out" >/dev/null && echo 1 || echo 0)" "$out"
check "issues tracker without --tracker is the default" "$(cd "$R" && "$DISP" issues tracker | jq -e '.ref == "FJ"' >/dev/null && echo 1 || echo 0)"

section "auth check"
: >"$CURL_LOG"
(cd "$R" && "$DISP" auth check --tracker ALT >/dev/null 2>&1) || true
check "auth check --tracker checks that tracker's host and token" "$(grep -q 'two.example.com' "$CURL_LOG" && grep -q 'Authorization: token token-two' "$CURL_LOG" && ! grep -q 'code.example.com' "$CURL_LOG" && echo 1 || echo 0)" "$(log)"
: >"$CURL_LOG"
(cd "$R" && "$DISP" auth check --axis issues >/dev/null 2>&1) || true
check "auth check --axis issues checks the default tracker" "$(grep -q 'one.example.com' "$CURL_LOG" && grep -q 'token token-one' "$CURL_LOG" && echo 1 || echo 0)" "$(log)"
: >"$CURL_LOG"
(cd "$R" && "$DISP" auth check >/dev/null 2>&1) || true
check "plain auth check still checks code" "$(grep -q 'code.example.com' "$CURL_LOG" && grep -q 'token code-secret' "$CURL_LOG" && echo 1 || echo 0)" "$(log)"
check "auth check --tracker with --axis code is a conflict" "$(fails 'conflicts with --axis code' "$DISP" auth check --tracker ALT --axis code && echo 1 || echo 0)" "$(cat "$SANDBOX/err")"
jq '.issueTrackers.ALT.token = "candidate-two"' "$SEC" >"$SANDBOX/candidate.json"
: >"$CURL_LOG"
(cd "$R" && "$DISP" auth check --tracker ALT --secrets "$SANDBOX/candidate.json" >/dev/null 2>&1) || true
check "auth check --tracker --secrets verifies the candidate tracker token" "$(grep -q 'token candidate-two' "$CURL_LOG" && echo 1 || echo 0)" "$(log)"

section "all-trackers view"
jq '.issueTrackers = [
  .issueTrackers[0], .issueTrackers[1], .issueTrackers[2], .issueTrackers[3],
  {ref:"BAD",name:"Unavailable",default:false,backend:"forgejo",api:"https://fail.example.com/api/v1",owner:"bad",repo:"bad",labels:{}}
]' "$SANDBOX/config.good" >"$CFG"
jq '.issueTrackers.BAD.token = "bad-token"' "$SEC" >"$SANDBOX/sec" && cp "$SANDBOX/sec" "$SEC"
: >"$CURL_LOG"
if (cd "$R" && FLIGHT_TOKEN=code-env "$DISP" issues list --all-trackers --limit 1 >"$SANDBOX/out" 2>"$SANDBOX/err"); then rc=0; else rc=$?; fi
check "rows are the tracker's own row with REF-N prepended" "$(grep -q $'^FJ-1\t1\tListed\t' "$SANDBOX/out" && grep -q $'^ALT-1\t1\tListed\t' "$SANDBOX/out" && echo 1 || echo 0)" "$(cat "$SANDBOX/out")"
check "Jira rows are qualified by tracker ref and keep the native key" "$(grep -q $'^JIR-1\tPROJ-1\t' "$SANDBOX/out" && echo 1 || echo 0)" "$(cat "$SANDBOX/out")"
check "a credentialRef-code tracker still gets the env code token" "$(grep -q 'repos/code/issues-only/issues.*token code-env' "$CURL_LOG" && echo 1 || echo 0)" "$(log)"
check "each tracker is listed with its own token" "$(grep -q 'repos/two/other/issues.*token token-two' "$CURL_LOG" && grep -q 'repos/one/backlog/issues.*token token-one' "$CURL_LOG" && echo 1 || echo 0)" "$(log)"
check "an unavailable tracker is reported and fails the view — never an empty backlog" "$([ "$rc" != 0 ] && grep -q 'tracker BAD unavailable' "$SANDBOX/err" && echo 1 || echo 0)" "rc=$rc $(cat "$SANDBOX/err")"
cp "$SANDBOX/config.good" "$CFG"
: >"$CURL_LOG"
(cd "$R" && "$DISP" issues list --limit 1 >"$SANDBOX/out")
check "ordinary issues list keeps its unqualified TSV" "$([ "$(cat "$SANDBOX/out")" = "$(printf '1\tListed\t')" ] && echo 1 || echo 0)" "$(cat -A "$SANDBOX/out")"

[ "$fail" -gt 0 ] && colour=$'\033[0;31m' || colour=''
printf '\n%sPassed: %d  Failed: %d\033[0m\n' "$colour" "$pass" "$fail"
[ "$fail" -eq 0 ]
