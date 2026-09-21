#!/usr/bin/env bash
# Dispatcher routing and identity resolution for schema-3 named trackers.
set -euo pipefail

unset LS_TOKEN FLIGHT_TOKEN FORGEJO_TOKEN LS_SECRETS_FILE
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DISP="$REPO_ROOT/flight/scripts/flight"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
R="$SANDBOX/repo"; mkdir -p "$R/.flightdirector" "$SANDBOX/bin"; git -C "$R" init -q

pass=0; fail=0
check() {
	if [ "$2" = 1 ]; then printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass + 1))
	else printf '\033[0;31m  ✗ %s\033[0m  %s\n' "$1" "${3:-}"; fail=$((fail + 1)); fi
}

cat >"$R/.flightdirector/config.json" <<'JSON'
{
  "schemaVersion": 3,
  "code": {"backend":"forgejo","api":"https://code.invalid/api","owner":"code","repo":"app","stages":[{"name":"main"}]},
  "issueTrackers": [
    {"ref":"FJ","name":"Primary","default":true,"backend":"forgejo","api":"https://one.invalid/api","owner":"one","repo":"backlog","labels":{"status":{"in-progress":"one/progress"}}},
    {"ref":"ALT","aliases":["Ext"],"name":"Second","default":false,"backend":"forgejo","api":"https://two.invalid/api","owner":"two","repo":"other","labels":{"status":{"in-progress":"alt/progress"}}},
    {"ref":"JIR","name":"Jira","default":false,"backend":"jira","api":"https://jira.invalid","project":"PROJ","email":"bot@example.invalid","labels":{}},
    {"ref":"CODE","name":"Explicit code credential","default":false,"backend":"forgejo","api":"https://code.invalid/api","owner":"code","repo":"app","credentialRef":"code","labels":{}}
  ]
}
JSON
cat >"$R/.flightdirector/secrets.json" <<'JSON'
{"code":{"token":"code-secret"},"issueTrackers":{"FJ":{"token":"token-one"},"ALT":{"token":"token-two"},"JIR":{"token":"jira-token","email":"jira@example.invalid"}}}
JSON

resolve() { (cd "$R" && "$DISP" issues resolve "$@"); }
field() { jq -r ".$1"; }

out="$(resolve --number 1)"
check "bare number selects the default" "$([ "$(printf '%s' "$out" | field tracker)" = FJ ] && echo 1 || echo 0)" "$out"
check "default identity is qualified and branch-safe" "$(printf '%s' "$out" | jq -e '.number == "1" and .qualified == "FJ-1" and .branchPrefix == "fj-1"' >/dev/null && echo 1 || echo 0)" "$out"
check "a leading hash remains an unqualified default number" "$(resolve --number '#1' | jq -e '.tracker == "FJ" and .number == "1"' >/dev/null && echo 1 || echo 0)"
check "compact ref syntax is case-insensitive" "$(resolve --number fJ1 | jq -e '.tracker == "FJ" and .number == "1"' >/dev/null && echo 1 || echo 0)"
check "hash ref syntax resolves" "$(resolve --number FJ#2 | jq -e '.qualified == "FJ-2"' >/dev/null && echo 1 || echo 0)"
check "exact alias resolves to canonical ref" "$(resolve --number eXt-3 | jq -e '.tracker == "ALT" and .qualified == "ALT-3"' >/dev/null && echo 1 || echo 0)"
check "Jira keeps its native key while qualifying with the tracker ref" "$(resolve --number proj-7 | jq -e '.tracker == "JIR" and .number == "PROJ-7" and .qualified == "JIR-7" and .branchPrefix == "jir-7"' >/dev/null && echo 1 || echo 0)"
check "explicit tracker accepts a native Jira key" "$(resolve --tracker JIR --number PROJ-8 | jq -e '.number == "PROJ-8" and .qualified == "JIR-8"' >/dev/null && echo 1 || echo 0)"
check "canonical Jira ref resolves back to native project key" "$(resolve --number JIR-8 | jq -e '.number == "PROJ-8" and .qualified == "JIR-8"' >/dev/null && echo 1 || echo 0)"
check "explicit Jira selector accepts a numeric suffix" "$(resolve --tracker JIR --number 9 | jq -e '.number == "PROJ-9" and .qualified == "JIR-9"' >/dev/null && echo 1 || echo 0)"
jq '(.issueTrackers[] | select(.ref == "FJ")).default = false | (.issueTrackers[] | select(.ref == "JIR")).default = true' "$R/.flightdirector/config.json" >"$SANDBOX/jira-default"
cp "$SANDBOX/jira-default" "$R/.flightdirector/config.json"
check "bare number selects a default Jira project" "$(resolve --number 10 | jq -e '.tracker == "JIR" and .number == "PROJ-10" and .qualified == "JIR-10"' >/dev/null && echo 1 || echo 0)"
jq '(.issueTrackers[] | select(.ref == "FJ")).default = true | (.issueTrackers[] | select(.ref == "JIR")).default = false' "$R/.flightdirector/config.json" >"$SANDBOX/default-fj"
cp "$SANDBOX/default-fj" "$R/.flightdirector/config.json"

if resolve --tracker ALT --number FJ-1 >"$SANDBOX/out" 2>"$SANDBOX/err"; then rc=0; else rc=$?; fi
check "conflicting explicit and qualified selectors fail" "$([ "$rc" != 0 ] && grep -qi 'conflict' "$SANDBOX/err" && echo 1 || echo 0)" "$(cat "$SANDBOX/err")"
if resolve --number GHH-1 >"$SANDBOX/out" 2>"$SANDBOX/err"; then rc=0; else rc=$?; fi
check "approximate names require a choice" "$([ "$rc" != 0 ] && grep -Eqi 'choose|configured|did you mean' "$SANDBOX/err" && echo 1 || echo 0)" "$(cat "$SANDBOX/err")"

# Prefix-overlapping refs make compact syntax ambiguous and must not guess.
cp "$R/.flightdirector/config.json" "$SANDBOX/config.good"
jq '.issueTrackers = [
  {ref:"A",name:"A",default:true,backend:"forgejo",labels:{}},
  {ref:"A1",name:"A1",default:false,backend:"forgejo",labels:{}}
]' "$SANDBOX/config.good" >"$R/.flightdirector/config.json"
if resolve --number A12 >"$SANDBOX/out" 2>"$SANDBOX/err"; then rc=0; else rc=$?; fi
check "ambiguous candidate splits fail with candidates" "$([ "$rc" != 0 ] && grep -qi 'ambiguous' "$SANDBOX/err" && grep -q 'A' "$SANDBOX/err" && grep -q 'A1' "$SANDBOX/err" && echo 1 || echo 0)" "$(cat "$SANDBOX/err")"
cp "$SANDBOX/config.good" "$R/.flightdirector/config.json"

jq '.issueTrackers[3].api = "https://other.invalid/api"' "$SANDBOX/config.good" >"$R/.flightdirector/config.json"
if resolve --number 1 >"$SANDBOX/out" 2>"$SANDBOX/err"; then rc=0; else rc=$?; fi
check "code credentials cannot be reused for a different target" "$([ "$rc" != 0 ] && grep -qi 'credentialRef\|credential' "$SANDBOX/err" && echo 1 || echo 0)" "$(cat "$SANDBOX/err")"
jq '.issueTrackers[0].credentialRef = "ALT"' "$SANDBOX/config.good" >"$R/.flightdirector/config.json"
if resolve --number 1 >"$SANDBOX/out" 2>"$SANDBOX/err"; then rc=0; else rc=$?; fi
check "credentials cannot be reused across tracker refs" "$([ "$rc" != 0 ] && grep -qi 'credentialRef\|credential' "$SANDBOX/err" && echo 1 || echo 0)" "$(cat "$SANDBOX/err")"
cp "$SANDBOX/config.good" "$R/.flightdirector/config.json"

# Invalid defaults and duplicate aliases are rejected before any operation.
jq '.issueTrackers[1].default = true' "$SANDBOX/config.good" >"$R/.flightdirector/config.json"
if resolve --number 1 >"$SANDBOX/out" 2>"$SANDBOX/err"; then rc=0; else rc=$?; fi
check "multiple defaults are rejected" "$([ "$rc" != 0 ] && grep -q 'invalid issueTrackers' "$SANDBOX/err" && echo 1 || echo 0)" "$(cat "$SANDBOX/err")"
jq '.issueTrackers[1].aliases = ["fj"]' "$SANDBOX/config.good" >"$R/.flightdirector/config.json"
if resolve --number 1 >"$SANDBOX/out" 2>"$SANDBOX/err"; then rc=0; else rc=$?; fi
check "case-insensitive ref/alias collisions are rejected" "$([ "$rc" != 0 ] && grep -q 'invalid issueTrackers' "$SANDBOX/err" && echo 1 || echo 0)" "$(cat "$SANDBOX/err")"
cp "$SANDBOX/config.good" "$R/.flightdirector/config.json"

# Fake Forgejo endpoints record the selected coordinates, token, and payload.
cat >"$SANDBOX/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=""; url=""; method=GET; data=""; headers=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		-D) printf 'x-total-count: 1\r\n' >"$2"; shift 2 ;;
		-w) shift 2 ;;
		-X) method="$2"; shift 2 ;;
		-H) headers="${headers}${headers:+|}$2"; shift 2 ;;
		--data-binary) data="$2"; shift 2 ;;
		-sS|-L) shift ;;
		*) url="$1"; shift ;;
	esac
done
printf '%s\t%s\t%s\t%s\n' "$method" "$url" "$headers" "$data" >>"${CURL_LOG:?}"
case "$url" in *fail.invalid*) exit 6 ;; esac
body='[]'
case "$url" in
	*/labels*page=1*) body='[{"id":22,"name":"alt/progress","color":"fff","description":""},{"id":23,"name":"model/sol","color":"fff","description":""}]' ;;
	*/labels*) body='[]' ;;
	*/rest/api/3/search/jql) body='{"issues":[{"key":"PROJ-1","fields":{"summary":"Jira issue","labels":[]}}]}' ;;
	*/issues/1) body='{"number":1,"title":"Selected","body":"Body","state":"open","labels":[]}' ;;
	*/issues*) body='[{"number":1,"title":"Listed","labels":[]}]' ;;
	*/user) body='{"id":2,"login":"bot"}' ;;
	*/repos/*) body='{"full_name":"two/other","private":true}' ;;
esac
[ -n "$out" ] && printf '%s' "$body" >"$out" || printf '%s' "$body"
printf '200'
SH
chmod +x "$SANDBOX/bin/curl"
export PATH="$SANDBOX/bin:$PATH" CURL_LOG="$SANDBOX/curl.log"

: >"$CURL_LOG"
(cd "$R" && FLIGHT_TOKEN=code-env "$DISP" issues get --tracker ALT --number 1 >/dev/null)
check "explicit tracker routes its coordinates" "$(grep -q 'https://two.invalid/api/repos/two/other/issues/1' "$CURL_LOG" && echo 1 || echo 0)" "$(cat "$CURL_LOG")"
check "tracker operation receives only its keyed token" "$(grep -q 'Authorization: token token-two' "$CURL_LOG" && ! grep -Eq 'token-one|code-secret|code-env' "$CURL_LOG" && echo 1 || echo 0)" "$(cat "$CURL_LOG")"

: >"$CURL_LOG"
(cd "$R" && "$DISP" issues set-status --tracker ALT --number 1 --status in-progress >/dev/null)
check "selected tracker supplies its own status label map" "$(if grep -q 'alt/progress' "$CURL_LOG" || grep -q '22' "$CURL_LOG"; then echo 1; else echo 0; fi)" "$(cat "$CURL_LOG")"

: >"$CURL_LOG"
out="$(cd "$R" && "$DISP" labels ensure --tracker ALT --model gpt-5.6-sol)"
check "labels ensure model sugar accepts --tracker" "$([ "$out" = 23 ] && echo 1 || echo 0)" "$out"
check "label operation uses selected tracker credential" "$(grep -q 'Authorization: token token-two' "$CURL_LOG" && echo 1 || echo 0)" "$(cat "$CURL_LOG")"

: >"$CURL_LOG"
(cd "$R" && "$DISP" issues get --tracker CODE --number 1 >/dev/null)
check "credentialRef code explicitly reuses the code secret" "$(grep -q 'Authorization: token code-secret' "$CURL_LOG" && echo 1 || echo 0)" "$(cat "$CURL_LOG")"

: >"$CURL_LOG"
(cd "$R" && "$DISP" auth check --tracker ALT >/dev/null || true)
check "tracker auth check routes tracker coordinates and token" "$(grep -q 'https://two.invalid/api' "$CURL_LOG" && grep -q 'Authorization: token token-two' "$CURL_LOG" && echo 1 || echo 0)" "$(cat "$CURL_LOG")"

# All-tracker listing qualifies same-number results and reports a failed source.
jq '.issueTrackers = [
  .issueTrackers[0], .issueTrackers[1], .issueTrackers[2],
  {ref:"BAD",name:"Unavailable",default:false,backend:"forgejo",api:"https://fail.invalid/api",owner:"bad",repo:"bad",labels:{}}
]' "$SANDBOX/config.good" >"$R/.flightdirector/config.json"
jq '.issueTrackers.BAD.token = "bad-token"' "$R/.flightdirector/secrets.json" >"$SANDBOX/sec" && mv "$SANDBOX/sec" "$R/.flightdirector/secrets.json"
if (cd "$R" && "$DISP" issues list --all-trackers --limit 1 >"$SANDBOX/out" 2>"$SANDBOX/err"); then rc=0; else rc=$?; fi
check "all-tracker list keeps same-number sources distinct" "$(grep -q $'^FJ-1\t' "$SANDBOX/out" && grep -q $'^ALT-1\t' "$SANDBOX/out" && echo 1 || echo 0)" "$(cat "$SANDBOX/out")"
check "all-tracker list qualifies Jira native keys with the tracker ref" "$(grep -q $'^JIR-1\t' "$SANDBOX/out" && echo 1 || echo 0)" "$(cat "$SANDBOX/out")"
check "an unavailable tracker is reported, not shown as empty" "$([ "$rc" != 0 ] && grep -q 'BAD' "$SANDBOX/err" && grep -qi 'unavailable' "$SANDBOX/err" && echo 1 || echo 0)" "$(cat "$SANDBOX/err")"

[ "$fail" -gt 0 ] && colour=$'\033[0;31m' || colour=''
printf '\n%sPassed: %d  Failed: %d\033[0m\n' "$colour" "$pass" "$fail"
[ "$fail" -eq 0 ]
