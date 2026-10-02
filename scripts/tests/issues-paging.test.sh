#!/usr/bin/env bash
# shellcheck disable=SC2016  # the single-quoted strings are jq programs; their $-vars are jq's
# `issues list --json --per-page M [--cursor C]` (#262): one page per call on every
# backend, newest created first, with an opaque cursor that neither repeats nor skips a
# row when issues are filed or closed between loads. The network is a fake `curl` that
# serves each backend's list endpoint from one mutable issue store.
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

R="$SANDBOX/repo"; mkdir -p "$R/.flightdirector" "$SANDBOX/bin"; git -C "$R" init -q
cat >"$R/.flightdirector/config.json" <<'JSON'
{
  "schemaVersion": 3,
  "code": {"backend":"forgejo","api":"https://fj.example/api/v1","owner":"o","repo":"r","stages":[{"name":"main"}]},
  "issues": {"backend":"requires-newer-flight"},
  "issueTrackers": [
    {"ref":"FJ","name":"Forgejo","default":true,"backend":"forgejo","api":"https://fj.example/api/v1","owner":"o","repo":"r","credentialRef":"code","labels":{}},
    {"ref":"GH","name":"GitHub","default":false,"backend":"github","api":"https://gh.example","owner":"o","repo":"r","labels":{}},
    {"ref":"GL","name":"GitLab","default":false,"backend":"gitlab","api":"https://gl.example/api/v4","owner":"o","repo":"r","labels":{}},
    {"ref":"JIR","name":"Jira","default":false,"backend":"jira","api":"https://jira.example","project":"KAN","email":"b@e.x","labels":{}}
  ]
}
JSON
echo '{"code":{"token":"t"},"issueTrackers":{"GH":{"token":"t"},"GL":{"token":"t"},"JIR":{"token":"t"}}}' >"$R/.flightdirector/secrets.json"

# The store: newest first. `pr` rows are pull requests (GitHub's /issues mixes them in;
# the other backends never return them). 7 and 6 share a created second (tie → number).
DB="$SANDBOX/db.json"
seed() {
	jq -n '[
		{n: 10, c: "2026-10-02T10:00:00Z"}, {n: 9, c: "2026-10-02T09:00:00Z", pr: true},
		{n: 8, c: "2026-10-02T08:00:00Z"}, {n: 7, c: "2026-10-02T07:00:00Z"},
		{n: 6, c: "2026-10-02T07:00:00Z"}, {n: 5, c: "2026-10-02T05:00:00Z", pr: true},
		{n: 4, c: "2026-10-02T04:00:00Z"}, {n: 3, c: "2026-10-02T03:00:00Z"},
		{n: 2, c: "2026-10-02T02:00:00Z"}, {n: 1, c: "2026-10-02T01:00:00Z"}]' >"$DB"
}
seed

cat >"$SANDBOX/bin/curl" <<'SH'
#!/usr/bin/env bash
out=""; hdr=""; url=""; data=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		-D) hdr="$2"; shift 2 ;;
		--data-binary) data="$2"; shift 2 ;;
		-w|-X|-H|-u) shift 2 ;;
		-*) shift ;;
		*) url="$1"; shift ;;
	esac
done
printf '%s\n' "$url" >>"${CURL_LOG:?}"
param() { printf '%s' "$url" | sed -n -E "s/.*[?&]$1=([0-9]+).*/\1/p"; }
total=""
case "$url" in
	*jira.example*/search/jql)
		size="$(jq -r '.maxResults' <<<"$data")"; tok="$(jq -r '.nextPageToken // "off:0"' <<<"$data")"; off="${tok#off:}"
		body="$(jq -c --argjson o "$off" --argjson s "$size" '[.[] | select(.pr | not)] as $all
			| {issues: [$all[$o:$o + $s][] | {key: "KAN-\(.n)", fields: {summary: "Issue \(.n)", labels: [],
				status: {name: "To Do", statusCategory: {key: "new"}},
				created: (.c | sub("Z$"; ".000+0000")), updated: (.c | sub("Z$"; ".000+0000")), reporter: {displayName: "bot"}}}]}
			+ (if ($o + $s) < ($all | length) then {nextPageToken: "off:\($o + $s)"} else {} end)' "$DB")" ;;
	*fj.example*/issues*)
		size="$(param limit)"; page="$(param page)"
		body="$(jq -c --argjson p "$page" --argjson s "$size" '[.[] | select(.pr | not)] | .[($p - 1) * $s:$p * $s]
			| map({number: .n, title: "Issue \(.n)", state: "open", labels: [], user: {login: "bot"},
				created_at: .c, updated_at: .c, comments: 0, html_url: "https://fj.example/o/r/issues/\(.n)", body: ""})' "$DB")"
		total="$(jq '[.[] | select(.pr | not)] | length' "$DB")" ;;
	*gh.example*/issues*)
		size="$(param per_page)"; page="$(param page)"
		body="$(jq -c --argjson p "$page" --argjson s "$size" '.[($p - 1) * $s:$p * $s]
			| map({number: .n, title: "Issue \(.n)", state: "open", labels: [], user: {login: "bot"},
				created_at: .c, updated_at: .c, comments: 0, html_url: "https://gh.example/o/r/issues/\(.n)", body: ""}
				+ (if .pr then {pull_request: {}} else {} end))' "$DB")" ;;
	*gl.example*/issues*)
		size="$(param per_page)"; page="$(param page)"
		body="$(jq -c --argjson p "$page" --argjson s "$size" '[.[] | select(.pr | not)] | .[($p - 1) * $s:$p * $s]
			| map({iid: .n, title: "Issue \(.n)", state: "opened", labels: [], author: {username: "bot"},
				created_at: .c, updated_at: .c, user_notes_count: 0, web_url: "https://gl.example/o/r/-/issues/\(.n)", description: ""})' "$DB")"
		total="$(jq '[.[] | select(.pr | not)] | length' "$DB")" ;;
	*) body='{"message":"no fixture"}'; printf '%s' "$body" >"$out"; printf 404; exit 0 ;;
esac
if [ -n "$hdr" ]; then
	{ printf 'HTTP/1.1 200 OK\r\n'; [ -z "$total" ] || printf 'X-Total-Count: %s\r\nX-Total: %s\r\n' "$total" "$total"; printf '\r\n'; } >"$hdr"
fi
printf '%s' "$body" >"$out"
printf 200
SH
chmod +x "$SANDBOX/bin/curl"
export PATH="$SANDBOX/bin:$PATH" CURL_LOG="$SANDBOX/curl.log" DB
fl() { (cd "$R" && "$DISP" "$@"); }
num() { jq -r '.issues | map(.number | split("-") | last) | join(" ")' <<<"$1"; }

# walk TRACKER PER — every page in turn; prints "<numbers>|<pages>|<last next>".
walk() {
	local t="$1" per="$2" cur="" all="" pages=0 o
	while :; do
		if [ -n "$cur" ]; then o="$(fl issues list --tracker "$t" --state all --json --per-page "$per" --cursor "$cur")"
		else o="$(fl issues list --tracker "$t" --state all --json --per-page "$per")"; fi
		pages=$((pages + 1)); all="$all $(num "$o")"
		cur="$(jq -r '.next // empty' <<<"$o")"
		[ -n "$cur" ] && [ "$pages" -lt 20 ] || break
	done
	printf '%s|%s\n' "$(tr -s ' ' <<<"$all" | sed -e 's/^ //' -e 's/ $//')" "$pages"
}

section "walking every page"
want="10 8 7 6 4 3 2 1"
for t in FJ GH GL JIR; do
	got="$(walk "$t" 3)"
	check "$t: pages of 3 cover every issue once, newest first (ties by number)" "$([ "${got%|*}" = "$want" ] && echo 1 || echo 0)" "$got"
done
got="$(walk GH 2)"
check "GitHub: pull requests never count toward a page" "$([ "${got%|*}" = "$want" ] && [ "${got#*|}" = 4 ] && echo 1 || echo 0)" "$got"

section "the page object"
o="$(fl issues list --json --per-page 3)"
check "first page: issues, truncated, total, next" \
	"$(yes jq -e '(.issues | length) == 3 and .truncated == true and .total == 8 and (.next | type) == "string" and .errors == []' <<<"$o")" "$o"
check "issues are the list shape (body omitted, tracker identity filled)" \
	"$(yes jq -e '.issues[0] | .number == "10" and .qualified == "FJ-10" and .body == null' <<<"$o")" "$o"
o="$(fl issues list --json --per-page 8)"
check "a page that reaches the end says next = null, truncated false" "$(yes jq -e '.next == null and .truncated == false and (.issues | length) == 8' <<<"$o")" "$o"
o="$(fl issues list --tracker JIR --json --per-page 3)"
check "Jira reports no total" "$(yes jq -e '.total == null and (.next | type) == "string"' <<<"$o")" "$o"
o="$(fl issues list --json --limit 3)"
check "without paging flags, list --json has no next field (unchanged)" "$(yes jq -e 'has("next") | not' <<<"$o")" "$o"

section "results that move between loads"
for t in FJ GH GL JIR; do
	seed
	o="$(fl issues list --tracker "$t" --state all --json --per-page 3)"; c="$(jq -r .next <<<"$o")"
	jq '[{n: 11, c: "2026-10-02T11:00:00Z"}] + .' "$DB" >"$DB.tmp" && mv "$DB.tmp" "$DB"
	o="$(fl issues list --tracker "$t" --state all --json --per-page 3 --cursor "$c")"
	check "$t: an issue filed between loads doesn't repeat a row" "$([ "$(num "$o")" = "6 4 3" ] && echo 1 || echo 0)" "$(num "$o")"
done
for t in FJ GH GL; do
	seed
	o="$(fl issues list --tracker "$t" --state all --json --per-page 3)"; c="$(jq -r .next <<<"$o")"
	o="$(fl issues list --tracker "$t" --state all --json --per-page 3 --cursor "$c")"; c="$(jq -r .next <<<"$o")"
	# Four rows above the cursor go: issue 2 moves up a whole server page, behind where
	# the cursor's page now starts. A page-number cursor alone would skip it.
	jq 'map(select(.n | IN(10, 8, 7, 6) | not))' "$DB" >"$DB.tmp" && mv "$DB.tmp" "$DB"
	o="$(fl issues list --tracker "$t" --state all --json --per-page 3 --cursor "$c")"
	check "$t: issues that left the list between loads don't make a row get skipped" "$([ "$(num "$o")" = "2 1" ] && echo 1 || echo 0)" "$(num "$o")"
done
seed

section "usage"
err() { local o; o="$(cd "$R" && "$DISP" "$@" 2>/dev/null || true)"; jq -r '.error.code // "none"' <<<"$o" 2>/dev/null || echo none; }
c="$(fl issues list --json --per-page 3 | jq -r .next)"
check "a cursor from different filters is refused (usage)" "$([ "$(err issues list --state closed --json --per-page 3 --cursor "$c")" = usage ] && echo 1 || echo 0)"
check "a cursor from another tracker is refused (usage)" "$([ "$(err issues list --tracker GL --json --per-page 3 --cursor "$c")" = usage ] && echo 1 || echo 0)"
check "a damaged cursor is refused (usage)" "$([ "$(err issues list --json --per-page 3 --cursor 'not-a-cursor')" = usage ] && echo 1 || echo 0)"
check "--per-page with --all-trackers is refused (usage)" "$([ "$(err issues list --all-trackers --json --per-page 3)" = usage ] && echo 1 || echo 0)"
check "--per-page with --limit is refused (usage)" "$([ "$(err issues list --json --per-page 3 --limit 5)" = usage ] && echo 1 || echo 0)"
check "--per-page 0 and 101 are refused (usage)" \
	"$([ "$(err issues list --json --per-page 0)" = usage ] && [ "$(err issues list --json --per-page 101)" = usage ] && echo 1 || echo 0)"
rc=0; (cd "$R" && "$DISP" issues list --per-page 3) >/dev/null 2>&1 || rc=$?
check "--per-page without --json is an error" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "capabilities advertise issues-paging" \
	"$("$DISP" capabilities --json | jq -e '.capabilities | index("issues-paging") != null' >/dev/null && echo 1 || echo 0)"

[ "$fail" -gt 0 ] && summary_colour=$'\033[0;31m' || summary_colour=''
printf '\n%sPassed: %d  Failed: %d\033[0m\n' "$summary_colour" "$pass" "$fail"
[ "$fail" -eq 0 ]
