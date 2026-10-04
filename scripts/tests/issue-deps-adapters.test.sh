#!/usr/bin/env bash
# shellcheck disable=SC2016  # the single-quoted strings are jq programs; their $-vars are jq's
# The adapters' native dependency verbs (FJ-271): dep-add, dep-remove, dep-list, dep-blocking.
# The network is a fake `curl` that answers from a route table and logs every request, so each
# test can say both what the adapter printed and what it sent.
# Contract: flight/references/adapter-contract.md (issues → dep-*).
set -euo pipefail

unset LS_JSON FLIGHT_ERROR_FILE
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ADAPTERS="$REPO_ROOT/flight/scripts/adapters"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

pass=0; fail=0
check() {
	if [ "$2" = 1 ]; then printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass + 1))
	else printf '\033[0;31m  ✗ %s\033[0m  %s\n' "$1" "${3:-}"; fail=$((fail + 1)); fi
}
section() { printf '\033[1m── %s ──\033[0m\n' "$1"; }

mkdir -p "$SANDBOX/bin" "$SANDBOX/bodies"
cat >"$SANDBOX/bin/curl" <<'SH'
#!/usr/bin/env bash
# Fake curl. Routes: lines of METHOD<TAB>URL-REGEX<TAB>STATUS<TAB>BODY-FILE in $ROUTES, first
# match wins. Every request is logged to $CURL_LOG as "METHOD URL DATA".
set -euo pipefail
out=""; method=GET; data=""; url=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		-X) method="$2"; shift 2 ;;
		--data-binary) data="$2"; shift 2 ;;
		-D|-w|-H|-u) shift 2 ;;
		-sS|-L) shift ;;
		*) url="$1"; shift ;;
	esac
done
printf '%s %s %s\n' "$method" "$url" "$data" >>"${CURL_LOG:?}"
while IFS=$'\t' read -r m re code body; do
	[ "$m" = "$method" ] || continue
	[[ "$url" =~ $re ]] || continue
	cat "$body" >"$out"; printf '%s' "$code"; exit 0
done <"${ROUTES:?}"
printf '{"message":"no route for %s %s"}' "$method" "$url" >"$out"; printf '404'
SH
chmod +x "$SANDBOX/bin/curl"
export PATH="$SANDBOX/bin:$PATH"
export LS_API=https://forge.invalid/api/v1 LS_OWNER=o LS_REPO=r LS_TOKEN=t LS_PROJECT=ACME LS_EMAIL=a@b.c
export ROUTES="$SANDBOX/routes" CURL_LOG="$SANDBOX/curl.log"

body_n=0
# route METHOD URL-REGEX STATUS JSON — add one answer to the table.
route() {
	body_n=$((body_n + 1))
	printf '%s' "$4" >"$SANDBOX/bodies/$body_n"
	printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$SANDBOX/bodies/$body_n" >>"$ROUTES"
}
reset() { : >"$ROUTES"; : >"$CURL_LOG"; }
# run ADAPTER VERB ARGS… — stdout of the adapter; its exit status is in $RC and its error
# envelope (if any) in $SANDBOX/err.json.
run() {
	local a="$1"; shift
	rm -f "$SANDBOX/err.json"; RC=0
	OUT="$(FLIGHT_ERROR_FILE="$SANDBOX/err.json" "$ADAPTERS/$a/issues" "$@" 2>/dev/null)" || RC=$?
}
code() { jq -r '.error.code // empty' "$SANDBOX/err.json" 2>/dev/null || true; }
sent() { grep -c -F -- "$1" "$CURL_LOG" || true; }

section "forgejo"
reset
route GET '/repos/o/r$' 200 '{"internal_tracker":{"enable_issue_dependencies":false}}'
run forgejo dep-list --number 5
check "dependencies switched off → unsupported" "$([ "$RC" = 1 ] && [ "$(code)" = unsupported ] && echo 1 || echo 0)" "rc=$RC code=$(code)"

reset
route GET '/repos/o/r$' 200 '{"internal_tracker":{"enable_issue_dependencies":true}}'
route GET '/issues/5/dependencies' 200 '[{"number":7,"title":"Seven","state":"open","repository":{"owner":"o","name":"r"}},{"number":9,"title":"Elsewhere","state":"open","repository":{"owner":"other","name":"r"}}]'
route GET '/issues/5/blocks' 200 '[{"number":11,"title":"Eleven","state":"closed","repository":{"owner":"O","name":"R"}}]'
run forgejo dep-list --number 5
check "dep-list: this repo's blockers only, as TSV" "$([ "$OUT" = "$(printf '7\tSeven\topen')" ] && echo 1 || echo 0)" "$OUT"
run forgejo dep-blocking --number 5
check "dep-blocking reads /blocks; owner/repo match ignores case" "$([ "$OUT" = "$(printf '11\tEleven\tclosed')" ] && echo 1 || echo 0)" "$OUT"
OUT="$(LS_JSON=1 "$ADAPTERS/forgejo/issues" dep-list --number 5)"
check "dep-list --json is an array of {number,title,state}" "$(jq -e '. == [{"number":"7","title":"Seven","state":"open"}]' <<<"$OUT" >/dev/null && echo 1 || echo 0)" "$OUT"

: >"$CURL_LOG"
route POST '/issues/5/dependencies' 201 '{}'
run forgejo dep-add --number 5 --by 8
check "dep-add posts {owner, repo, index}" "$([ "$RC" = 0 ] && [ "$(sent 'POST https://forge.invalid/api/v1/repos/o/r/issues/5/dependencies {"owner":"o","repo":"r","index":8}')" = 1 ] && echo 1 || echo 0)" "$(cat "$CURL_LOG")"
: >"$CURL_LOG"
run forgejo dep-add --number 5 --by 7
check "dep-add of an existing link sends nothing" "$([ "$RC" = 0 ] && [ "$(sent POST)" = 0 ] && echo 1 || echo 0)" "$(cat "$CURL_LOG")"
: >"$CURL_LOG"
route DELETE '/issues/5/dependencies' 200 '{}'
run forgejo dep-remove --number 5 --by 7
check "dep-remove sends DELETE with the same body" "$([ "$(sent 'DELETE https://forge.invalid/api/v1/repos/o/r/issues/5/dependencies {"owner":"o","repo":"r","index":7}')" = 1 ] && echo 1 || echo 0)" "$(cat "$CURL_LOG")"
: >"$CURL_LOG"
run forgejo dep-remove --number 5 --by 8
check "dep-remove of a missing link sends nothing" "$([ "$RC" = 0 ] && [ "$(sent DELETE)" = 0 ] && echo 1 || echo 0)"
run forgejo dep-add --number 5 --by abc
check "a non-numeric --by is a usage error" "$([ "$RC" = 1 ] && [ "$(code)" = usage ] && echo 1 || echo 0)"

section "github"
reset
route GET '/issues/5/dependencies/blocked_by' 200 '[{"number":7,"title":"Seven","state":"closed","repository_url":"https://api.github.com/repos/O/R"},{"number":9,"title":"Elsewhere","state":"open","repository_url":"https://api.github.com/repos/x/y"}]'
route GET '/issues/5/dependencies/blocking' 200 '[{"number":12,"title":"Twelve","state":"open","repository_url":"https://api.github.com/repos/o/r"}]'
route GET '/issues/8$' 200 '{"id":4242,"number":8}'
route GET '/issues/7$' 200 '{"id":4141,"number":7}'
route POST '/issues/5/dependencies/blocked_by' 201 '{}'
route DELETE '/issues/5/dependencies/blocked_by/4141' 200 '{}'
run github dep-list --number 5
check "dep-list: this repo's blockers only" "$([ "$OUT" = "$(printf '7\tSeven\tclosed')" ] && echo 1 || echo 0)" "$OUT"
run github dep-blocking --number 5
check "dep-blocking reads /dependencies/blocking" "$([ "$OUT" = "$(printf '12\tTwelve\topen')" ] && echo 1 || echo 0)" "$OUT"
: >"$CURL_LOG"
run github dep-add --number 5 --by 8
check "dep-add posts the blocker's database id" "$([ "$(sent 'POST https://forge.invalid/api/v1/repos/o/r/issues/5/dependencies/blocked_by {"issue_id":4242}')" = 1 ] && echo 1 || echo 0)" "$(cat "$CURL_LOG")"
: >"$CURL_LOG"
run github dep-add --number 5 --by 7
check "dep-add of an existing link sends nothing" "$([ "$RC" = 0 ] && [ "$(sent POST)" = 0 ] && echo 1 || echo 0)"
: >"$CURL_LOG"
run github dep-remove --number 5 --by 7
check "dep-remove deletes by database id" "$([ "$(sent 'DELETE https://forge.invalid/api/v1/repos/o/r/issues/5/dependencies/blocked_by/4141')" = 1 ] && echo 1 || echo 0)" "$(cat "$CURL_LOG")"

[ "$fail" -gt 0 ] && summary_colour=$'\033[0;31m' || summary_colour=''
printf '\n%sPassed: %d  Failed: %d\033[0m\n' "$summary_colour" "$pass" "$fail"
[ "$fail" -eq 0 ]
