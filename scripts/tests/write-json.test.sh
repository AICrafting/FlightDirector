#!/usr/bin/env bash
# shellcheck disable=SC2016  # the single-quoted strings are jq programs; their $-vars are jq's
# `issues create|comment|set-status --json` (#252): a write answers with what it
# made or changed, in the same shapes the read verbs use, and a create that succeeded
# never reports failure just because reading the new issue back did. The network is
# a fake `curl`. Contract: flight/references/json-output.md.
set -euo pipefail

unset LS_TOKEN FLIGHT_TOKEN FORGEJO_TOKEN LS_SECRETS_FILE LS_EMAIL FLIGHT_ERROR_FILE LS_JSON FLIGHT_MODEL LS_MODEL
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
     "labels":{"status":{"in-progress":"status/in progress","to-test":"status/to test"}}},
    {"ref":"GH","name":"GitHub","default":false,"backend":"github","api":"https://gh.example","owner":"o","repo":"r","labels":{}},
    {"ref":"GL","name":"GitLab","default":false,"backend":"gitlab","api":"https://gl.example/api/v4","owner":"o","repo":"r","labels":{}},
    {"ref":"JIR","name":"Jira","default":false,"backend":"jira","api":"https://jira.example","project":"KAN","email":"b@e.x","labels":{}}
  ]
}
JSON
echo '{"code":{"token":"t"},"issueTrackers":{"GH":{"token":"t"},"GL":{"token":"t"},"JIR":{"token":"t"}}}' >"$R/.flightdirector/secrets.json"

# The fake echoes a POSTed comment body back, so the signature the dispatcher added
# can be seen split out again. GET_FAILS makes single-issue reads fail (500).
cat >"$SANDBOX/bin/curl" <<'SH'
#!/usr/bin/env bash
out=""; url=""; method=GET; data=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		-X) method="$2"; shift 2 ;;
		--data-binary) data="$2"; shift 2 ;;
		-D|-w|-H|-u) shift 2 ;;
		-*) shift ;;
		*) url="$1"; shift ;;
	esac
done
printf '%s %s\n' "$method" "$url" >>"${CURL_LOG:?}"
code=200
case "$method $url" in
	*[?\&]page=[2-9]*) body='[]' ;;
	"GET "*fj.example*/labels*) body='[{"id":1,"name":"status/in progress","color":"1f9d55"},{"id":2,"name":"status/to test","color":"e3a008"}]' ;;
	"POST "*fj.example*/issues/12/comments|"POST "*gh.example*/issues/5/comments)
		body="$(jq -c --argjson d "$data" -n '{id: 77, user: {login: "bot"}, created_at: "2026-10-02T10:00:00+00:00",
			updated_at: "2026-10-02T10:00:00+00:00", html_url: "https://x.example/c/77", body: $d.body}')" ;;
	"POST "*gl.example*/issues/7/notes)
		body="$(jq -c --argjson d "$data" -n '{id: 70, author: {username: "bot"}, created_at: "2026-10-02T10:00:00Z",
			updated_at: "2026-10-02T10:00:00Z", body: $d.body}')" ;;
	"GET "*gl.example*/issues/7)
		if [ -n "${GL_GET_FAILS:-}" ]; then body='{"message":"boom"}'; code=500
		else body='{"iid":7,"web_url":"https://gl.example/o/r/-/issues/7"}'; fi ;;
	"POST "*jira.example*/issue/KAN-9/comment)
		body='{"id":"900","author":{"displayName":"Bot"},"created":"2026-10-02T10:00:00.000+0000","updated":"2026-10-02T10:00:00.000+0000",
			"body":{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"from jira"}]}]}}' ;;
	"POST "*fj.example*/issues/12/labels|"DELETE "*fj.example*/issues/12/labels/*) body='[]' ;;
	"POST "*fj.example*/issues) body='{"number":12}' ;;
	"GET "*fj.example*/issues/12)
		if [ -n "${GET_FAILS:-}" ]; then body='{"message":"boom"}'; code=500
		else body='{"number":12,"title":"Filed from a panel","state":"open","labels":[{"name":"status/in progress"}],
			"user":{"login":"bot"},"created_at":"2026-10-02T10:00:00Z","updated_at":"2026-10-02T10:00:00Z","comments":0,
			"html_url":"https://fj.example/o/r/issues/12","body":"Body.\n\n---\n🤖 via FlightDirector:flight@0.16.0"}'; fi ;;
	*) body='{"message":"no fixture"}'; code=404 ;;
esac
printf '%s' "$body" >"$out"
printf '%s' "$code"
SH
chmod +x "$SANDBOX/bin/curl"
export PATH="$SANDBOX/bin:$PATH" CURL_LOG="$SANDBOX/curl.log"
fl() { (cd "$R" && "$DISP" "$@"); }
ISSUE_KEYS='["author","blocked_by","body","comments","created","labels","number","qualified","signature","state","status","title","tracker","updated","url"]'
COMMENT_KEYS='["author","body","created","id","signature","updated","url"]'

section "issues create --json"
out="$(fl issues create --title "Filed from a panel" --body "Body." --json)"
check "answers with the new issue, in the issues get --json shape" \
	"$(yes jq -e --argjson k "$ISSUE_KEYS" 'keys == $k and .number == "12" and .qualified == "FJ-12" and .status == "in-progress"' <<<"$out")" "$out"
check "the read-back's signature is split as usual" "$(yes jq -e '.body == "Body." and .signature.version == "0.16.0"' <<<"$out")" "$out"
out="$(cd "$R" && GET_FAILS=1 "$DISP" issues create --title "Filed from a panel" --body "Body." --json 2>"$SANDBOX/err")"; rc=$?
check "a failed read-back still reports the created issue, exit 0 (no duplicate re-file)" \
	"$([ "$rc" = 0 ] && jq -e --argjson k "$ISSUE_KEYS" 'keys == $k and .number == "12" and .title == "Filed from a panel" and .qualified == "FJ-12"' <<<"$out" >/dev/null && echo 1 || echo 0)" "$out"
check "…unknown fields null, labels still an array" "$(yes jq -e '.comments == null and .url == null and .labels == []' <<<"$out")" "$out"
check "…and says so on stderr" "$(grep -q 'created #12 but could not read it back' "$SANDBOX/err" && echo 1 || echo 0)" "$(cat "$SANDBOX/err")"
check "without --json, create still prints just the number" "$([ "$(fl issues create --title t --body b)" = 12 ] && echo 1 || echo 0)"

section "issues comment --json"
out="$(fl issues comment --number 12 --body "Looks good." --model claude-opus-5-5 --json)"
check "forgejo: the new comment, in the comments --json shape" \
	"$(yes jq -e --argjson k "$COMMENT_KEYS" 'keys == $k and .id == "77" and .author == "bot" and .created == "2026-10-02T10:00:00Z"' <<<"$out")" "$out"
check "the signature the dispatcher appended comes back split out" \
	"$(yes jq -e '.body == "Looks good." and .signature == {plugin: "flight", version: (.signature.version), model: "Opus/5.5"}' <<<"$out")" "$out"
out="$(fl issues comment --number GH-5 --body "hi" --no-signature --json)"
check "github: same shape" "$(yes jq -e --argjson k "$COMMENT_KEYS" 'keys == $k and .body == "hi" and .signature == null' <<<"$out")" "$out"
out="$(fl issues comment --number GL-7 --body "hi" --no-signature --json)"
check "gitlab: same shape, url built from the issue" \
	"$(yes jq -e --argjson k "$COMMENT_KEYS" 'keys == $k and .url == "https://gl.example/o/r/-/issues/7#note_70"' <<<"$out")" "$out"
out="$(fl issues comment --number KAN-9 --body "hi" --no-signature --json)"
check "jira: same shape, focused comment url" \
	"$(yes jq -e --argjson k "$COMMENT_KEYS" 'keys == $k and .id == "900" and .url == "https://jira.example/browse/KAN-9?focusedCommentId=900" and .body == "from jira"' <<<"$out")" "$out"
: >"$CURL_LOG"
out="$(cd "$R" && GL_GET_FAILS=1 "$DISP" issues comment --number GL-7 --body "hi" --no-signature --json 2>/dev/null || true)"
check "gitlab: a failing issue read stops the comment BEFORE it is posted (no double post on retry)" \
	"$([ "$(jq -r '.error.code' <<<"$out")" = backend ] && ! grep -q 'POST .*gl.example.*/notes' "$CURL_LOG" && echo 1 || echo 0)" "$out $(cat "$CURL_LOG")"
check "without --json, comment prints nothing" "$([ -z "$(fl issues comment --number 12 --body x)" ] && echo 1 || echo 0)"

section "issues set-status --json"
out="$(fl issues set-status --number FJ-12 --status to-test --json)"
check "echoes the new status: number, tracker, qualified, role, label" \
	"$(yes jq -e '. == {number: "12", tracker: "FJ", qualified: "FJ-12", status: "to-test", label: "status/to test"}' <<<"$out")" "$out"
check "the label really was applied" "$(grep -q 'POST .*fj.example.*/issues/12/labels' "$CURL_LOG" && echo 1 || echo 0)"
out="$(cd "$R" && "$DISP" issues set-status --number 12 --status nope --json 2>/dev/null || true)"
check "an unconfigured role is an error envelope, not an echo" "$(yes jq -e 'keys == ["error"] and .error.code == "usage"' <<<"$out")" "$out"
check "without --json, set-status prints nothing" "$([ -z "$(fl issues set-status --number 12 --status to-test)" ] && echo 1 || echo 0)"
check "capabilities advertise write-json" "$("$DISP" capabilities --json | jq -e '.capabilities | index("write-json") != null' >/dev/null && echo 1 || echo 0)"

[ "$fail" -gt 0 ] && summary_colour=$'\033[0;31m' || summary_colour=''
printf '\n%sPassed: %d  Failed: %d\033[0m\n' "$summary_colour" "$pass" "$fail"
[ "$fail" -eq 0 ]
