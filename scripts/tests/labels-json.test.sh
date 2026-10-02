#!/usr/bin/env bash
# shellcheck disable=SC2016  # the single-quoted strings are jq programs; their $-vars are jq's
# `labels list --json` and `labels statuses [--json]` (#250): the label filter chips
# and the status-role filter a UI needs, without assuming any repo's label names.
# The network is a fake `curl`. Contract: flight/references/json-output.md.
set -euo pipefail

unset LS_TOKEN FLIGHT_TOKEN FORGEJO_TOKEN LS_SECRETS_FILE LS_EMAIL FLIGHT_ERROR_FILE LS_JSON
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DISP="$REPO_ROOT/flight/scripts/flight"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

pass=0; fail=0
check() {
	if [ "$2" = 1 ]; then printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass + 1))
	else printf '\033[0;31m  ✗ %s\033[0m  %s\n' "$1" "${3:-}"; fail=$((fail + 1)); fi
}
section() { printf '\033[1m── %s ──\033[0m\n' "$1"; }
yes() { "$@" >/dev/null 2>&1 && echo 1 || echo 0; }

R="$SANDBOX/repo"; mkdir -p "$R/.flightdirector" "$SANDBOX/bin"; git -C "$R" init -q
cat >"$R/.flightdirector/config.json" <<'JSON'
{
  "schemaVersion": 3,
  "code": {"backend":"forgejo","api":"https://fj.example/api/v1","owner":"o","repo":"r","stages":[{"name":"main"}]},
  "issues": {"backend":"requires-newer-flight"},
  "issueTrackers": [
    {"ref":"FJ","name":"Forgejo","default":true,"backend":"forgejo","api":"https://fj.example/api/v1","owner":"o","repo":"r","credentialRef":"code",
     "labels":{"status":{"new":"status/new","in-progress":"status/in progress","to-test":"status/to test","done":false,"qa":"status/qa"}}},
    {"ref":"GH","name":"GitHub","default":false,"backend":"github","api":"https://gh.example","owner":"o","repo":"r",
     "labels":{"status":{"to-test":"needs-test"}}},
    {"ref":"GL","name":"GitLab","default":false,"backend":"gitlab","api":"https://gl.example/api/v4","owner":"o","repo":"r","labels":{}},
    {"ref":"JIR","name":"Jira","default":false,"backend":"jira","api":"https://jira.example","project":"KAN","email":"b@e.x",
     "labels":{"status":{"to-test":"status-to-test"}}}
  ]
}
JSON
echo '{"code":{"token":"t"},"issueTrackers":{"GH":{"token":"t"},"GL":{"token":"t"},"JIR":{"token":"t"}}}' >"$R/.flightdirector/secrets.json"

cat >"$SANDBOX/bin/curl" <<'SH'
#!/usr/bin/env bash
out=""; url=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		-D|--data-binary|-w|-X|-H|-u) shift 2 ;;
		-*) shift ;;
		*) url="$1"; shift ;;
	esac
done
[ -z "${FAIL_ALL:-}" ] || { echo "curl: (7) Failed to connect" >&2; exit 7; }
case "$url" in
	*[?\&]page=[2-9]*|*startAt=[1-9]*) body='[]'; case "$url" in *jira*) body='{"values":[],"total":2}' ;; esac ;;
	*fj.example*/labels*) body='[{"id":1,"name":"bug","color":"e11d21","description":"Something is broken"},
		{"id":2,"name":"status/to test","color":"#E3A008","description":""},
		{"id":3,"name":"status/in progress","color":"1f9d55"}]' ;;
	*gh.example*/labels*) body='[{"id":5,"name":"needs-test","color":"FBCA04","description":null}]' ;;
	*gl.example*/labels*) body='[{"id":7,"name":"Testing","color":"#428BCA","description":"GitLab label"}]' ;;
	*jira.example*/label*) body='{"values":["status-to-test","backend"],"total":2}' ;;
	*) body='{"message":"no fixture"}'; printf '%s' "$body" >"$out"; printf 404; exit 0 ;;
esac
printf '%s' "$body" >"$out"
printf 200
SH
chmod +x "$SANDBOX/bin/curl"
export PATH="$SANDBOX/bin:$PATH"
fl() { (cd "$R" && "$DISP" "$@"); }

section "labels list --json"
out="$(fl labels list --json)"
check "forgejo: [{name, color, description}] in the backend's order" \
	"$(yes jq -e 'map(.name) == ["bug","status/to test","status/in progress"] and all(.[]; keys == ["color","description","name"])' <<<"$out")" "$out"
check "colours normalized to #rrggbb lowercase, with or without the backend's #" \
	"$(yes jq -e 'map(.color) == ["#e11d21","#e3a008","#1f9d55"]' <<<"$out")" "$out"
check "an empty or absent description is null" "$(yes jq -e '.[1].description == null and .[2].description == null and .[0].description == "Something is broken"' <<<"$out")" "$out"
out="$(fl labels list --tracker GH --json)"
check "github: same shape" "$(yes jq -e '. == [{name:"needs-test", color:"#fbca04", description:null}]' <<<"$out")" "$out"
out="$(fl labels list --tracker GL --json)"
check "gitlab: same shape" "$(yes jq -e '. == [{name:"Testing", color:"#428bca", description:"GitLab label"}]' <<<"$out")" "$out"
out="$(fl labels list --tracker JIR --json)"
check "jira: bare label names, colour and description null" \
	"$(yes jq -e '. == [{name:"status-to-test", color:null, description:null}, {name:"backend", color:null, description:null}]' <<<"$out")" "$out"
check "without --json, labels list is the TSV it always was" \
	"$([ "$(fl labels list | head -n1)" = "$(printf 'bug\te11d21\tSomething is broken')" ] && echo 1 || echo 0)"

section "labels statuses"
out="$(fl labels statuses --json)"
check "roles in the tracker's config order; declined (false) roles left out" \
	"$(yes jq -e 'map(.role) == ["new","in-progress","to-test","qa"]' <<<"$out")" "$out"
check "each role carries its label name and that label's colour" \
	"$(yes jq -e '.[2] == {role:"to-test", label:"status/to test", color:"#e3a008"}' <<<"$out")" "$out"
check "a role whose label is missing on the tracker has colour null" \
	"$(yes jq -e '.[0] == {role:"new", label:"status/new", color:null}' <<<"$out")" "$out"
out="$(fl labels statuses --tracker GH --json)"
check "--tracker selects that tracker's map and colours" "$(yes jq -e '. == [{role:"to-test", label:"needs-test", color:"#fbca04"}]' <<<"$out")" "$out"
out="$(fl labels statuses --tracker GL --json)"
check "a tracker with no status roles is an empty array" "$(yes jq -e '. == []' <<<"$out")" "$out"
out="$(fl labels statuses --tracker JIR --json)"
check "jira: colour null" "$(yes jq -e '. == [{role:"to-test", label:"status-to-test", color:null}]' <<<"$out")" "$out"
out="$(fl labels statuses)"
check "text form: role⇥label⇥color rows (empty colour when unknown)" \
	"$([ "$(head -n1 <<<"$out")" = "$(printf 'new\tstatus/new\t')" ] && [ "$(sed -n 3p <<<"$out")" = "$(printf 'to-test\tstatus/to test\t#e3a008')" ] && echo 1 || echo 0)" "$out"
out="$(cd "$R" && FAIL_ALL=1 "$DISP" labels statuses --json 2>/dev/null || true)"
check "an unreachable tracker → the nested call's network envelope, alone on stdout" \
	"$(yes jq -e 'keys == ["error"] and .error.code == "network"' <<<"$out")" "$out"
rc=0; out="$(cd "$R" && FAIL_ALL=1 "$DISP" labels list 2>/dev/null)" || rc=$?
check "regression: an unreachable server is a failure, not an empty label list (text mode too)" \
	"$([ "$rc" -ne 0 ] && [ -z "$out" ] && echo 1 || echo 0)" "rc=$rc out=$out"
out="$(cd "$R" && "$DISP" labels statuses extra --json 2>/dev/null || true)"
check "unexpected arguments → usage" "$(yes jq -e '.error.code == "usage"' <<<"$out")" "$out"
check "capabilities advertise labels-json" "$("$DISP" capabilities --json | jq -e '.capabilities | index("labels-json") != null' >/dev/null && echo 1 || echo 0)"

[ "$fail" -gt 0 ] && summary_colour=$'\033[0;31m' || summary_colour=''
printf '\n%sPassed: %d  Failed: %d\033[0m\n' "$summary_colour" "$pass" "$fail"
[ "$fail" -eq 0 ]
