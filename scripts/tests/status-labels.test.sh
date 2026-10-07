#!/usr/bin/env bash
# Contract tests for `issues set-status` / `clear-status` on the label-keyed adapters
# (forgejo by id, github by name): exactly the OTHER configured status labels the issue
# carries are removed, a non-status label is never touched, a declined role (false) is
# skipped — and the repo's label registry is fetched ONCE per call, however many status
# roles there are (FJ-301: every lookup used to re-fetch the whole paged list).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin"

cat >"$SANDBOX/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=""; method=GET; payload=""; url=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		-D|-w|-X|-H|-u) [ "$1" = -X ] && method="$2"; shift 2 ;;
		-L|-sS) shift ;;
		--data-binary) payload="$2"; shift 2 ;;
		*) url="$1"; shift ;;
	esac
done
# ON_ISSUE is the JSON array of label names the issue currently carries.
on_issue="${ON_ISSUE:-[\"bug\",\"status/new\",\"status/qa\"]}"
registry='[{"id":7,"name":"bug"},{"id":11,"name":"status/new"},{"id":12,"name":"status/to-test"},{"id":13,"name":"status/qa"},{"id":14,"name":"status/done"}]'
printf '%s\t%s\t%s\n' "$method" "$url" "$(printf '%s' "$payload" | jq -c . 2>/dev/null)" >>"${CURL_LOG:?}"
if [ "$method" = GET ]; then
	case "$url" in
		*/labels\?*\&page=1) printf '%s' "$registry" >"$out" ;;
		*/labels\?*)         printf '%s' '[]' >"$out" ;;
		*) jq -n --argjson n "$on_issue" --argjson r "$registry" \
			'{number:5, labels:[$n[] as $x | $r[] | select(.name == $x)]}' >"$out" ;;
	esac
else
	printf '%s' '{}' >"$out"
fi
printf '200'
SH
chmod +x "$SANDBOX/bin/curl"

export PATH="$SANDBOX/bin:$PATH"
export LS_API=https://example.invalid/api LS_OWNER=acme LS_REPO=widget LS_TOKEN=t
export CURL_LOG="$SANDBOX/curl.log"
# in-progress is declined (false): a role with no label must be skipped, not looked up.
export LS_LABELS_JSON='{"status":{"new":"status/new","in-progress":false,"to-test":"status/to-test","qa":"status/qa","done":"status/done"}}'

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; }
bad() { fail=$((fail + 1)); printf '\033[0;31m  ✗ %s\033[0m\n' "$1"; }
check() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }

# run <backend> <verb> [args…] — the adapter's exit code; resets the request log.
run() {
	backend="$1"; shift
	: >"$CURL_LOG"
	set +e
	"$REPO_ROOT/flight/scripts/adapters/$backend/issues" "$@" >"$SANDBOX/out" 2>"$SANDBOX/err"
	rc=$?
	set -e
	return $rc
}
writes()   { awk -F'\t' '$1 != "GET" { sub("https://example.invalid/api/repos/acme/widget", "", $2); print $1 " " $2 }' "$CURL_LOG"; }
registry() { grep -c '^GET	[^	]*/labels?.*&page=1	' "$CURL_LOG" || true; }

printf '\033[1m── forgejo (by id) ──\033[0m\n'
if run forgejo set-status --number 5 --status to-test; then
	check "$(writes | tr '\n' ' ')" "DELETE /issues/5/labels/11 DELETE /issues/5/labels/13 POST /issues/5/labels " \
		"set-status removes the other status labels it carries (new, qa), keeps bug, adds to-test"
	check "$(grep '^POST' "$CURL_LOG" | cut -f3)" '{"labels":[12]}' "the target is added by its id"
	check "$(registry)" 1 "the label registry is fetched once for all five roles"
else
	bad "forgejo set-status exited non-zero: $(cat "$SANDBOX/err")"
fi
if ON_ISSUE='["status/to-test","bug"]' run forgejo set-status --number 5 --status to-test; then
	check "$(writes | tr '\n' ' ')" "POST /issues/5/labels " "the target the issue already carries is never deleted"
else
	bad "forgejo set-status (already set) exited non-zero"
fi
if run forgejo set-status --number 5 --status in-progress; then
	bad "forgejo accepted a declined role"
else
	ok "a declined role is an error, not a silent no-op"
fi
if run forgejo clear-status --number 5; then
	check "$(writes | tr '\n' ' ')" "DELETE /issues/5/labels/11 DELETE /issues/5/labels/13 " \
		"clear-status removes every status label it carries and nothing else"
	check "$(registry)" 1 "clear-status fetches the registry once"
else
	bad "forgejo clear-status exited non-zero"
fi
if run forgejo label-add --number 5 --label bug --label status/qa --label status/done; then
	check "$(registry)" 1 "label-add resolves three names with one registry fetch"
else
	bad "forgejo label-add exited non-zero"
fi

printf '\033[1m── github (by name) ──\033[0m\n'
if run github set-status --number 5 --status to-test; then
	check "$(writes | tr '\n' ' ')" "DELETE /issues/5/labels/status%2Fnew DELETE /issues/5/labels/status%2Fqa POST /issues/5/labels " \
		"set-status removes the other status labels it carries, keeps bug, adds to-test"
	check "$(grep '^POST' "$CURL_LOG" | cut -f3)" '{"labels":["status/to-test"]}' "the target is added by name"
else
	bad "github set-status exited non-zero: $(cat "$SANDBOX/err")"
fi
if ON_ISSUE='["status/to-test"]' run github set-status --number 5 --status to-test; then
	check "$(writes | tr '\n' ' ')" "POST /issues/5/labels " "the target the issue already carries is never deleted"
else
	bad "github set-status (already set) exited non-zero"
fi
if run github clear-status --number 5; then
	check "$(writes | tr '\n' ' ')" "DELETE /issues/5/labels/status%2Fnew DELETE /issues/5/labels/status%2Fqa " \
		"clear-status removes every status label it carries and nothing else"
else
	bad "github clear-status exited non-zero"
fi
if run github label-add --number 5 --label bug --label status/qa --label status/done; then
	check "$(registry)" 1 "label-add resolves three names with one registry fetch"
else
	bad "github label-add exited non-zero"
fi

[ "$fail" -gt 0 ] && colour=$'\033[0;31m' || colour=''
printf '\n%sPassed: %d  Failed: %d\033[0m\n' "$colour" "$pass" "$fail"
[ "$fail" -eq 0 ]
