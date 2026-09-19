#!/usr/bin/env bash
# Unit tests for list-verb pagination: every `list` verb must page under its
# --limit instead of handing back one server-clamped page, and must say on stderr
# when the limit hid rows. See flight/references/adapter-contract.md, "Paging".
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ADAPTERS="$REPO_ROOT/flight/scripts/adapters"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# A fake forge that behaves like the real ones: it CLAMPS the requested page size
# to CAP however much is asked for, and reports the true total only in a header.
mkdir -p "$SANDBOX/bin"
cat >"$SANDBOX/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=""; hdr=""; url=""; data=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		-D) hdr="$2"; shift 2 ;;
		--data-binary) data="$2"; shift 2 ;;
		-w|-X|-H|-u) shift 2 ;;
		-sS|-L) shift ;;
		*) url="$1"; shift ;;
	esac
done
printf '%s\n' "$url" >>"${CURL_LOG:?}"
[ -z "$data" ] || printf '%s\n' "$data" >>"${CURL_DATA_LOG:-/dev/null}"

# field <name> — the query parameter's value, or exit 1 if it isn't in the URL.
field() {
	case "$url" in
		*"?$1="*|*"&$1="*) : ;;
		*) return 1 ;;
	esac
	local v="${url##*[?&]$1=}"
	printf '%s' "${v%%&*}"
}

cap="${CAP:-50}"
total="${TOTAL:-109}"

# Where this request starts, and how many rows it may have. Jira's collections
# count from startAt, its JQL search from an opaque token (here: the next index),
# and the git forges from a page number.
if [ -n "$data" ]; then
	start="$(printf '%s' "$data" | jq -r '.nextPageToken // "0"')"
	asked="$(printf '%s' "$data" | jq -r '.maxResults // 50')"
	size="$asked"; [ "$size" -le "$cap" ] || size="$cap"
elif asked="$(field startAt)"; then
	start="$asked"
	asked="$(field maxResults)" || asked=50
	size="$asked"; [ "$size" -le "$cap" ] || size="$cap"
else
	page="$(field page)" || page=1
	asked="$(field limit)" || asked="$(field per_page)" || asked=30
	size="$asked"; [ "$size" -le "$cap" ] || size="$cap"
	start=$(( (page - 1) * size ))
fi

n=$(( total - start ))
[ "$n" -ge 0 ] || n=0
[ "$n" -le "$size" ] || n="$size"

# Rows are shaped for whichever endpoint was asked for, then wrapped in that
# backend's envelope: a bare array on the git forges, an object on Jira.
case "$url" in
	*/search/jql*)             tmpl='{"key":"ACME-\(.)","fields":{"summary":"i\(.)","labels":[]}}' ;;
	*/rest/api/3/label*)       tmpl='"l\(.)"' ;;
	*/comment*)                tmpl='{"author":{"displayName":"dave"},"created":"2026-09-01","user":{"login":"dave"},"created_at":"2026-09-01","body":"c\(.)"}' ;;
	*/labels*)                 tmpl='{"id":.,"name":"l\(.)","color":"ffffff","description":""}' ;;
	*)                         tmpl='{"number":.,"iid":.,"title":"i\(.)","labels":[]}' ;;
esac
rows="$(jq -nc --argjson s "$start" --argjson n "$n" "[range(\$s; \$s + \$n) | $tmpl]")"

next=$(( start + n ))
case "$url" in
	*/search/jql*)
		jq -nc --argjson r "$rows" --argjson next "$next" --argjson t "$total" \
			'{issues:$r} + (if $next < $t then {nextPageToken:($next|tostring)} else {isLast:true} end)' >"$out" ;;
	*/rest/api/3/label*)
		jq -nc --argjson r "$rows" --argjson s "$start" --argjson t "$total" --argjson m "$size" \
			'{values:$r, startAt:$s, maxResults:$m, total:$t, isLast:(($s + ($r|length)) >= $t)}' >"$out" ;;
	*/rest/api/3/issue/*/comment*)
		jq -nc --argjson r "$rows" --argjson s "$start" --argjson t "$total" --argjson m "$size" \
			'{comments:$r, startAt:$s, maxResults:$m, total:$t}' >"$out" ;;
	*)
		printf '%s' "$rows" >"$out" ;;
esac

if [ -n "$hdr" ]; then
	{
		printf 'HTTP/2 200\r\n'
		[ "${NO_TOTAL:-0}" = 1 ] || printf '%s: %s\r\n' "${TOTAL_HEADER:-x-total-count}" "$total"
		[ "$next" -ge "$total" ] || printf 'link: <https://x/next>; rel="next"\r\n'
		printf '\r\n'
	} >"$hdr"
fi
printf '200'
SH
chmod +x "$SANDBOX/bin/curl"

export PATH="$SANDBOX/bin:$PATH"
export LS_API=https://forge.invalid/api/v1 LS_OWNER=o LS_REPO=r LS_TOKEN=t
export CURL_LOG="$SANDBOX/curl.log"
export CURL_DATA_LOG="$SANDBOX/curl-data.log"

fail() { printf 'paging: %s\n' "$*" >&2; exit 1; }
# run [VAR=value…] cmd… — the fake forge reads its dataset from the environment,
# so per-case knobs go through `env` rather than being exported around the call.
run() { : >"$CURL_LOG"; : >"$CURL_DATA_LOG"; env "$@" >"$SANDBOX/out" 2>"$SANDBOX/err"; }
rows() { wc -l <"$SANDBOX/out" | tr -d ' '; }
reqs() { wc -l <"$CURL_LOG" | tr -d ' '; }

# --- Forgejo: --limit above the cap pages instead of truncating ----------------
# 109 rows behind a 50-row cap: pages 1 and 2 are full, page 3 is short, page 4 is
# empty and is what actually ends the loop — a short page cannot end it, because a
# short page and a clamped one look identical.
run "$ADAPTERS/forgejo/issues" list --state all --limit 200
[ "$(rows)" = 109 ] || fail "limit 200 returned $(rows) rows, want 109"
[ "$(reqs)" = 4 ] || fail "limit 200 made $(reqs) requests, want 4 (last one empty)"
[ ! -s "$SANDBOX/err" ] || fail "a complete list must not warn: $(cat "$SANDBOX/err")"
grep -q '^0	i0	$' "$SANDBOX/out" || fail "rows are not the expected TSV: $(head -1 "$SANDBOX/out")"

# --- Forgejo: at the limit, the hidden rows are named on stderr ----------------
run "$ADAPTERS/forgejo/issues" list --state all --limit 50
[ "$(rows)" = 50 ] || fail "limit 50 returned $(rows) rows, want 50"
grep -q 'showing 50 of 109' "$SANDBOX/err" || fail "no truncation warning: $(cat "$SANDBOX/err")"
! grep -q 'warning' "$SANDBOX/out" || fail "the warning leaked onto stdout"

# --- A limit under the page size costs exactly one request ---------------------
run "$ADAPTERS/forgejo/issues" list --state all --limit 20
[ "$(rows)" = 20 ] || fail "limit 20 returned $(rows) rows, want 20"
[ "$(reqs)" = 1 ] || fail "limit 20 made $(reqs) requests, want 1"
grep -q 'showing 20 of 109' "$SANDBOX/err" || fail "no truncation warning at limit 20"

# --- An exact-fit limit is complete, so it must not warn ----------------------
run TOTAL=20 "$ADAPTERS/forgejo/issues" list --state all --limit 20
[ "$(rows)" = 20 ] || fail "exact fit returned $(rows) rows, want 20"
[ ! -s "$SANDBOX/err" ] || fail "exact fit warned: $(cat "$SANDBOX/err")"

# --- An empty tracker is not an error ----------------------------------------
run TOTAL=0 "$ADAPTERS/forgejo/issues" list --state all --limit 50
[ "$(rows)" = 0 ] || fail "empty tracker returned $(rows) rows"
[ ! -s "$SANDBOX/err" ] || fail "empty tracker warned: $(cat "$SANDBOX/err")"

# --- No total header: warn without naming a count, never crash ----------------
run NO_TOTAL=1 "$ADAPTERS/forgejo/issues" list --state all --limit 50
[ "$(rows)" = 50 ] || fail "headerless forge returned $(rows) rows, want 50"
grep -q 'more are available' "$SANDBOX/err" || fail "no fallback warning: $(cat "$SANDBOX/err")"

# --- GitHub comments page to exhaustion, so the NEWEST are never dropped ------
# GitHub renders oldest-first and defaults to 30 per page, which is exactly why an
# unpaged fetch loses the trailing correction "the later comment wins" relies on.
run CAP=30 TOTAL=70 "$ADAPTERS/github/issues" comments --number 1
[ "$(grep -c '^dave	' "$SANDBOX/out")" = 70 ] || fail "github comments returned $(grep -c '^dave	' "$SANDBOX/out") of 70"
grep -q '^c69$' "$SANDBOX/out" || fail "the newest github comment was dropped"
[ ! -s "$SANDBOX/err" ] || fail "an exhaustive fetch warned: $(cat "$SANDBOX/err")"

# --- GitLab reads its total from X-Total --------------------------------------
run TOTAL_HEADER=x-total "$ADAPTERS/gitlab/issues" list --state all --limit 50
[ "$(rows)" = 50 ] || fail "gitlab limit 50 returned $(rows) rows"
grep -q 'showing 50 of 109' "$SANDBOX/err" || fail "gitlab read no total: $(cat "$SANDBOX/err")"

# --- labels list goes through the same paged cache label_id uses --------------
run "$ADAPTERS/forgejo/labels" list
[ "$(rows)" = 109 ] || fail "labels list returned $(rows) rows, want 109"

# --- A bad --limit is refused rather than looped over -------------------------
if "$ADAPTERS/forgejo/issues" list --limit 0 >/dev/null 2>&1; then
	fail "--limit 0 was accepted"
fi
if "$ADAPTERS/forgejo/issues" list --limit abc >/dev/null 2>&1; then
	fail "--limit abc was accepted"
fi


# --- Jira: the JQL search pages with an opaque nextPageToken ------------------
# Jira clamps maxResults to its own ceiling and the enhanced search reports no
# total, so the token is the only thing that says whether more remain.
export LS_EMAIL=dev@example.invalid LS_PROJECT=ACME
run "$ADAPTERS/jira/issues" list --state all --limit 200
[ "$(rows)" = 109 ] || fail "jira list returned $(rows) rows, want 109"
[ "$(reqs)" = 3 ] || fail "jira list made $(reqs) requests, want 3"
[ ! -s "$SANDBOX/err" ] || fail "a complete jira list warned: $(cat "$SANDBOX/err")"
grep -q '^ACME-0	i0	$' "$SANDBOX/out" || fail "jira rows are not the expected TSV: $(head -1 "$SANDBOX/out")"

run "$ADAPTERS/jira/issues" list --state all --limit 50
[ "$(rows)" = 50 ] || fail "jira limit 50 returned $(rows) rows"
grep -q 'more are available' "$SANDBOX/err" || fail "jira did not warn at the cap: $(cat "$SANDBOX/err")"

# --- Jira: the collection endpoints page with startAt against total -----------
run "$ADAPTERS/jira/labels" list
[ "$(rows)" = 109 ] || fail "jira labels returned $(rows) rows, want 109"
grep -q '^l108		$' "$SANDBOX/out" || fail "the last jira label was dropped"

run CAP=50 TOTAL=70 "$ADAPTERS/jira/issues" comments --number ACME-1
[ "$(grep -c '^dave	' "$SANDBOX/out")" = 70 ] || fail "jira comments returned $(grep -c '^dave	' "$SANDBOX/out") of 70"
grep -q '^c69$' "$SANDBOX/out" || fail "the newest jira comment was dropped"

# --- Every interpolated query value is percent-encoded ------------------------
# A default status label (`status/to test`) carries a space and a slash. Dropped
# raw into the query string, curl refuses the whole request ("Malformed input to
# a URL function") and the board cross-check in cleaning-up-branches cannot run.
# Every backend that puts the name in the URL must send the encoded form.
LABEL='status/to test'
ENC='status%2Fto%20test'

run "$ADAPTERS/forgejo/issues" list --state open --label "$LABEL" --limit 20
grep -q "labels=$ENC" "$CURL_LOG" \
	|| fail "forgejo list did not encode the label: $(head -1 "$CURL_LOG")"
! grep -q 'labels=[^&]*[ ]' "$CURL_LOG" || fail "forgejo list left a raw space in the URL"

run "$ADAPTERS/github/issues" list --state open --label "$LABEL" --limit 20
grep -q "labels=$ENC" "$CURL_LOG" \
	|| fail "github list did not encode the label: $(head -1 "$CURL_LOG")"

run "$ADAPTERS/gitlab/issues" list --state open --label "$LABEL" --limit 20
grep -q "labels=$ENC" "$CURL_LOG" \
	|| fail "gitlab list did not encode the label: $(head -1 "$CURL_LOG")"

# Two labels comma-join as two encoded values, not one encoded comma.
run "$ADAPTERS/forgejo/issues" list --state open --label "$LABEL" --label 'type/bug' --limit 20
grep -q "labels=$ENC,type%2Fbug" "$CURL_LOG" \
	|| fail "forgejo list mangled a two-label filter: $(head -1 "$CURL_LOG")"

# --state is caller input too, so it is encoded rather than trusted.
run "$ADAPTERS/forgejo/issues" list --state 'a b' --limit 20
grep -q 'state=a%20b' "$CURL_LOG" || fail "forgejo list did not encode --state"

# Jira puts the label in a JQL string literal in the POST body, not in the URL,
# so what must hold there is the quoting — the space stays, the quotes wrap it.
export LS_EMAIL=dev@example.invalid LS_PROJECT=ACME
run "$ADAPTERS/jira/issues" list --state open --label "$LABEL" --limit 20
jql="$(jq -rs '.[0].jql' "$CURL_DATA_LOG")"
grep -q 'labels IN ("status/to test")' <<<"$jql" \
	|| fail "jira list did not quote the label in its JQL: $jql"

printf 'paging tests passed\n'
