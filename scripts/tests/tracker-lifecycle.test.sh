#!/usr/bin/env bash
# End-to-end acceptance for #198: an issue's tracker identity survives the whole work
# lifecycle. Walks the steps the workflow skills take — resolve once, branch + worktree,
# retain, change the default tracker mid-work, resume from the branch, write (comment,
# status, model label, close), batch-manifest and branch discovery, the promotion PR line —
# through the REAL dispatcher and scripts. The network is a fake `curl` that logs every
# call, so the test can prove which tracker each write reached.
set -euo pipefail

unset LS_TOKEN FLIGHT_TOKEN FORGEJO_TOKEN LS_SECRETS_FILE LS_EMAIL FLIGHT_SELF FLIGHT_REPO_ROOT BATCH_MANIFEST_ROOT
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DISP="$REPO_ROOT/flight/scripts/flight"
IDENTITY="$REPO_ROOT/flight/scripts/issue-identity.sh"
BM="$REPO_ROOT/flight/scripts/batch-manifest"

pass=0; fail=0
check() { if [ "$2" = 1 ]; then printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass+1));
			else printf '\033[0;31m  ✗ %s\033[0m\n  %s\n' "$1" "${3:-}"; fail=$((fail+1)); fi; }
section() { printf '\033[1m── %s ──\033[0m\n' "$1"; }

SANDBOX="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$SANDBOX"' EXIT
R="$SANDBOX/repo"; mkdir -p "$SANDBOX/bin"
git init -q -b develop "$R"
git -C "$R" config user.email t@t; git -C "$R" config user.name t; git -C "$R" config commit.gpgsign false
printf 'base\n' >"$R/base"; git -C "$R" add base; git -C "$R" commit -qm base
mkdir -p "$R/.flightdirector"
CFG="$R/.flightdirector/config.json"

# FJ is the code repository's own issue tracker and the starting default (it configures a
# `new` starting status); GH is a public GitHub tracker whose numbers overlap FJ's (it
# declined `new`); JIR is a Jira project whose native key (PROJ) differs from its ref.
cat >"$CFG" <<'JSON'
{
  "schemaVersion": 3,
  "code": {"backend":"forgejo","api":"https://code.example.com/api/v1","owner":"acme","repo":"widget",
           "stages":[{"name":"develop","issueStatus":"to-test","closesIssues":false},{"name":"main","closesIssues":true}]},
  "issues": {"backend":"requires-newer-flight"},
  "issueTrackers": [
    {"ref":"FJ","name":"Code issues","default":true,"backend":"forgejo","api":"https://code.example.com/api/v1","owner":"acme","repo":"widget","credentialRef":"code",
     "labels":{"status":{"new":"fj/new","in-progress":"fj/progress","to-test":"fj/test"}}},
    {"ref":"GH","name":"Public issues","backend":"github","api":"https://api.github.com","owner":"acme","repo":"widget",
     "labels":{"status":{"new":false,"in-progress":"gh-progress","to-test":"gh-test"}}},
    {"ref":"JIR","name":"Jira","backend":"jira","api":"https://jira.example.com","project":"PROJ","email":"bot@example.com",
     "labels":{"status":{"in-progress":"jir-progress","to-test":"jir-test"}}}
  ]
}
JSON
cp "$CFG" "$SANDBOX/config.good"
printf '%s\n' '{"code":{"token":"code-token"},"issueTrackers":{"GH":{"token":"gh-token"},"JIR":{"token":"jira-token"}}}' >"$R/.flightdirector/secrets.json"
printf '.flightdirector/secrets.json\n.flightdirector/batches/\n.worktrees/\n' >"$R/.gitignore"

cat >"$SANDBOX/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=""; url=""; method=GET; data=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		-D) printf 'x-total-count: 1\r\n' >"$2"; shift 2 ;;
		-w|-H|-u) shift 2 ;;
		-X) method="$2"; shift 2 ;;
		--data-binary|-d|--data) data="$2"; shift 2 ;;
		-*) shift ;;
		*) url="$1"; shift ;;
	esac
done
printf '%s\t%s\t%s\n' "$method" "$url" "$data" >>"${CURL_LOG:?}"
body='{}'
case "$url" in
	*/labels*page=1*) body='[{"id":31,"name":"fj/new","color":"fff","description":""},{"id":32,"name":"fj/progress","color":"fff","description":""},{"id":33,"name":"fj/test","color":"fff","description":""},{"id":34,"name":"model/opus","color":"d97757","description":""}]' ;;
	*/labels*) body='[]' ;;
	*/transitions*) body='{"transitions":[{"id":"41","to":{"statusCategory":{"key":"done"}}}]}' ;;
	*/rest/api/3/issue/*) body='{"key":"PROJ-7","fields":{"labels":[]}}' ;;
	*/issues/*/labels*) body='[]' ;;
	*/issues/*) body='{"number":1,"title":"Selected","body":"","state":"open","labels":[]}' ;;
	*/issues*) [ "$method" = POST ] && body='{"number":5,"html_url":"https://example.com/5"}' || body='[]' ;;
esac
if [ -n "$out" ]; then printf '%s' "$body" >"$out"; else printf '%s' "$body"; fi
printf '200'
SH
chmod +x "$SANDBOX/bin/curl"
export PATH="$SANDBOX/bin:$PATH" CURL_LOG="$SANDBOX/curl.log"

flight() { (cd "$R" && "$DISP" "$@"); }
ident() { (cd "$R" && "$IDENTITY" "$@"); }
log() { cat "$CURL_LOG"; }
only_host() { # only_host <host> — every logged call went to that host
	# Request lines only: a logged JSON payload spans several lines.
	local urls; urls="$(grep -E '^(GET|POST|PUT|PATCH|DELETE)	' "$CURL_LOG" | cut -f2 || true)"
	[ -n "$urls" ] && ! grep -vq "^https://$1/" <<<"$urls" && echo 1 || echo 0
}

section "start two issues numbered 1 on different trackers"
FJ1="$(flight issues resolve --number 1)"            # a bare number: the current default
GH1="$(flight issues resolve --number GH-1)"
check "a bare 1 resolves to the default tracker, GH-1 to GitHub" \
	"$([ "$(jq -r .qualified <<<"$FJ1")" = FJ-1 ] && [ "$(jq -r .qualified <<<"$GH1")" = GH-1 ] && echo 1 || echo 0)" "$FJ1 $GH1"
for id in "$FJ1" "$GH1"; do
	prefix="$(jq -r .branchPrefix <<<"$id")"
	git -C "$R" worktree add -q -b "feature/$prefix-widget" ".worktrees/$prefix-widget" develop
	ident remember --branch "feature/$prefix-widget" --identity "$id"
done
check "their branches and worktrees do not collide" \
	"$([ -d "$R/.worktrees/fj-1-widget" ] && [ -d "$R/.worktrees/gh-1-widget" ] \
		&& git -C "$R" rev-parse -q --verify feature/fj-1-widget >/dev/null && git -C "$R" rev-parse -q --verify feature/gh-1-widget >/dev/null && echo 1 || echo 0)"
(cd "$R" && "$BM" write --run-id RUN --zone core --issues "FJ-1 GH-1")

section "the default changes mid-work"
jq '.issueTrackers |= map(.default = (.ref == "GH"))' "$SANDBOX/config.good" >"$CFG"
check "a bare 1 would now mean GH-1 — which is why nothing re-resolves it" \
	"$([ "$(flight issues resolve --number 1 | jq -r .qualified)" = GH-1 ] && echo 1 || echo 0)"
ISSUE="$(ident from-branch --branch feature/fj-1-widget)"
TRACKER="$(jq -r .tracker <<<"$ISSUE")"; NUMBER="$(jq -r .number <<<"$ISSUE")"
check "resuming from the branch recovers the original tracker" "$([ "$TRACKER/$NUMBER" = FJ/1 ] && echo 1 || echo 0)" "$ISSUE"

: >"$CURL_LOG"
flight issues comment --tracker "$TRACKER" --number "$NUMBER" --body "work ledger" --no-signature >/dev/null
flight issues set-status --tracker "$TRACKER" --number "$NUMBER" --status to-test >/dev/null
flight labels ensure --tracker "$TRACKER" --model claude-opus-5 >/dev/null
flight issues label-add --tracker "$TRACKER" --number "$NUMBER" --label model/opus >/dev/null
check "ledger, status and model label all reach the original tracker, none GitHub" "$(only_host code.example.com)" "$(log)"
check "the status role maps through the original tracker's labels" \
	"$(grep -q 'repos/acme/widget/issues/1/labels' "$CURL_LOG" && grep -q '33' "$CURL_LOG" && echo 1 || echo 0)" "$(log)"

section "promotion"
GH_OUT="$(ident pr-reference --identity "$GH1" --closes true)"
FJ_OUT="$(ident pr-reference --identity "$ISSUE" --closes true)"
check "the code repository's own issue gets its closing keyword" "$([ "$FJ_OUT" = 'Closes #1' ] && echo 1 || echo 0)" "$FJ_OUT"
check "the cross-tracker GH-1 can never close the code repository's issue 1" "$([ "$GH_OUT" = 'Tracks GH-1' ] && echo 1 || echo 0)" "$GH_OUT"
: >"$CURL_LOG"
GH_ISSUE="$(ident from-branch --branch feature/gh-1-widget)"
flight issues set-status --tracker "$(jq -r .tracker <<<"$GH_ISSUE")" --number "$(jq -r .number <<<"$GH_ISSUE")" --status to-test >/dev/null 2>&1 || true
flight issues close --tracker "$(jq -r .tracker <<<"$GH_ISSUE")" --number "$(jq -r .number <<<"$GH_ISSUE")" >/dev/null 2>&1 || true
check "promotion drives GH-1 on GitHub explicitly, never the code forge" "$(only_host api.github.com)" "$(log)"
out="$(cd "$R" && "$BM" groups)"
check "the batch manifest still holds both issues after the default change" \
	"$([ "$out" = "$(printf 'core\tFJ-1,GH-1')" ] && echo 1 || echo 0)" "$out"
for b in feature/fj-1-widget feature/gh-1-widget; do
	wt="$R/.worktrees/${b#feature/}"
	printf '%s\n' "$b" >"$wt/change-${b#feature/}"
	git -C "$wt" add "change-${b#feature/}"; git -C "$wt" commit -qm "feat($(ident from-branch --branch "$b" | jq -r .qualified)): change"
	git -C "$R" merge -q --no-ff -m "Merge $b into develop" "$b"
done
out="$(flight branches list --no-fetch 2>/dev/null)"
check "cleanup discovery reports each merged branch's own tracker" \
	"$(grep -q $'^feature/fj-1-widget\tlocal\tdevelop\t-\tFJ-1\t' <<<"$out" && grep -q $'^feature/gh-1-widget\tlocal\tdevelop\t-\tGH-1\t' <<<"$out" && echo 1 || echo 0)" "$out"
out="$(ident from-history --ref "$(git -C "$R" log -1 --format=%s feature/fj-1-widget | sed -E 's/^feat\(([^)]*)\).*/\1/')")"
check "a stage hop recovers the issue from the qualified commit subject" "$([ "$(jq -r .qualified <<<"$out")" = FJ-1 ] && echo 1 || echo 0)" "$out"

section "per-tracker starting and terminal statuses (Jira native ids)"
: >"$CURL_LOG"
flight issues create --tracker FJ --title T --body B --no-signature >/dev/null
check "a new issue on FJ gets FJ's own starting status" "$(grep -q '^POST	https://code.example.com/api/v1/repos/acme/widget/issues	' "$CURL_LOG" && tr -d ' \n' <"$CURL_LOG" | grep -q '"labels":\[31\]' && echo 1 || echo 0)" "$(log)"
: >"$CURL_LOG"
flight issues create --tracker GH --title T --body B --no-signature >/dev/null 2>&1 || true
check "a new issue on GH (new declined) gets no starting status, least of all FJ's" \
	"$(grep -q 'api.github.com/repos/acme/widget/issues' "$CURL_LOG" && ! grep -q 'fj/new' "$CURL_LOG" && ! grep -q 'code.example.com' "$CURL_LOG" && echo 1 || echo 0)" "$(log)"
JIRA="$(flight issues resolve --number JIR-7)"
: >"$CURL_LOG"
flight issues set-status --tracker "$(jq -r .tracker <<<"$JIRA")" --number "$(jq -r .number <<<"$JIRA")" --status to-test >/dev/null
check "a Jira status change uses the native key and JIR's own label" \
	"$(grep -q '^PUT	https://jira.example.com/rest/api/3/issue/PROJ-7	' "$CURL_LOG" && grep -q '"add": "jir-test"' "$CURL_LOG" && echo 1 || echo 0)" "$(log)"
: >"$CURL_LOG"
flight issues close --tracker "$(jq -r .tracker <<<"$JIRA")" --number "$(jq -r .number <<<"$JIRA")" >/dev/null
check "closing a Jira issue transitions the native key on Jira only" \
	"$(grep -q 'POST	https://jira.example.com/rest/api/3/issue/PROJ-7/transitions' "$CURL_LOG" && [ "$(only_host jira.example.com)" = 1 ] && echo 1 || echo 0)" "$(log)"

[ "$fail" -gt 0 ] && colour=$'\033[0;31m' || colour=''
printf '\n%sPassed: %d  Failed: %d\033[0m\n' "$colour" "$pass" "$fail"
[ "$fail" -eq 0 ]
