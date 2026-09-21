#!/usr/bin/env bash
# Unit tests for the dispatcher-owned starting status (#193): when a repo configures a `new`
# status role, `issues create` applies that label so a freshly filed issue is distinguishable
# from one whose label was forgotten. Applied in the dispatcher (adapters stay pure), opt-in via
# `labels.status.new`, skipped when the caller chose a status of their own or passed
# --no-status. A fake curl serves the label list and captures the created payload.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DISP="$REPO_ROOT/flight/scripts/flight"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin"

# Label ids the fake serves; the assertions read the created issue's `labels` array back
# through them. 11 = status/new, 12 = status/blocked, 13 = bug.
cat >"$SANDBOX/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=""; method=GET; payload=""; url=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		-w) shift 2 ;;
		-X) method="$2"; shift 2 ;;
		-H|-u) shift 2 ;;
		-L|-sS) shift ;;
		--data-binary) payload="$2"; shift 2 ;;
		*) url="$1"; shift ;;
	esac
done
case "$url" in
	# The adapter pages until a page comes back empty, so serve the rows once and then
	# nothing — a fake that repeats itself forever paginates forever.
	*/labels*page=1*|*/labels*[!0-9]page=1) body='[{"id":11,"name":"status/new"},{"id":12,"name":"status/blocked"},{"id":13,"name":"bug"}]' ;;
	*/labels*)  body='[]' ;;
	# `labels` present and empty: set-status reads the issue's current labels back.
	*)          body='{"number":42,"iid":42,"id":7,"title":"t","state":"open","labels":[]}' ;;
esac
[ -z "$out" ] && printf '%s' "$body" || printf '%s' "$body" >"$out"
if [ "$method" != GET ]; then
	printf '%s\t%s\t%s\n' "$method" "$url" "$(printf '%s' "$payload" | jq -c . 2>/dev/null)" >>"${CURL_LOG:?}"
fi
printf '200'
SH
chmod +x "$SANDBOX/bin/curl"
export PATH="$SANDBOX/bin:$PATH"
export CURL_LOG="$SANDBOX/curl.log"
export LS_TOKEN=t
unset FLIGHT_MODEL LS_MODEL

pass=0; fail=0
check() { if [ "$2" = 1 ]; then printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass+1));
			else printf '\033[0;31m  ✗ %s\033[0m  %s\n' "$1" "${3:-}"; fail=$((fail+1)); fi; }

# mkrepo <name> <labels-json> → prints the repo path
mkrepo() {
	local r="$SANDBOX/$1" labels="$2"; mkdir -p "$r/.flightdirector"; git -C "$r" init -q
	jq -n --argjson labels "$labels" \
		'{code:{backend:"forgejo",owner:"acme",repo:"widget",api:"https://example.invalid/api/v1",stages:[{name:"develop"}]}, labels:$labels}' \
		>"$r/.flightdirector/config.json"
	printf '%s\n' "$r"
}
# run <repo> <args…> → the POSTed issue's label ids in $LABELS (JSON array, "null" if none)
run() {
	local r="$1"; shift
	: >"$CURL_LOG"
	set +e; (cd "$r" && "$DISP" "$@" >"$SANDBOX/out" 2>"$SANDBOX/err"); RC=$?; set -e
	LABELS="$(grep -a '/issues' "$CURL_LOG" | tail -1 | cut -f3 | jq -c '.labels // null' 2>/dev/null || echo null)"
}

WITH_NEW='{"status":{"new":"status/new","blocked":"status/blocked"}}'
WITHOUT_NEW='{"status":{"blocked":"status/blocked"}}'

printf '\033[1m── dispatcher: starting status on issues create ──\033[0m\n'

R="$(mkrepo configured "$WITH_NEW")"
run "$R" issues create --title "t" --body b
check "a configured 'new' role is applied to a freshly filed issue" \
	"$([ "$RC" = 0 ] && [ "$LABELS" = "[11]" ] && echo 1 || echo 0)" "rc=$RC labels=$LABELS"

run "$R" issues create --title "t" --body b --label bug
check "it is added alongside a non-status label the caller chose" \
	"$([ "$RC" = 0 ] && [ "$(jq -c 'sort' <<<"$LABELS")" = "[11,13]" ] && echo 1 || echo 0)" "labels=$LABELS"

run "$R" issues create --title "t" --body b --label "status/blocked"
check "a caller who chose a status of their own keeps it, and gets no second status" \
	"$([ "$RC" = 0 ] && [ "$LABELS" = "[12]" ] && echo 1 || echo 0)" "labels=$LABELS"

run "$R" issues create --title "t" --body b --no-status
check "--no-status opts one issue out" \
	"$([ "$RC" = 0 ] && [ "$LABELS" = "null" ] && echo 1 || echo 0)" "labels=$LABELS"

# --- opt-in: a repo that never configured the role is untouched -----------------
R2="$(mkrepo unconfigured "$WITHOUT_NEW")"
run "$R2" issues create --title "t" --body b
check "no 'new' role configured → nothing is added (every pre-#193 repo)" \
	"$([ "$RC" = 0 ] && [ "$LABELS" = "null" ] && echo 1 || echo 0)" "labels=$LABELS"

run "$R2" issues create --title "t" --body b --label bug
check "…and the caller's own labels still go through" \
	"$([ "$RC" = 0 ] && [ "$LABELS" = "[13]" ] && echo 1 || echo 0)" "labels=$LABELS"

# --- declined: recorded as `false` so setup's gap check stops asking ------------
R3="$(mkrepo declined '{"status":{"new":false,"blocked":"status/blocked"}}')"
run "$R3" issues create --title "t" --body b
check "a declined role (recorded as false) adds nothing" \
	"$([ "$RC" = 0 ] && [ "$LABELS" = "null" ] && echo 1 || echo 0)" "rc=$RC labels=$LABELS err=$(cat "$SANDBOX/err")"
run "$R3" issues set-status --number 1 --status blocked
check "…and set-status still works with a non-string value in the map" \
	"$([ "$RC" = 0 ] && echo 1 || echo 0)" "rc=$RC err=$(cat "$SANDBOX/err")"

# --- create only: nothing else grows a status label ----------------------------
run "$R" issues comment --number 1 --body hello
check "issues comment is untouched" "$([ "$RC" = 0 ] && [ "$LABELS" = "null" ] && echo 1 || echo 0)" "labels=$LABELS"
run "$R" issues update --number 1 --title "retitled"
check "issues update is untouched" "$([ "$RC" = 0 ] && [ "$LABELS" = "null" ] && echo 1 || echo 0)" "labels=$LABELS"

# --- the body signature still lands (the two dispatcher rewrites compose) -------
run "$R" issues create --title "t" --body "hello" --model claude-opus-5
BODY="$(grep -a '/issues' "$CURL_LOG" | tail -1 | cut -f3 | jq -r '.body // empty')"
check "the signature rewrite and the label injection coexist" \
	"$([ "$LABELS" = "[11]" ] && grep -q 'FlightDirector:flight@' <<<"$BODY" && echo 1 || echo 0)" "labels=$LABELS body=$BODY"

printf '\n'
[ "$fail" -gt 0 ] && summary_colour=$'\033[0;31m' || summary_colour=''
printf '%sPassed: %d  Failed: %d\033[0m\n' "$summary_colour" "$pass" "$fail"
[ "$fail" -eq 0 ]
