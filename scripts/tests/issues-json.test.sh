#!/usr/bin/env bash
# shellcheck disable=SC2016  # the single-quoted strings are jq programs; their $-vars are jq's
# `issues list|get|comments --json` (#253): one shape on every backend, finished by
# the dispatcher (status role, signature split, tracker identity), with the
# tab-separated output untouched when --json is absent. The network is a fake
# `curl` that answers each backend's endpoints from canned JSON.
# Contract: flight/references/json-output.md.
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

R="$SANDBOX/repo"; F="$SANDBOX/fixtures"; mkdir -p "$R/.flightdirector" "$F" "$SANDBOX/bin"; git -C "$R" init -q
cat >"$R/.flightdirector/config.json" <<'JSON'
{
  "schemaVersion": 3,
  "code": {"backend":"forgejo","api":"https://fj.example/api/v1","owner":"o","repo":"r","stages":[{"name":"main"}]},
  "issues": {"backend":"requires-newer-flight"},
  "issueTrackers": [
    {"ref":"FJ","name":"Forgejo","default":true,"backend":"forgejo","api":"https://fj.example/api/v1","owner":"o","repo":"r","credentialRef":"code",
     "labels":{"status":{"new":"status/new","in-progress":"status/in progress","to-test":"status/to test","done":false}}},
    {"ref":"GH","name":"GitHub","default":false,"backend":"github","api":"https://gh.example","owner":"o","repo":"r",
     "labels":{"status":{"to-test":"needs-test"}}},
    {"ref":"GL","name":"GitLab","default":false,"backend":"gitlab","api":"https://gl.example/api/v4","owner":"o","repo":"r",
     "labels":{"status":{"to-test":"Testing"}}},
    {"ref":"JIR","name":"Jira","default":false,"backend":"jira","api":"https://jira.example","project":"KAN","email":"bot@example.com",
     "labels":{"status":{"to-test":"status-to-test"}}}
  ]
}
JSON
cat >"$R/.flightdirector/secrets.json" <<'JSON'
{"code":{"token":"t"},"issueTrackers":{"GH":{"token":"t"},"GL":{"token":"t"},"JIR":{"token":"t"}}}
JSON

SIG=$'\n\n---\n🤖 via FlightDirector:flight@0.16.0 with Opus/5.5\n'
# Forgejo: +02:00 offset; X-Total-Count says more exist than the page holds.
jq -n --arg b "Fix the thing.$SIG" '{number:1, title:"FJ one", state:"open",
	labels:[{name:"bug"},{name:"status/to test"}], user:{login:"ana"},
	created_at:"2026-10-01T10:00:00+02:00", updated_at:"2026-10-02T10:00:00+02:00",
	comments:2, html_url:"https://fj.example/o/r/issues/1", body:$b}' >"$F/fj-issue.json"
jq -n '{number:2, title:"FJ two (older, closed, still labelled)", state:"closed",
	labels:[{name:"status/in progress"}], user:{login:"bo"},
	created_at:"2026-09-01T00:00:00Z", updated_at:"2026-09-02T00:00:00Z",
	comments:0, html_url:"https://fj.example/o/r/issues/2", body:"plain"}' >"$F/fj-issue2.json"
jq -s '.' "$F/fj-issue.json" "$F/fj-issue2.json" >"$F/fj-list.json"
jq -n --arg b "A comment.$SIG" '[{id:11, user:{login:"cy"}, created_at:"2026-10-01T12:00:00+00:00",
	updated_at:"2026-10-01T12:30:00+00:00", html_url:"https://fj.example/o/r/issues/1#issuecomment-11", body:$b},
	{id:12, user:{login:"di"}, created_at:"2026-10-01T13:00:00Z", updated_at:"2026-10-01T13:00:00Z",
	html_url:"https://fj.example/o/r/issues/1#issuecomment-12", body:"---\nnot a signature"}]' >"$F/fj-comments.json"
# GitHub: Z timestamps; the list mixes in a pull request, which must be dropped.
jq -n '[{number:5, title:"GH five", state:"open", labels:[{name:"needs-test"}], user:{login:"gh"},
	created_at:"2026-10-01T10:00:00Z", updated_at:"2026-10-01T11:00:00Z", comments:1,
	html_url:"https://github.example/o/r/issues/5", body:"gh body"},
	{number:6, title:"a PR", state:"open", labels:[], user:{login:"gh"}, pull_request:{},
	created_at:"2026-10-01T10:00:00Z", updated_at:"2026-10-01T10:00:00Z", comments:0, html_url:"x", body:""}]' >"$F/gh-list.json"
jq '.[0]' "$F/gh-list.json" >"$F/gh-issue.json"
# GitLab: `opened`, iid, fractional seconds, notes without links, a system note.
jq -n '{iid:7, title:"GL seven", state:"opened", labels:["Testing"], author:{username:"gl"},
	created_at:"2026-10-01T10:00:00.123Z", updated_at:"2026-10-01T10:05:00.000Z", user_notes_count:1,
	web_url:"https://gl.example/o/r/-/issues/7", description:"gl body"}' >"$F/gl-issue.json"
jq -s '.' "$F/gl-issue.json" >"$F/gl-list.json"
jq -n '[{id:70, system:false, author:{username:"gl"}, created_at:"2026-10-01T11:00:00Z", updated_at:"2026-10-01T11:00:00Z", body:"note"},
	{id:71, system:true, author:{username:"gl"}, created_at:"2026-10-01T11:01:00Z", updated_at:"2026-10-01T11:01:00Z", body:"changed the label"}]' >"$F/gl-notes.json"
# Jira: a KEY, -0400 offset, status category, ADF description ending in the signature.
jq -n '{key:"KAN-9", fields:{summary:"Jira nine", labels:["status-to-test"],
	status:{statusCategory:{key:"indeterminate"}}, reporter:{displayName:"Jo"},
	created:"2026-10-01T10:00:00.000-0400", updated:"2026-10-01T11:00:00.000-0400",
	comment:{total:1},
	description:{type:"doc", version:1, content:[
		{type:"paragraph", content:[{type:"text", text:"Jira body"}]},
		{type:"rule"},
		{type:"paragraph", content:[{type:"text", text:"🤖 via FlightDirector:flight@0.16.0 with Fable/5.1"}]}]}}}' >"$F/jira-issue.json"
jq -n --slurpfile i "$F/jira-issue.json" '{issues: $i}' >"$F/jira-search.json"
jq -n '{total:1, comments:[{id:"900", author:{displayName:"Jo"}, created:"2026-10-01T12:00:00.000+0000",
	updated:"2026-10-01T12:00:00.000+0000", body:{type:"doc", version:1, content:[{type:"paragraph", content:[{type:"text", text:"jira note"}]}]}}]}' >"$F/jira-comments.json"

cat >"$SANDBOX/bin/curl" <<'SH'
#!/usr/bin/env bash
out=""; hdr=""; url=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		-D) hdr="$2"; shift 2 ;;
		--data-binary|-w|-X|-H|-u) shift 2 ;;
		-*) shift ;;
		*) url="$1"; shift ;;
	esac
done
F="${FIXTURES:?}"
[ "${FAIL_HOST:-}" = "" ] || case "$url" in *"$FAIL_HOST"*) echo '{"message":"Bad credentials"}' >"$out"; printf 401; exit 0 ;; esac
body=""; total=""
case "$url" in
	*[?\&]page=[2-9]*|*[?\&]page=1[0-9]*) body='[]' ;;   # pages after the first are empty (not per_page=…)
	*fj.example*/issues/1/comments*) body="$(cat "$F/fj-comments.json")" ;;
	*fj.example*/issues/1*)          body="$(cat "$F/fj-issue.json")" ;;
	*fj.example*/issues\?*)          body="$(cat "$F/fj-list.json")"; total=40 ;;
	*gh.example*/issues/5/comments*) body='[{"id":51,"user":{"login":"gh"},"created_at":"2026-10-01T12:00:00Z","updated_at":"2026-10-01T12:00:00Z","html_url":"https://github.example/o/r/issues/5#issuecomment-51","body":"hi"}]' ;;
	*gh.example*/issues/5*)          body="$(cat "$F/gh-issue.json")" ;;
	*gh.example*/issues\?*)          body="$(cat "$F/gh-list.json")" ;;
	*gl.example*/issues/7/notes*)    body="$(cat "$F/gl-notes.json")" ;;
	*gl.example*/issues/7*)          body="$(cat "$F/gl-issue.json")" ;;
	*gl.example*/issues\?*)          body="$(cat "$F/gl-list.json")"; total=1 ;;
	*jira.example*/search/jql*)      body="$(cat "$F/jira-search.json")" ;;
	*jira.example*/issue/KAN-9/comment*) body="$(cat "$F/jira-comments.json")" ;;
	*jira.example*/issue/KAN-9*)     body="$(cat "$F/jira-issue.json")" ;;
	*) echo '{"message":"no fixture"}' >"$out"; printf 404; exit 0 ;;
esac
printf '%s' "$body" >"$out"
if [ -n "$hdr" ]; then
	{ printf 'HTTP/1.1 200 OK\r\n'; [ -z "$total" ] || printf 'X-Total-Count: %s\r\nX-Total: %s\r\n' "$total" "$total"; printf '\r\n'; } >"$hdr"
fi
printf 200
SH
chmod +x "$SANDBOX/bin/curl"
export PATH="$SANDBOX/bin:$PATH" FIXTURES="$F"

fl() { (cd "$R" && "$DISP" "$@"); }
ISSUE_KEYS='["author","body","comments","created","labels","number","qualified","signature","state","status","title","tracker","updated","url"]'
COMMENT_KEYS='["author","body","created","id","signature","updated","url"]'

section "issues get --json: one shape on every backend"
for id in FJ-1 GH-5 GL-7 KAN-9; do
	out="$(fl issues get --number "$id" --json)"
	check "$id: exactly the documented keys" "$(yes jq -e --argjson k "$ISSUE_KEYS" 'keys == $k' <<<"$out")" "$out"
	check "$id: number is a string, state normalized, timestamps UTC Z" \
		"$(yes jq -e '(.number | type == "string") and (.state == "open" or .state == "closed")
			and (.created | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
			and (.updated | test("Z$"))' <<<"$out")" "$out"
done
out="$(fl issues get --number 1 --json)"
check "forgejo: identity, offset converted to UTC, comment count, url" \
	"$(yes jq -e '.number == "1" and .tracker == "FJ" and .qualified == "FJ-1" and .created == "2026-10-01T08:00:00Z"
		and .comments == 2 and .url == "https://fj.example/o/r/issues/1" and .author == "ana"' <<<"$out")" "$out"
check "forgejo: status is the ROLE from the tracker's map" "$(yes jq -e '.status == "to-test" and .labels == ["bug","status/to test"]' <<<"$out")" "$out"
check "forgejo: the signature is split out of the body" \
	"$(yes jq -e '.body == "Fix the thing." and .signature == {plugin:"flight", version:"0.16.0", model:"Opus/5.5"}' <<<"$out")" "$out"
crlf="$(jq -n -c --arg b $'Edited on the web.\r\n\r\n---\r\n🤖 via FlightDirector:flight@0.16.0 with Opus/5.5\r\n' \
	'{body: $b, number: "1", title: "", state: "open", labels: [], author: null, created: null, updated: null, comments: null, url: null}' \
	| jq -c -f "$REPO_ROOT/flight/scripts/issue-json.jq" --arg mode get --arg tracker FJ --argjson labels '{}')"
check "a CRLF body (GitHub web edit) still has its signature split" \
	"$(yes jq -e '.body == "Edited on the web." and .signature.model == "Opus/5.5"' <<<"$crlf")" "$crlf"
out="$(fl issues get --number GL-7 --json)"
check "gitlab: iid, opened → open, fractional seconds dropped, notes count" \
	"$(yes jq -e '.number == "7" and .qualified == "GL-7" and .state == "open" and .created == "2026-10-01T10:00:00Z" and .comments == 1 and .status == "to-test"' <<<"$out")" "$out"
out="$(fl issues get --number GH-5 --json)"
check "github: role through GitHub's own label name, no signature → null" \
	"$(yes jq -e '.status == "to-test" and .signature == null and .body == "gh body"' <<<"$out")" "$out"
out="$(fl issues get --number KAN-9 --json)"
check "jira: native key, REF-qualified, -0400 → UTC, built browse url" \
	"$(yes jq -e '.number == "KAN-9" and .tracker == "JIR" and .qualified == "JIR-9" and .created == "2026-10-01T14:00:00Z"
		and .url == "https://jira.example/browse/KAN-9" and .author == "Jo" and .comments == 1' <<<"$out")" "$out"
check "jira: the signature survives the ADF round trip and is split" \
	"$(yes jq -e '.body == "Jira body" and .signature.model == "Fable/5.1"' <<<"$out")" "$out"
check "a qualified id is accepted as --number (FJ-1 == 1)" \
	"$([ "$(fl issues get --number FJ-1 --json)" = "$(fl issues get --number 1 --json)" ] && echo 1 || echo 0)"

section "issues list --json"
out="$(fl issues list --json --limit 2 2>/dev/null)"
check "list: {issues, truncated, total, errors}" "$(yes jq -e 'keys == ["errors","issues","total","truncated"] and .errors == []' <<<"$out")" "$out"
check "list rows have the issue keys, body and signature null" \
	"$(yes jq -e --argjson k "$ISSUE_KEYS" 'all(.issues[]; keys == $k and .body == null and .signature == null)' <<<"$out")" "$out"
check "list: truncated with the server's total" "$(yes jq -e '.truncated == true and .total == 40' <<<"$out")" "$out"
check "list: newest created first" "$(yes jq -e '[.issues[].number] == ["1","2"]' <<<"$out")" "$out"
check "list: a closed issue keeps its status role" "$(yes jq -e '.issues[1].state == "closed" and .issues[1].status == "in-progress"' <<<"$out")" "$out"
out="$(fl issues list --tracker GH --json 2>/dev/null)"
check "github list: pull requests stay out" "$(yes jq -e '[.issues[].number] == ["5"] and .total == null' <<<"$out")" "$out"
out="$(fl issues list --tracker JIR --json 2>/dev/null)"
check "jira list: no total from the JQL endpoint → null" "$(yes jq -e '.issues[0].number == "KAN-9" and .total == null and .truncated == false' <<<"$out")" "$out"
out="$(fl issues list --tracker GL --status to-test --json 2>/dev/null)"
check "--status ROLE filters by that tracker's own label" "$(yes jq -e '.issues[0].qualified == "GL-7"' <<<"$out")" "$out"
fails_out="$(cd "$R" && "$DISP" issues list --status nope --json 2>/dev/null || true)"
check "an unconfigured --status role is a usage error" "$(yes jq -e '.error.code == "usage"' <<<"$fails_out")" "$fails_out"
fails_out="$(cd "$R" && "$DISP" issues list --status "done" --json 2>/dev/null || true)"
check "a declined (false) role is not a filter" "$(yes jq -e '.error.code == "usage"' <<<"$fails_out")" "$fails_out"

section "issues comments --json"
for id in FJ-1 GH-5 GL-7 KAN-9; do
	out="$(fl issues comments --number "$id" --json)"
	check "$id: an array of comments with exactly the documented keys" \
		"$(yes jq -e --argjson k "$COMMENT_KEYS" 'type == "array" and length >= 1 and all(.[]; keys == $k and (.id | type == "string"))' <<<"$out")" "$out"
done
out="$(fl issues comments --number 1 --json)"
check "comments: signature split per comment; a bare --- in text is left alone" \
	"$(yes jq -e '.[0].body == "A comment." and .[0].signature.version == "0.16.0" and .[1].body == "---\nnot a signature" and .[1].signature == null' <<<"$out")" "$out"
out="$(fl issues comments --number GL-7 --json)"
check "gitlab: system notes dropped, note url built from the issue's web url" \
	"$(yes jq -e 'length == 1 and .[0].url == "https://gl.example/o/r/-/issues/7#note_70"' <<<"$out")" "$out"
out="$(fl issues comments --number KAN-9 --json)"
check "jira: comment url focuses the comment" "$(yes jq -e '.[0].url == "https://jira.example/browse/KAN-9?focusedCommentId=900" and .[0].body == "jira note"' <<<"$out")" "$out"

section "--all-trackers --json"
out="$(fl issues list --all-trackers --json 2>/dev/null)"
check "every tracker's issues, newest first, each with its tracker" \
	"$(yes jq -e '([.issues[].qualified] | sort) == (["FJ-1","FJ-2","GH-5","GL-7","JIR-9"] | sort) and .errors == [] and all(.issues[]; .tracker != null)' <<<"$out")" "$out"
check "aggregate: truncated if any tracker was; total null unless every tracker had one" \
	"$(yes jq -e '.truncated == false and .total == null' <<<"$out")" "$out"
out="$(cd "$R" && FAIL_HOST=gh.example "$DISP" issues list --all-trackers --json 2>"$SANDBOX/err")"; rc=$?
check "a failing tracker is reported in errors, the rest still listed, exit 0" \
	"$(yes jq -e '(.errors | length) == 1 and .errors[0].tracker == "GH" and .errors[0].code == "auth" and (.issues | length) == 4' <<<"$out")" "$out"
check "…and total is null, since a partial sum would look complete" "$(yes jq -e '.total == null' <<<"$out")" "$out"
check "…and named on stderr" "$(grep -q 'tracker GH unavailable' "$SANDBOX/err" && echo 1 || echo 0)" "$(cat "$SANDBOX/err")"
check "…with exit status 0" "$([ "$rc" = 0 ] && echo 1 || echo 0)"
out="$(cd "$R" && FAIL_HOST=example "$DISP" issues list --all-trackers --json 2>/dev/null || true)"
check "when every tracker fails, the first failure is the envelope" "$(yes jq -e 'keys == ["error"] and .error.code == "auth"' <<<"$out")" "$out"

section "text output is unchanged"
check "issues list (no --json) is TSV" "$([ "$(fl issues list 2>/dev/null | head -n1)" = "$(printf '1\tFJ one\tbug,status/to test')" ] && echo 1 || echo 0)"
check "issues get (no --json) is the header line + body" "$([ "$(fl issues get --number 1 | head -n1)" = "$(printf '1\tFJ one\topen')" ] && echo 1 || echo 0)"
check "capabilities advertise issues-json" "$("$DISP" capabilities --json | jq -e '.capabilities | index("issues-json") != null' >/dev/null && echo 1 || echo 0)"

[ "$fail" -gt 0 ] && summary_colour=$'\033[0;31m' || summary_colour=''
printf '\n%sPassed: %d  Failed: %d\033[0m\n' "$summary_colour" "$pass" "$fail"
[ "$fail" -eq 0 ]
