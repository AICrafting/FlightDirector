#!/usr/bin/env bash
# Contract tests for `issues label-remove` — the mirror of `label-add` — across
# every backend adapter. A fake curl stands in for the API: it serves the repo's
# label registry and the issue's current labels, and logs every write.
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
		-w) shift 2 ;;
		-X) method="$2"; shift 2 ;;
		-H|-u) shift 2 ;;
		-L|-sS) shift ;;
		--data-binary) payload="$2"; shift 2 ;;
		*) url="$1"; shift ;;
	esac
done
# ON_ISSUE is the JSON array of label names the issue currently carries.
on_issue="${ON_ISSUE:-[\"bug\",\"status/to-test\"]}"
if [ "$method" = GET ]; then
	case "$url" in
		*/labels\?*)
			# The repo's label registry (page 1 only; page 2+ is empty).
			case "$url" in
				*page=2*|*page=3*) printf '%s' '[]' >"$out" ;;
				*) printf '%s' '[{"id":7,"name":"bug"},{"id":8,"name":"status/to-test"},{"id":9,"name":"chore"}]' >"$out" ;;
			esac
			;;
		*fields=labels*)
			jq -n --argjson n "$on_issue" '{fields:{labels:$n}}' >"$out" ;;
		*)
			# The issue itself: both id and name are needed (forgejo keys on id).
			jq -n --argjson n "$on_issue" \
				'{number:5, labels:[$n[] | {name:., id:(if .=="bug" then 7 elif .=="status/to-test" then 8 else 9 end)}]}' >"$out" ;;
	esac
else
	printf '%s' '{}' >"$out"
	# One line per write: METHOD⇥url⇥compacted-payload (adapters send pretty JSON).
	printf '%s\t%s\t%s\n' "$method" "$url" "$(printf '%s' "$payload" | jq -c . 2>/dev/null)" >>"${CURL_LOG:?}"
fi
printf '200'
SH
chmod +x "$SANDBOX/bin/curl"

export PATH="$SANDBOX/bin:$PATH"
export LS_API=https://example.invalid/api LS_OWNER=acme LS_REPO=widget LS_TOKEN=t
export LS_EMAIL=dev@example.invalid LS_PROJECT=ACME
export CURL_LOG="$SANDBOX/curl.log"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; }
bad() { fail=$((fail + 1)); printf '\033[0;31m  ✗ %s\033[0m\n' "$1"; }
check() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }

# run <backend> [args…] — returns the adapter's exit code, resets the write log.
run() {
	backend="$1"; shift
	: >"$CURL_LOG"
	set +e
	"$REPO_ROOT/flight/scripts/adapters/$backend/issues" label-remove "$@" \
		>"$SANDBOX/out" 2>"$SANDBOX/err"
	rc=$?
	set -e
	return $rc
}

# --- forgejo: removes by numeric label id ---------------------------------
if run forgejo --number 5 --label bug; then
	check "$(cut -f1,2 "$CURL_LOG")" \
		"$(printf 'DELETE\thttps://example.invalid/api/repos/acme/widget/issues/5/labels/7')" \
		"forgejo deletes the label id from the issue"
	check "$(cat "$SANDBOX/out")" "" "forgejo is silent on success"
else
	bad "forgejo label-remove exited non-zero"
fi

# Idempotent: a label the issue is not carrying is a no-op success.
if ON_ISSUE='["status/to-test"]' run forgejo --number 5 --label bug; then
	check "$(wc -l <"$CURL_LOG")" "0" "forgejo writes nothing when the label is absent"
else
	bad "forgejo label-remove was not idempotent"
fi

# An unknown label name is still an error — same as label-add.
if run forgejo --number 5 --label nope; then
	bad "forgejo accepted an unknown label name"
else
	ok "forgejo rejects an unknown label name"
fi

# Repeatable --label.
if run forgejo --number 5 --label bug --label status/to-test; then
	check "$(grep -c '^DELETE' "$CURL_LOG")" "2" "forgejo --label is repeatable"
else
	bad "forgejo repeated --label exited non-zero"
fi

# --- github: removes by URL-encoded name ----------------------------------
if run github --number 5 --label status/to-test; then
	check "$(cut -f1,2 "$CURL_LOG")" \
		"$(printf 'DELETE\thttps://example.invalid/api/repos/acme/widget/issues/5/labels/status%%2Fto-test')" \
		"github deletes the url-encoded label name"
else
	bad "github label-remove exited non-zero"
fi

if ON_ISSUE='["bug"]' run github --number 5 --label status/to-test; then
	check "$(wc -l <"$CURL_LOG")" "0" "github writes nothing when the label is absent"
else
	bad "github label-remove was not idempotent"
fi

if run github --number 5 --label nope; then
	bad "github accepted an unknown label name"
else
	ok "github rejects an unknown label name"
fi

# --- gitlab: one PUT with remove_labels ------------------------------------
if run gitlab --number 5 --label bug --label chore; then
	check "$(cut -f1,2 "$CURL_LOG")" \
		"$(printf 'PUT\thttps://example.invalid/api/projects/acme%%2Fwidget/issues/5')" \
		"gitlab patches the issue once"
	check "$(cut -f3 "$CURL_LOG" | jq -r .remove_labels)" "bug,chore" \
		"gitlab sends remove_labels as CSV"
	check "$(cut -f3 "$CURL_LOG" | jq -r 'has("add_labels")')" "false" \
		"gitlab adds nothing"
else
	bad "gitlab label-remove exited non-zero"
fi

if run gitlab --number 5 --label nope; then
	bad "gitlab accepted an unknown label name"
else
	ok "gitlab rejects an unknown label name"
fi

# --- jira: update ops, only for labels the issue carries -------------------
if run jira --number ACME-5 --label bug; then
	check "$(cut -f1,2 "$CURL_LOG")" \
		"$(printf 'PUT\thttps://example.invalid/api/rest/api/3/issue/ACME-5')" \
		"jira updates the issue"
	check "$(cut -f3 "$CURL_LOG" | jq -c '.update.labels')" '[{"remove":"bug"}]' \
		"jira sends a remove op"
else
	bad "jira label-remove exited non-zero"
fi

if ON_ISSUE='["chore"]' run jira --number ACME-5 --label bug; then
	check "$(wc -l <"$CURL_LOG")" "0" "jira writes nothing when the label is absent"
else
	bad "jira label-remove was not idempotent"
fi

if run jira --number ACME-5 --label "has space"; then
	bad "jira accepted a label name with a space"
else
	ok "jira rejects a label name with a space"
fi

# --- shared argument validation -------------------------------------------
for backend in forgejo github gitlab jira; do
	if run "$backend" --number 5; then
		bad "$backend accepted no --label"
	else
		ok "$backend requires at least one --label"
	fi
	if run "$backend" --label bug; then
		bad "$backend accepted no --number"
	else
		ok "$backend requires --number"
	fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
